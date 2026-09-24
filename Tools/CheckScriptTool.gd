class_name CheckScriptTool
extends GodotTool

# Script checks should be near-instant; keep the cap well below
# launch_headless's default so a hung Godot process doesn't stall the loop.
const CHECK_TIMEOUT := 20.0

func _init() -> void:
	name = "check_script"
	description = (
		"Validate a single .gd file for parse/compile errors without booting the "
		+ "project. Fast — prefer right after editing a .gd file, before "
		+ "launch_headless. Can't resolve autoload singletons, so 'Identifier not "
		+ "found' errors for autoload names are filtered as false positives."
	)
	required_permission = "RUN_GODOT"
	input_schema = {
		"type": "object",
		"properties": {
			"path": {"type": "string", "description": "res:// path to a .gd file"},
		},
		"required": ["path"],
	}

func execute(arguments: Dictionary) -> ToolResult:
	if project_root == "":
		return ToolResult.invalid_argument("No project is open")
	if process_manager == null:
		return ToolResult.failure("GodotProcessManager is not available", ToolResult.ErrorKind.INTERNAL)

	var raw_path := str(arguments.get("path", "")).strip_edges()
	if raw_path == "":
		return ToolResult.invalid_argument("Missing required argument: path")

	var full := resolve_path(raw_path)
	if full == "":
		return ToolResult.sandbox_violation("Path is outside the project sandbox: %s" % raw_path)
	if not FileAccess.file_exists(full):
		return ToolResult.not_found("File not found: %s" % raw_path)
	if not full.to_lower().ends_with(".gd"):
		return ToolResult.invalid_argument("check_script only supports .gd files: %s" % raw_path)

	var exe := _resolve_executable()
	if exe.strip_edges() == "":
		return ToolResult.invalid_argument("Godot executable is not configured")

	var res_path := _to_res_path(full)
	var args := PackedStringArray([
		"--path", project_root,
		"--headless",
		"--check-only",
		"--script", res_path,
	])

	var id: int = process_manager.launch(exe, args, project_root, "check_script")
	if id < 0:
		return ToolResult.io_error("Failed to spawn Godot for check_script: %s" % exe)

	var snap: Dictionary = await process_manager.wait_for_exit_or_timeout(id, CHECK_TIMEOUT)
	var timed_out := bool(snap.get("timed_out", false))
	if timed_out:
		process_manager.kill(id)

	var stdout := str(snap.get("stdout", ""))
	var stderr := str(snap.get("stderr", ""))
	var exit_code := int(snap.get("exit_code", -1))
	var combined := stdout
	if stderr != "":
		if combined != "" and not combined.ends_with("\n"):
			combined += "\n"
		combined += "[stderr]\n" + stderr

	# Structured summary of whatever the parser could recognize. Empty when
	# the parser found nothing; callers fall back to raw text in that case.
	var annotated := _annotate_output(combined)
	var events: Array = annotated.get("events", [])
	var summary: String = str(annotated.get("text", ""))

	# If this is going to be reported as a real failure, strip autoload FP
	# events out of both the summary shown to the model and the events list
	# stored in metadata — those aren't things the model should try to fix.
	# The whole-run check below decides between "OK, all FPs" and "failure".
	var has_errors := _has_error_markers(combined)
	var autoload_names: Array = []
	if has_errors:
		autoload_names = _load_autoload_names()
		if not _is_false_positive_check(events, combined, autoload_names):
			var filtered := filter_false_positive_events(events, autoload_names)
			events = filtered["real"]
			var filtered_idents: PackedStringArray = filtered["filtered_idents"]
			summary = summarize_filtered_events(events, filtered_idents)

	var meta := {
		"process_id": id,
		"exit_code": exit_code,
		"timed_out": timed_out,
		"path": raw_path,
		"events": events_to_dicts(events),
		"event_count": events.size(),
	}

	if timed_out:
		var body := "check_script timed out after %.0fs on %s (process killed)." % [CHECK_TIMEOUT, raw_path]
		if summary != "":
			body += "\n" + summary
		body += "\n---- raw output ----\n" + combined
		return ToolResult.timeout(body, meta)

	if has_errors:
		if _is_false_positive_check(events, combined, autoload_names):
			meta["autoload_false_positive_suppressed"] = true
			return ToolResult.ok(_build_false_positive_message(raw_path, events, autoload_names), meta)

	if exit_code == 0 and not has_errors:
		var body := "No parse/compile errors in %s." % raw_path
		if summary != "":
			body += "\n" + summary
		elif combined.strip_edges() != "":
			body += "\n" + combined
		return ToolResult.ok(body, meta)

	# Failure path — include the structured summary, then any error-specific
	# hints (when model_profile.append_syntax_hints allows it — see
	# GodotTool._hints_enabled()), then the raw output.
	var fail_body := "check_script found problems in %s (exit %d)." % [raw_path, exit_code]
	if summary != "":
		fail_body += "\n" + summary
		if _hints_enabled():
			var hints := syntax_hints_for_events(events)
			if not hints.is_empty():
				fail_body += "\n\nHints (fix these before retrying):\n  - " + "\n  - ".join(hints)
		fail_body += "\n---- raw output ----\n" + combined
	else:
		fail_body += "\n" + combined
	return ToolResult.failure(fail_body, ToolResult.ErrorKind.INTERNAL, meta)

# The success-with-suppressed-false-positives message is the one most likely
# to be misread by a small model, so it's built separately and carefully:
# no error lines, no "ERROR" tokens, explicit "OK" prefix, and a direct
# instruction not to try to fix the referenced autoload.
#
# It also has to be honest about the scope: check-only on X only proves X
# itself is clean. If a referenced autoload is broken, check-only on X
# reports the same "Identifier not found: <autoload>" that a healthy
# autoload produces — the two are indistinguishable without separately
# checking the autoload file. So the message points the model at the
# autoload file explicitly, rather than claiming the project is fine.
func _build_false_positive_message(raw_path: String, events: Array, autoload_names: Array) -> String:
	var idents := _collect_suppressed_idents(events, autoload_names)
	var body := "OK — no parse/compile errors in %s itself." % raw_path
	if idents != "":
		var plural := idents.find(",") != -1
		body += (
			"\n(Autoload reference%s filtered as check-only false positive%s: %s. "
			+ "Declared in project.godot's [autoload] section; not a real error in this file. "
			+ "Do not edit this file to 'fix' them.)"
		) % [("s" if plural else ""), ("s" if plural else ""), idents]
		body += (
			"\nNOTE: this only proves %s is clean. If the autoload script%s above %s "
			+ "not already checked this task, verify %s directly — a broken autoload "
			+ "produces this exact same pattern in every file that references it, "
			+ "so an all-clear here does not mean the autoload is fine."
		) % [
			raw_path,
			("s" if plural else ""),
			("have" if plural else "has"),
			("them" if plural else "it"),
		]
	return body

# Which autoload names actually triggered the suppression. Used purely to
# make the success message concrete, so the model knows exactly which
# identifier was skipped rather than being told generically "there were
# false positives."
static func _collect_suppressed_idents(events: Array, autoload_names: Array) -> String:
	var found: PackedStringArray = PackedStringArray()
	for e in events:
		var ev := e as DebugEvent
		if ev == null or ev.severity != DebugEvent.Severity.ERROR:
			continue
		var ident := ErrorParser.extract_missing_identifier(ev.message)
		if ident != "" and (ident in autoload_names) and not (ident in found):
			found.append(ident)
	return ", ".join(found)

# Same safety net as LaunchHeadlessTool — never trust exit code alone.
static func _has_error_markers(text: String) -> bool:
	return text.find("SCRIPT ERROR:") != -1 \
		or text.find("ERROR:") != -1 \
		or text.find("Failed to load script") != -1

# Convert an absolute filesystem path (already validated to be inside
# project_root) back into a res:// path for the Godot CLI's --script arg.
func _to_res_path(absolute_path: String) -> String:
	var root := project_root.replace("\\", "/").simplify_path().rstrip("/")
	var rel := absolute_path.substr(root.length())
	if rel.begins_with("/"):
		rel = rel.substr(1)
	return "res://" + rel
