class_name GetNodePropertyTool
extends ProjectPathTool

const MAX_FILE_BYTES := 2_000_000

func _init() -> void:
	name = "get_node_property"
	description = (
		"Read one property's raw value for a specific node in a .tscn file, as written "
		+ "in the scene file. Reports 'not set in scene file' if the property isn't "
		+ "overridden there — it may still have a script/class default, which this "
		+ "tool cannot see."
	)
	required_permission = "READ_PROJECT"
	input_schema = {
		"type": "object",
		"properties": {
			"path": {"type": "string", "description": "res:// path to a .tscn file"},
			"node_path": {
				"type": "string",
				"description": "Node path as shown by find_node/inspect_scene — '.' for the scene root, the bare name for a direct root child, or 'Parent/Name' for a deeper node.",
			},
			"property": {"type": "string", "description": "Property key, e.g. 'collision_layer'"},
		},
		"required": ["path", "node_path", "property"],
	}

func execute(arguments: Dictionary) -> ToolResult:
	var raw_path := str(arguments.get("path", "")).strip_edges()
	var node_path := str(arguments.get("node_path", "")).strip_edges()
	var prop := str(arguments.get("property", "")).strip_edges()
	if raw_path == "":
		return ToolResult.invalid_argument("Missing required argument: path")
	if node_path == "":
		return ToolResult.invalid_argument("Missing required argument: node_path")
	if prop == "":
		return ToolResult.invalid_argument("Missing required argument: property")
	if not raw_path.to_lower().ends_with(".tscn"):
		return ToolResult.invalid_argument("get_node_property only supports .tscn files: %s" % raw_path)

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

	var target: TscnParser.Node_ = null
	for n_v in scene.nodes:
		var n: TscnParser.Node_ = n_v
		var is_root := n.parent == ""
		var full_path := n.name if is_root or n.parent == "." else n.parent + "/" + n.name
		if node_path == "." and is_root:
			target = n
			break
		if node_path == n.name or node_path == full_path:
			target = n
			break
	if target == null:
		return ToolResult.not_found(
			"No node '%s' found in %s. Use find_node or inspect_scene to locate it first."
			% [node_path, raw_path]
		)

	if not target.properties.has(prop):
		return ToolResult.ok(
			"'%s' is not set in %s's scene entry for node '%s' — it may be at its script/class "
			+ "default, or set at runtime."
			% [prop, raw_path, node_path]
		)
	return ToolResult.ok("%s.%s = %s" % [node_path, prop, str(target.properties[prop])])
