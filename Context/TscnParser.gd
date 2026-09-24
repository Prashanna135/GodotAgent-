class_name TscnParser
extends RefCounted

# Lightweight, best-effort parser for Godot .tscn (and .tres) text format.
# Not a full resource loader — does not resolve UIDs, does not load binary
# data, does not validate correctness. It exists so the agent can answer
# "what does this scene look like" without reading 40+ lines of raw
# ext_resource/sub_resource syntax and re-deriving the node tree from it
# by eye every time.
#
# Godot's .tscn format: a header line `[section_name key="value" ...]`
# followed by zero or more `key = value` property lines, repeated until
# the next `[` header or end of file. Sections handled here:
#   gd_scene / gd_resource — the file's own header (load_steps, format)
#   ext_resource           — external resource references (scripts, scenes)
#   sub_resource           — inline resource definitions
#   node                   — a node in the tree
#
# `connection` sections and anything else are skipped — not needed by the
# tools built on top of this parser yet.

class Node_:
	extends RefCounted
	var name: String = ""
	var type: String = ""          # "" if this node instances another scene
	var parent: String = ""        # "" for the scene root, "." for its direct
									# children, "A/B" for deeper nodes
	var instance_id: String = ""   # ExtResource id, if this node instances a scene
	var script_id: String = ""     # ExtResource/SubResource id of an attached script
	var properties: Dictionary = {}
	var line: int = 0

class ExtRes:
	extends RefCounted
	var id: String = ""
	var type: String = ""
	var path: String = ""
	var uid: String = ""

class SubRes:
	extends RefCounted
	var id: String = ""
	var type: String = ""

class ParsedScene:
	extends RefCounted
	var format: int = 0
	var load_steps: int = 0
	var nodes: Array = []          # Array[Node_], file order (root first)
	var ext_resources: Array = []  # Array[ExtRes]
	var sub_resources: Array = []  # Array[SubRes]
	var parse_ok: bool = false

static var _header_re: RegEx = null
static var _attr_re: RegEx = null
static var _ref_re: RegEx = null

static func parse(text: String) -> ParsedScene:
	var result := ParsedScene.new()
	if text.strip_edges() == "":
		return result

	if _header_re == null:
		_header_re = RegEx.new()
		_header_re.compile("^\\[(\\w+)(.*)\\]\\s*$")
	if _attr_re == null:
		_attr_re = RegEx.new()
		# key="quoted value"  OR  key=bareword/number/ExtResource(...)/SubResource(...)
		_attr_re.compile("(\\w+)=(\"(?:[^\"\\\\]|\\\\.)*\"|[^\\s]+)")

	var lines := text.split("\n")
	var current_node: Node_ = null

	for i in lines.size():
		var raw: String = lines[i]
		var line := raw.strip_edges()
		if line == "":
			continue
		var hm := _header_re.search(line)
		if hm != null:
			current_node = null
			var section := hm.get_string(1)
			var attrs := _parse_attrs(hm.get_string(2))
			match section:
				"gd_scene", "gd_resource":
					result.format = int(str(attrs.get("format", "0")))
					result.load_steps = int(str(attrs.get("load_steps", "0")))
					result.parse_ok = true
				"ext_resource":
					var er := ExtRes.new()
					er.id = _unquote(attrs.get("id", ""))
					er.type = _unquote(attrs.get("type", ""))
					er.path = _unquote(attrs.get("path", ""))
					er.uid = _unquote(attrs.get("uid", ""))
					result.ext_resources.append(er)
				"sub_resource":
					var sr := SubRes.new()
					sr.id = _unquote(attrs.get("id", ""))
					sr.type = _unquote(attrs.get("type", ""))
					result.sub_resources.append(sr)
				"node":
					var n := Node_.new()
					n.name = _unquote(attrs.get("name", ""))
					n.type = _unquote(attrs.get("type", ""))
					n.parent = _unquote(attrs.get("parent", ""))
					n.instance_id = _extract_ref_id(str(attrs.get("instance", "")))
					n.line = i + 1
					result.nodes.append(n)
					current_node = n
				_:
					pass
			continue

		# Property line inside the current [node] section. Sub/ext resource
		# bodies (also `key = value` shaped) are skipped — nothing built on
		# this parser needs their contents yet.
		if current_node != null:
			var eq := line.find("=")
			if eq > 0:
				var key := line.substr(0, eq).strip_edges()
				var val := line.substr(eq + 1).strip_edges()
				current_node.properties[key] = val
				if key == "script":
					current_node.script_id = _extract_ref_id(val)

	return result

static func _parse_attrs(rest: String) -> Dictionary:
	var out: Dictionary = {}
	if _attr_re == null:
		return out
	var pos := 0
	while true:
		var m := _attr_re.search(rest, pos)
		if m == null:
			break
		out[m.get_string(1)] = m.get_string(2)
		pos = m.get_end()
	return out

static func _unquote(v) -> String:
	var s := str(v)
	if s.length() >= 2 and s.begins_with("\"") and s.ends_with("\""):
		return s.substr(1, s.length() - 2)
	return s

# Extracts the id out of `ExtResource("2")`, `SubResource("3")`, or the
# Godot-4-style string id `ExtResource("2_abcde")`. Returns "" if `val`
# doesn't look like a resource reference.
static func _extract_ref_id(val: String) -> String:
	if val == "":
		return ""
	if _ref_re == null:
		_ref_re = RegEx.new()
		_ref_re.compile("(?:Ext|Sub)Resource\\(\\s*\"?([^\")]+)\"?\\s*\\)")
	var m := _ref_re.search(val)
	if m != null:
		return m.get_string(1)
	return ""

static func resolve_ext_path(scene: ParsedScene, id: String) -> String:
	if id == "":
		return ""
	for er_v in scene.ext_resources:
		var er: ExtRes = er_v
		if er.id == id:
			return er.path
	return "(unresolved id %s)" % id

# --- rendering helpers used by the tools built on top of this parser ---

# Renders the node tree as an indented outline, e.g.:
#   CharacterBody3D 'Pesents'  [script: pesents.gd]
#     MeshInstance3D 'Medieval'
#     AnimationPlayer 'AnimationPlayer'
#   Node3D 'Enemies'  [instances: enemy_camp.tscn]
#
# Depth is derived from the `parent` path alone (it is not a real tree
# walk) — good enough for a readable outline, not guaranteed correct on a
# scene with unusual/reordered node declarations.
static func render_tree(scene: ParsedScene) -> String:
	if scene.nodes.is_empty():
		return "(no nodes found)"
	var lines := PackedStringArray()
	for n_v in scene.nodes:
		var n: Node_ = n_v
		var depth := 0
		if n.parent != "":
			depth = 1 if n.parent == "." else n.parent.split("/").size() + 1
		var indent := "  ".repeat(depth)
		var label := n.type if n.type != "" else "(instance)"
		var notes := ""
		if n.script_id != "":
			var sp := resolve_ext_path(scene, n.script_id)
			notes += "  [script: %s]" % (sp.get_file() if sp != "" else "?")
		if n.instance_id != "":
			var ip := resolve_ext_path(scene, n.instance_id)
			notes += "  [instances: %s]" % (ip.get_file() if ip != "" else "?")
		lines.append("%s%s '%s'%s" % [indent, label, n.name, notes])
	return "\n".join(lines)
