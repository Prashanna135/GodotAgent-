class_name CreateFileTool
extends ProjectPathTool

func _init() -> void:
	name = "create_file"
	description = "Create a new file. Fails if it already exists — use write_file/edit_file instead."
	required_permission = "WRITE_PROJECT"
	input_schema = {
		"type": "object",
		"properties": {
			"path": {"type": "string"},
			"content": {"type": "string"},
		},
		"required": ["path", "content"],
	}

func execute(arguments: Dictionary) -> ToolResult:
	var raw_path := str(arguments.get("path", ""))
	if raw_path == "":
		return ToolResult.invalid_argument("Missing required argument: path")
	var content := str(arguments.get("content", ""))
	var full := resolve_path(raw_path)
	if full == "":
		return ToolResult.sandbox_violation("Path is outside the project sandbox: %s" % raw_path)
	if FileAccess.file_exists(full):
		return ToolResult.invalid_argument("File already exists: %s (use write_file/edit_file)" % raw_path)

	var dir := full.get_base_dir()
	if not DirAccess.dir_exists_absolute(dir):
		var err := DirAccess.make_dir_recursive_absolute(dir)
		if err != OK:
			return ToolResult.io_error("Could not create directory %s (error %d)" % [dir, err])

	var f := FileAccess.open(full, FileAccess.WRITE)
	if f == null:
		return ToolResult.io_error("Cannot create file: %s (error %d)" % [raw_path, FileAccess.get_open_error()])
	f.store_string(content)
	f.close()
	return ToolResult.ok(
		"Created %s (%d bytes)" % [raw_path, content.length()],
		{"path": raw_path}
	)
