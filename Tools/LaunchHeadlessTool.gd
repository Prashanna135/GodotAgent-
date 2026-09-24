class_name LaunchHeadlessTool
extends GodotTool

const DEFAULT_DURATION := 15.0
const HARD_CAP := 120.0

func _init() -> void:
	name = "launch_headless"
	description = (
		"Run the project headlessly, capturing stdout/stderr, to verify it boots "
		+ "without errors. Only parses scripts reachable from the boot scene — use "
		+ "check_project instead to syntax-check every .gd file directly."
	)
	required_permission = "RUN_GODOT"
	input_schema = {
		"type": "object",
		"properties": {
			"duration": {"type": "number", "description": "Seconds to let the project run (default 15, max 120)."},
			"scene": {"type": "string", "description": "Optional res:// path to a scene to run."},
			"extra_args": {"type": "array", "items": {"type": "string"}},
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

	var duration := float(arguments.get("duration", DEFAULT_DURATION))
	if duration <= 0.0 or duration > HARD_CAP:
		duration = DEFAULT_DURATION
	var frames := int(clamp(duration * 60.0, 30.0, 7200.0))

	var args := PackedStringArray([
		"--path", project_root,
		"--headless",
		"--quit-after", str(frames),
	])
	var scene := str(arguments.get("scene", "")).strip_edges()
	if scene != "":
		args.append(scene)
	if arguments.has("extra_args") and typeof(arguments["extra_args"]) == TYPE_ARRAY:
		for v in arguments["extra_args"]:
			args.append(str(v))

	var id: int = process_manager.launch(exe, args, project_root, "headless")
	if id < 0:
		return ToolResult.io_error("Failed to spawn headless Godot: %s" % exe)

	var snap: Dictionary = await process_manager.wait_for_exit_or_timeout(id, duration + 8.0)
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

	var annotated := _annotate_output(combined)
	var events: Array = annotated.get("events", [])
	var summary: String = str(annotated.get("text", ""))

	var meta := {
		"process_id": id,
		"exit_code": exit_code,
		"timed_out": timed_out,
		"events": events_to_dicts(events),
		"event_count": events.size(),
	}

	if timed_out:
		var body := "Headless run timed out after %.1fs (process killed)." % duration
		if summary != "":
			body += "\n" + summary
		body += "\n---- raw output ----\n" + combined
		return ToolResult.ok(body, meta)

	# Godot's process exit code is NOT reliable for script parse/load errors —
	# it will happily exit 0 after printing "ERROR: Failed to load script ..."
	# to stderr if the failing script isn't the one blocking the main loop.
	# Always scan the captured output, not just the exit code.
	if _has_error_markers(combined):
		meta["had_error_markers"] = true
		var body := (
			"Headless run exited %d, but the output contains Godot ERROR lines — "
			+ "treating this as a failed run regardless of exit code."
		) % exit_code
		if summary != "":
			body += "\n" + summary
			if _hints_enabled():
				var hints := syntax_hints_for_events(events)
				if not hints.is_empty():
					body += "\n\nHints (fix these before retrying):\n  - " + "\n  - ".join(hints)
			body += "\n---- raw output ----\n" + combined
		else:
			body += "\n" + combined
		return ToolResult.failure(body, ToolResult.ErrorKind.INTERNAL, meta)

	if exit_code == 0:
		var body := "Headless run completed (exit 0)."
		if summary != "":
			body += "\n" + summary
		elif combined.strip_edges() != "":
			body += "\n" + combined
		return ToolResult.ok(body, meta)

	var body := "Headless run exited with code %d." % exit_code
	if summary != "":
		body += "\n" + summary + "\n---- raw output ----\n" + combined
	else:
		body += "\n" + combined
	return ToolResult.failure(body, ToolResult.ErrorKind.INTERNAL, meta)

# Godot's engine-level error lines always contain one of these markers,
# regardless of the process's final exit code.
static func _has_error_markers(text: String) -> bool:
	return text.find("SCRIPT ERROR:") != -1 \
		or text.find("ERROR:") != -1 \
		or text.find("Failed to load script") != -1
