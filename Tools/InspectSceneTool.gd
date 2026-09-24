class_name InspectSceneTool
extends ProjectPathTool

const MAX_FILE_BYTES := 2_000_000

func _init() -> void:
	name = "inspect_scene"
	description = (
		"Parse a .tscn file and return its node tree (name/type/script/instanced-scene) "
		+ "plus its external resource list, instead of raw resource syntax. Use before "
		+ "editing an unfamiliar scene."
	)
	required_permission = "READ_PROJECT"
	input_schema = {
		"type": "object",
		"properties": {
			"path": {"type": "string", "description": "res:// path to a .tscn file"},
		},
		"required": ["path"],
	}

func execute(arguments: Dictionary) -> ToolResult:
	var raw_path := str(arguments.get("path", "")).strip_edges()
	if raw_path == "":
		return ToolResult.invalid_argument("Missing required argument: path")
	if not raw_path.to_lower().ends_with(".tscn"):
		return ToolResult.invalid_argument("inspect_scene only supports .tscn files: %s" % raw_path)

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
		return ToolResult.failure(
			"Could not find a [gd_scene] header in %s — is this a valid scene file?" % raw_path,
			ToolResult.ErrorKind.INTERNAL
		)

	var body := "Scene: %s (format %d, %d node(s), %d ext_resource(s))\n\n" % [
		raw_path, scene.format, scene.nodes.size(), scene.ext_resources.size()
	]
	body += TscnParser.render_tree(scene)

	if not scene.ext_resources.is_empty():
		body += "\n\nExternal resources:\n"
		var er_lines := PackedStringArray()
		for er_v in scene.ext_resources:
			var er: TscnParser.ExtRes = er_v
			er_lines.append("  [%s] %s (%s)" % [er.id, er.path, er.type])
		body += "\n".join(er_lines)

	return ToolResult.ok(body, {
		"path": raw_path,
		"node_count": scene.nodes.size(),
		"ext_resource_count": scene.ext_resources.size(),
	})
