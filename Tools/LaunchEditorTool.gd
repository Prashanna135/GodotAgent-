class_name LaunchEditorTool
extends GodotTool

func _init() -> void:
	name = "launch_editor"
	description = "Launch the Godot editor for the current project. Returns immediately with a process id."
	required_permission = "RUN_GODOT"
	input_schema = {
		"type": "object",
		"properties": {},
	}

func execute(_arguments: Dictionary) -> ToolResult:
	if project_root == "":
		return ToolResult.invalid_argument("No project is open")
	if process_manager == null:
		return ToolResult.failure("GodotProcessManager is not available", ToolResult.ErrorKind.INTERNAL)
	var exe := _resolve_executable()
	if exe.strip_edges() == "":
		return ToolResult.invalid_argument("Godot executable is not configured")
	var args := PackedStringArray(["--path", project_root, "-e"])
	var id: int = process_manager.launch(exe, args, project_root, "editor")
	if id < 0:
		return ToolResult.io_error("Failed to spawn Godot editor: %s" % exe)
	return ToolResult.ok(
		"Launched Godot editor (process %d)" % id,
		{"process_id": id}
	)
