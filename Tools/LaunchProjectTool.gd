class_name LaunchProjectTool
extends GodotTool

func _init() -> void:
	name = "launch_project"
	description = "Run the current project (main scene) with Godot. Returns immediately with a process id."
	required_permission = "RUN_GODOT"
	input_schema = {
		"type": "object",
		"properties": {
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

	var args := PackedStringArray(["--path", project_root])
	var scene := str(arguments.get("scene", "")).strip_edges()
	if scene != "":
		args.append(scene)
	if arguments.has("extra_args") and typeof(arguments["extra_args"]) == TYPE_ARRAY:
		for v in arguments["extra_args"]:
			args.append(str(v))

	var id: int = process_manager.launch(exe, args, project_root, "project")
	if id < 0:
		return ToolResult.io_error("Failed to spawn project: %s" % exe)
	return ToolResult.ok(
		"Launched project (process %d)" % id,
		{"process_id": id}
	)
