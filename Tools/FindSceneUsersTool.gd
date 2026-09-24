class_name FindSceneUsersTool
extends ProjectPathTool

const MAX_RESULTS := 200
const MAX_FILE_BYTES := 1_000_000
# Same skip list used by the other project-wide walkers (SearchTextTool,
# FindFilesTool, CheckProjectTool) — .agent_scenarios (run_scenario's own
# generated files) is skipped the same way as any other dot-directory.
const SKIP_DIR_NAMES := [".godot", ".git", ".import", "__pycache__"]

func _init() -> void:
	name = "find_scene_users"
	description = (
		"Find every .tscn that instances a given scene (ext_resource) and every .gd "
		+ "file that preloads/loads it. Use before renaming, moving, or deleting a scene "
		+ "— find_references does the equivalent for a GDScript symbol, but there is no "
		+ "other way to ask 'what instances this scene?'."
	)
	required_permission = "READ_PROJECT"
	input_schema = {
		"type": "object",
		"properties": {
			"path": {"type": "string", "description": "res:// path to the scene to search for, e.g. res://scenes/Player.tscn"},
		},
		"required": ["path"],
	}

func execute(arguments: Dictionary) -> ToolResult:
	var target := str(arguments.get("path", "")).strip_edges()
	if target == "":
		return ToolResult.invalid_argument("Missing required argument: path")
	if not target.begins_with("res://"):
		target = "res://" + target.lstrip("/")

	if project_root == "":
		return ToolResult.invalid_argument("No project is open")
	var root := project_root.replace("\\", "/").simplify_path().rstrip("/")

	var matches: Array = []
	_walk(root, target, matches)

	if matches.is_empty():
		return ToolResult.ok("No references to %s found in any .tscn or .gd file." % target)

	var lines := PackedStringArray()
	for m_v in matches:
		var m: Dictionary = m_v
		lines.append("%s:%d: [%s] %s" % [str(m["file"]), int(m["line"]), str(m["kind"]), str(m["text"])])
	var header := "%d reference(s) to %s found." % [matches.size(), target]
	if matches.size() >= MAX_RESULTS:
		header = "%d+ reference(s) to %s found; showing first %d." % [matches.size(), target, MAX_RESULTS]
	return ToolResult.ok(header + "\n" + "\n".join(lines), {"total": matches.size()})

func _walk(dir: String, target: String, out: Array) -> void:
	if out.size() >= MAX_RESULTS:
		return
	var d := DirAccess.open(dir)
	if d == null:
		return
	d.list_dir_begin()
	var n := d.get_next()
	while n != "":
		if n.begins_with("."):
			n = d.get_next()
			continue
		var child := dir.path_join(n)
		if d.current_is_dir():
			if not (n in SKIP_DIR_NAMES):
				_walk(child, target, out)
		else:
			var lower := n.to_lower()
			if lower.ends_with(".tscn") or lower.ends_with(".gd"):
				_scan_file(child, target, lower.ends_with(".gd"), out)
		if out.size() >= MAX_RESULTS:
			d.list_dir_end()
			return
		n = d.get_next()
	d.list_dir_end()

func _scan_file(path: String, target: String, is_script: bool, out: Array) -> void:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return
	if f.get_length() > MAX_FILE_BYTES:
		f.close()
		return
	var text := f.get_as_text()
	f.close()
	var lines := text.split("\n")
	for i in lines.size():
		var line: String = lines[i]
		if line.find(target) == -1:
			continue
		if is_script and line.find("preload(") == -1 and line.find("load(") == -1:
			# The path string appears in the script but not inside a
			# load/preload call (e.g. it's a comment or an unrelated
			# string) — not a real reference, skip it.
			continue
		var kind := "preload/load" if is_script else "ext_resource"
		out.append({"file": path, "line": i + 1, "kind": kind, "text": line.strip_edges()})
		if out.size() >= MAX_RESULTS:
			return
