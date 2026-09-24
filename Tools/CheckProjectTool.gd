class_name CheckProjectTool
extends GodotTool

const DEFAULT_LIMIT := 100
const PER_FILE_TIMEOUT := 15.0

func _init() -> void:
	name = "check_project"
	description = (
		"Syntax-check every .gd file under a directory (default: whole project). "
		+ "Unlike launch_headless, reaches scripts only loaded at runtime (e.g. behind "
		+ "a button press). Slower — one process per file — so use after a batch of "
		+ "edits or when a non-boot scene might be broken. Autoload 'Identifier not "
		+ "found' false positives are filtered automatically."
	)
	required_permission = "RUN_GODOT"
	input_schema = {
		"type": "object",
		"properties": {
			"path": {"type": "string", "description": "Directory to scan; default res://"},
			"limit": {"type": "integer", "description": "Max files to check; default 100"},
		},
	}

func execute(arguments: Dictionary) -> ToolResult:
	if project_root == "":
		return ToolResult.invalid_argument("No project is open")
	if process_manager == null:
		return ToolResult.failure("GodotProcessManager is not available", ToolResult.ErrorKind.INTERNAL)
	var exe := _resolve_executable()
	if exe.strip_edges() == "":
		return ToolResult.invalid_argument("Godot executable is not configured")

	var raw_path := str(arguments.get("path", "res://"))
	if raw_path.strip_edges() == "":
		raw_path = "res://"
	var full := resolve_path(raw_path)
	if full == "":
		return ToolResult.sandbox_violation("Path is outside the project sandbox: %s" % raw_path)
	if not DirAccess.dir_exists_absolute(full) and not FileAccess.file_exists(full):
		return ToolResult.not_found("Path does not exist: %s" % raw_path)

	var limit := int(arguments.get("limit", DEFAULT_LIMIT))
	var files: Array = []
	_collect_gd_files(full, files)
	files.sort()

	var total := files.size()
	var window: Array = files.slice(0, limit)
	var autoload_names := _load_autoload_names()

	var failures := PackedStringArray()
	var all_events: Array = []
	var checked := 0
	var suppressed := 0
	var filtered_ident_names: PackedStringArray = PackedStringArray()
	for abs_path in window:
		checked += 1
		var res_path := _to_res_path(abs_path)
		var args := PackedStringArray([
			"--path", project_root,
			"--headless",
			"--check-only",
			"--script", res_path,
		])
		var id: int = process_manager.launch(exe, args, project_root, "check_project")
		if id < 0:
			failures.append("%s: failed to spawn Godot" % res_path)
			continue
		var snap: Dictionary = await process_manager.wait_for_exit_or_timeout(id, PER_FILE_TIMEOUT)
		var timed_out := bool(snap.get("timed_out", false))
		if timed_out:
			process_manager.kill(id)
			failures.append("%s: check timed out after %.0fs" % [res_path, PER_FILE_TIMEOUT])
			continue
		var stdout := str(snap.get("stdout", ""))
		var stderr := str(snap.get("stderr", ""))
		var exit_code := int(snap.get("exit_code", -1))
		var combined := stdout
		if stderr != "":
			combined += ("\n" if combined != "" else "") + stderr
		if exit_code != 0 or _has_error_markers(combined):
			var annotated := _annotate_output(combined)
			var events: Array = annotated.get("events", [])
			if _is_false_positive_check(events, combined, autoload_names):
				suppressed += 1
				continue
			# Mixed run: has at least one real error and possibly some
			# autoload FPs. Strip the FPs from the reported list so the
			# model isn't told to fix things that aren't broken.
			var filtered := filter_false_positive_events(events, autoload_names)
			var real_events: Array = filtered["real"]
			var filtered_idents: PackedStringArray = filtered["filtered_idents"]
			for ident in filtered_idents:
				if not (ident in filtered_ident_names):
					filtered_ident_names.append(ident)
			all_events.append_array(real_events)
			var summary := summarize_filtered_events(real_events, filtered_idents)

			# Per-file hints (when model_profile.append_syntax_hints allows
			# it) — a file with `//` comments gets the comment-syntax hint,
			# a file with bad indentation gets the indent hint, and a file
			# with neither gets no hint block at all.
			var hints_block := ""
			if _hints_enabled():
				var hints := syntax_hints_for_events(real_events)
				if not hints.is_empty():
					hints_block = "\n\nHints (fix these before retrying):\n  - " + "\n  - ".join(hints)

			var snippet := combined.strip_edges()
			if snippet.length() > 400:
				snippet = snippet.substr(0, 400) + "…"
			if summary != "":
				failures.append("%s:\n%s%s\n---- raw ----\n%s" % [res_path, summary, hints_block, snippet])
			else:
				failures.append("%s:\n%s" % [res_path, snippet])

	var header: String
	if total == 0:
		header = "No .gd files found under %s." % raw_path
	elif total > limit:
		header = "Checked %d/%d .gd file(s) under %s (limit reached — narrow `path` to cover the rest)." % [checked, total, raw_path]
	else:
		header = "Checked %d .gd file(s) under %s." % [checked, raw_path]
	if suppressed > 0 or not filtered_ident_names.is_empty():
		var bits := PackedStringArray()
		if suppressed > 0:
			bits.append("%d fully-suppressed file(s)" % suppressed)
		if not filtered_ident_names.is_empty():
			bits.append("filtered identifier(s): %s" % ", ".join(filtered_ident_names))
		header += " (autoload false positives — %s — check-only mode can't resolve [autoload] singletons.)" % ", ".join(bits)

	var meta := {
		"checked": checked,
		"total": total,
		"failed": failures.size(),
		"suppressed": suppressed,
		"events": events_to_dicts(all_events),
		"event_count": all_events.size(),
	}

	if failures.is_empty():
		return ToolResult.ok(header + "\nAll checked scripts parsed cleanly.", meta)

	var body := header + "\n%d file(s) with problems:\n\n" % failures.size() + "\n\n".join(failures)
	return ToolResult.failure(body, ToolResult.ErrorKind.INTERNAL, meta)

func _collect_gd_files(target: String, out: Array) -> void:
	if DirAccess.dir_exists_absolute(target):
		var d := DirAccess.open(target)
		if d == null:
			return
		d.list_dir_begin()
		var n := d.get_next()
		while n != "":
			if not n.begins_with("."):
				var child := target.path_join(n)
				if d.current_is_dir():
					_collect_gd_files(child, out)
				elif n.to_lower().ends_with(".gd"):
					out.append(child)
			n = d.get_next()
		d.list_dir_end()
	else:
		if target.to_lower().ends_with(".gd"):
			out.append(target)

# Convert an absolute filesystem path (already validated to be inside
# project_root) back into a res:// path for the Godot CLI's --script arg.
func _to_res_path(absolute_path: String) -> String:
	var root := project_root.replace("\\", "/").simplify_path().rstrip("/")
	var rel := absolute_path.substr(root.length())
	if rel.begins_with("/"):
		rel = rel.substr(1)
	return "res://" + rel

# Same safety net as check_script/launch_headless — never trust exit code alone.
static func _has_error_markers(text: String) -> bool:
	return text.find("SCRIPT ERROR:") != -1 \
		or text.find("ERROR:") != -1 \
		or text.find("Failed to load script") != -1
