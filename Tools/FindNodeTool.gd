class_name FindNodeTool
extends ProjectPathTool

const MAX_FILE_BYTES := 2_000_000

func _init() -> void:
	name = "find_node"
	description = (
		"Find node(s) in a .tscn scene by name or type substring (case-insensitive). "
		+ "Reports each match's parent path, so you know where it lives in the tree. "
		+ "Companion to inspect_scene — use this when you already know roughly what "
		+ "you're looking for."
	)
	required_permission = "READ_PROJECT"
	input_schema = {
		"type": "object",
		"properties": {
			"path": {"type": "string", "description": "res:// path to a .tscn file"},
			"query": {"type": "string", "description": "Substring to match against node name or type"},
		},
		"required": ["path", "query"],
	}

func execute(arguments: Dictionary) -> ToolResult:
	var raw_path := str(arguments.get("path", "")).strip_edges()
	var query := str(arguments.get("query", "")).strip_edges()
	if raw_path == "":
		return ToolResult.invalid_argument("Missing required argument: path")
	if query == "":
		return ToolResult.invalid_argument("Missing required argument: query")
	if not raw_path.to_lower().ends_with(".tscn"):
		return ToolResult.invalid_argument("find_node only supports .tscn files: %s" % raw_path)

	var full := resolve_path(raw_path)
	if full == "":
		return ToolResult.sandbox_violation("Path is outside the project sandbox: %s" % raw_path)
	if not FileAccess.file_exists(full):
		return ToolResult.not_found("File not found: %s" % raw_path)

	var f := FileAccess.open(full, FileAccess.READ)
	if f == null:
		return ToolResult.io_error("Cannot open file: %s (error %d)" % [raw_path, FileAccess.get_open_error()])
	if f.get_length() > MAX_FILE_BYTES:
		f.close()
		return ToolResult.invalid_argument("%s is too large to parse (%d bytes)." % [raw_path, f.get_length()])
	var text := f.get_as_text()
	f.close()

	var scene := TscnParser.parse(text)
	if not scene.parse_ok:
		return ToolResult.failure("Could not parse %s as a scene." % raw_path, ToolResult.ErrorKind.INTERNAL)

	var needle := query.to_lower()
	var matches := PackedStringArray()
	for n_v in scene.nodes:
		var n: TscnParser.Node_ = n_v
		if n.name.to_lower().find(needle) != -1 or n.type.to_lower().find(needle) != -1:
			var parent_desc := "root" if n.parent == "" else n.parent
			var type_label := n.type if n.type != "" else "(instance)"
			matches.append("line %d: %s '%s' (parent: %s)" % [n.line, type_label, n.name, parent_desc])

	if matches.is_empty():
		return ToolResult.ok(
			"No nodes matching '%s' found in %s.\n(If you were guessing at a name, "
			+ "inspect_scene shows the full tree.)" % [query, raw_path]
		)
	return ToolResult.ok(
		"%d node(s) matching '%s' in %s:\n%s" % [matches.size(), query, raw_path, "\n".join(matches)],
		{"total": matches.size()}
	)
