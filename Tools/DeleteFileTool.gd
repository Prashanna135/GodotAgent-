class_name DeleteFileTool
extends ProjectPathTool

func _init() -> void:
	name = "delete_file"
	description = "Delete a single file inside the project. Directories are not deleted."
	required_permission = "DELETE_PROJECT_FILE"
	input_schema = {
		"type": "object",
		"properties": {
			"path": {"type": "string"},
		},
		"required": ["path"],
	}

func execute(arguments: Dictionary) -> ToolResult:
	var raw_path := str(arguments.get("path", ""))
	if raw_path == "":
		return ToolResult.invalid_argument("Missing required argument: path")
	var full := resolve_path(raw_path)
	if full == "":
		return ToolResult.sandbox_violation("Path is outside the project sandbox: %s" % raw_path)
	if DirAccess.dir_exists_absolute(full):
		return ToolResult.invalid_argument("Refusing to delete a directory: %s" % raw_path)
	if not FileAccess.file_exists(full):
		return ToolResult.not_found("File not found: %s" % raw_path)

	var err := DirAccess.remove_absolute(full)
	if err != OK:
		return ToolResult.io_error("Failed to delete %s (error %d)" % [raw_path, err])
	return ToolResult.ok("Deleted %s" % raw_path, {"path": raw_path})
