class_name ListDirectoryTool
extends ProjectPathTool

func _init() -> void:
	name = "list_directory"
	description = "List the immediate contents of a directory inside the project."
	required_permission = "READ_PROJECT"
	input_schema = {
		"type": "object",
		"properties": {
			"path": {"type": "string", "description": "Directory relative to project root, or res:// for the root"},
		},
		"required": ["path"],
	}

func execute(arguments: Dictionary) -> ToolResult:
	var raw_path := str(arguments.get("path", "res://"))
	var full := resolve_path(raw_path)
	if full == "":
		return ToolResult.failure("Path is outside the project sandbox: %s" % raw_path)
	if not DirAccess.dir_exists_absolute(full):
		return ToolResult.failure("Not a directory: %s" % raw_path)
	var d := DirAccess.open(full)
	if d == null:
		return ToolResult.failure("Cannot open directory: %s" % raw_path)
	var entries := PackedStringArray()
	d.list_dir_begin()
	var n := d.get_next()
	while n != "":
		if n.begins_with("."):
			n = d.get_next()
			continue
		var kind := "dir" if d.current_is_dir() else "file"
		entries.append("%s\t%s" % [kind, n])
		n = d.get_next()
	d.list_dir_end()
	entries.sort()
	return ToolResult.ok("\n".join(entries), {"path": raw_path, "count": entries.size()})
