class_name GodotApiLookupTool
extends GodotTool

# Roadmap §5.2 — "biggest lever against hallucinated API calls." Godot's own
# class reference is the ground truth for what methods/signals/properties a
# built-in class actually has; this tool gets at it via `godot --doctool
# <dir>`, which dumps the engine's compiled-in docs as one XML file per
# class into <dir>. That's the correct mechanism for an ordinary downloaded
# Godot build — the docs are baked into the editor binary, not shipped as
# loose XML files next to it, so there's nothing to read until this has run
# once.
#
# >>> THE --doctool INVOCATION BELOW IS UNVERIFIED. <<<
# Same caveat as bridge.py's selectors and RunScenarioTool's wrapper scene:
# I cannot run a real Godot binary to confirm the exact flags a given
# Godot 4.7.2 build expects for --doctool (whether --headless is required,
# whether it needs a --path even though it's not project-specific, exit
# code semantics). DOCTOOL_ARGS below is the single place to adjust if the
# configured Godot executable rejects the current invocation — the rest of
# the tool only depends on the cache directory ending up full of *.xml
# files, not on how it got that way.
#
# Extends GodotTool (not ProjectPathTool): it never touches project files,
# only the Godot install the harness is already configured to run — same
# trust boundary as launch_editor/launch_project/check_script, which is why
# this reuses RUN_GODOT rather than introducing a new permission.

const DOCTOOL_ARGS := ["--doctool", "--headless"]   # cache dir is inserted as DOCTOOL_ARGS[1]'s argument
const DOC_GEN_TIMEOUT := 120.0
const CACHE_SUBDIR := "godot_docs_cache"
const MAX_METHODS_SHOWN := 200
const MAX_FULL_DESC_CHARS := 4000

func _init() -> void:
	name = "godot_api_lookup"
	description = (
		"Look up a built-in Godot 4 class's real API — methods, signals, properties, "
		+ "constants — from the engine's own class reference, instead of guessing names "
		+ "from memory. First call per machine generates a local doc cache via "
		+ "`godot --doctool` (can take up to a minute); later calls are instant. Pass "
		+ "`member` to get one method/signal/property/constant's full description "
		+ "instead of the whole class summary."
	)
	required_permission = "RUN_GODOT"
	input_schema = {
		"type": "object",
		"properties": {
			"class_name": {"type": "string", "description": "Exact or approximate Godot class name, e.g. 'CharacterBody3D'"},
			"member": {"type": "string", "description": "Optional: one method/signal/property/constant name to show in full instead of the whole class summary"},
		},
		"required": ["class_name"],
	}

func execute(arguments: Dictionary) -> ToolResult:
	var exe := _resolve_executable()
	if exe.strip_edges() == "":
		return ToolResult.invalid_argument("Godot executable is not configured")
	if process_manager == null:
		return ToolResult.failure("GodotProcessManager is not available", ToolResult.ErrorKind.INTERNAL)

	var wanted := str(arguments.get("class_name", "")).strip_edges()
	if wanted == "":
		return ToolResult.invalid_argument("Missing required argument: class_name")
	var member := str(arguments.get("member", "")).strip_edges()

	var cache_dir: String = await _ensure_docs_cached(exe)
	if cache_dir == "":
		return ToolResult.failure(
			(
				"Could not generate the Godot class-doc cache (godot --doctool produced no "
				+ "*.xml output). The exact --doctool invocation this tool uses is unverified "
				+ "against a real Godot binary — see DOCTOOL_ARGS in GodotApiLookupTool.gd if "
				+ "this keeps failing. Verify the configured Godot executable in Settings runs "
				+ "at all first."
			),
			ToolResult.ErrorKind.INTERNAL
		)

	var xml_path := _find_class_xml(cache_dir, wanted)
	if xml_path == "":
		var suggestions := _suggest_class_names(cache_dir, wanted)
		var body := "No class named '%s' found in the Godot class reference." % wanted
		if not suggestions.is_empty():
			body += "\nDid you mean: %s?" % ", ".join(suggestions)
		return ToolResult.not_found(body)

	var parsed := _parse_class_xml(xml_path)
	if parsed.is_empty() or str(parsed.get("name", "")) == "":
		return ToolResult.failure("Could not parse class doc XML: %s" % xml_path, ToolResult.ErrorKind.INTERNAL)

	if member != "":
		return _describe_member(parsed, member)
	return _describe_class(parsed)

# --- doc cache generation ------------------------------------------------

# Regenerates the cache only when it's missing/empty or the recorded
# executable (stored in a marker file alongside the XML) no longer matches
# the one configured in Settings — so switching Godot versions/installs
# invalidates a stale cache instead of silently serving the wrong docs.
func _ensure_docs_cached(exe: String) -> String:
	var cache_dir := OS.get_user_data_dir().path_join(CACHE_SUBDIR)
	var marker := cache_dir.path_join("_source.txt")
	if DirAccess.dir_exists_absolute(cache_dir) and FileAccess.file_exists(marker):
		var mf := FileAccess.open(marker, FileAccess.READ)
		if mf != null:
			var recorded := mf.get_as_text().strip_edges()
			mf.close()
			if recorded == exe and _has_any_xml(cache_dir):
				return cache_dir

	if not DirAccess.dir_exists_absolute(cache_dir):
		DirAccess.make_dir_recursive_absolute(cache_dir)

	var args := PackedStringArray([DOCTOOL_ARGS[0], cache_dir, DOCTOOL_ARGS[1]])
	var id: int = process_manager.launch(exe, args, "", "doctool")
	if id < 0:
		return ""
	await process_manager.wait_for_exit_or_timeout(id, DOC_GEN_TIMEOUT)

	if not _has_any_xml(cache_dir):
		return ""

	var wf := FileAccess.open(marker, FileAccess.WRITE)
	if wf != null:
		wf.store_string(exe)
		wf.close()
	return cache_dir

static func _has_any_xml(dir: String) -> bool:
	var d := DirAccess.open(dir)
	if d == null:
		return false
	d.list_dir_begin()
	var n := d.get_next()
	var found := false
	while n != "":
		if n.to_lower().ends_with(".xml"):
			found = true
			break
		n = d.get_next()
	d.list_dir_end()
	return found

# --- class file lookup ----------------------------------------------------

func _find_class_xml(cache_dir: String, wanted: String) -> String:
	var direct := cache_dir.path_join(wanted + ".xml")
	if FileAccess.file_exists(direct):
		return direct
	var d := DirAccess.open(cache_dir)
	if d == null:
		return ""
	var lower_wanted := wanted.to_lower()
	d.list_dir_begin()
	var n := d.get_next()
	var found := ""
	while n != "":
		if n.to_lower() == lower_wanted + ".xml":
			found = cache_dir.path_join(n)
			break
		n = d.get_next()
	d.list_dir_end()
	return found

func _suggest_class_names(cache_dir: String, wanted: String) -> PackedStringArray:
	var out := PackedStringArray()
	var d := DirAccess.open(cache_dir)
	if d == null:
		return out
	var needle := wanted.to_lower()
	d.list_dir_begin()
	var n := d.get_next()
	while n != "":
		if n.to_lower().ends_with(".xml"):
			var stem := n.substr(0, n.length() - 4)
			if stem.to_lower().find(needle) != -1:
				out.append(stem)
				if out.size() >= 8:
					break
		n = d.get_next()
	d.list_dir_end()
	return out

# --- XML parsing ------------------------------------------------------
#
# XMLParser is a flat event stream (NODE_ELEMENT / NODE_TEXT /
# NODE_ELEMENT_END), not a tree — `current` holds the method/signal/member/
# constant currently being built, and `text_target` says where the next
# text event should accumulate. Good enough for Godot's own doc XML shape;
# not a general XML parser.

func _parse_class_xml(path: String) -> Dictionary:
	var parser := XMLParser.new()
	if parser.open(path) != OK:
		return {}

	var result := {
		"name": "", "inherits": "",
		"brief": "", "description": "",
		"methods": [], "signals": [], "members": [], "constants": [],
	}

	var section := ""
	var current: Dictionary = {}
	var current_params: Array = []
	var text_target := ""   # "brief" | "description" | "" (item text always goes to `current`)

	while parser.read() == OK:
		var node_type := parser.get_node_type()

		if node_type == XMLParser.NODE_ELEMENT:
			var tag := parser.get_node_name()

			match tag:
				"class":
					result["name"] = parser.get_named_attribute_value_safe("name")
					result["inherits"] = parser.get_named_attribute_value_safe("inherits")
				"brief_description":
					text_target = "brief"
				"description":
					text_target = "item_description" if not current.is_empty() else "description"
				"methods", "signals", "members", "constants":
					section = tag
				"method":
					current = {"name": parser.get_named_attribute_value_safe("name"), "qualifiers": parser.get_named_attribute_value_safe("qualifiers"), "return": "void", "description": ""}
					current_params = []
				"signal":
					current = {"name": parser.get_named_attribute_value_safe("name"), "description": ""}
					current_params = []
				"member":
					current = {
						"name": parser.get_named_attribute_value_safe("name"),
						"type": parser.get_named_attribute_value_safe("type"),
						"default": parser.get_named_attribute_value_safe("default"),
						"description": "",
					}
				"constant":
					current = {
						"name": parser.get_named_attribute_value_safe("name"),
						"value": parser.get_named_attribute_value_safe("value"),
						"enum": parser.get_named_attribute_value_safe("enum"),
						"description": "",
					}
				"return":
					if not current.is_empty():
						current["return"] = parser.get_named_attribute_value_safe("type")
				"param":
					current_params.append({
						"name": parser.get_named_attribute_value_safe("name"),
						"type": parser.get_named_attribute_value_safe("type"),
						"default": parser.get_named_attribute_value_safe("default"),
					})

		elif node_type == XMLParser.NODE_TEXT:
			var data := parser.get_node_data()
			if data.strip_edges() == "":
				pass
			elif text_target == "brief":
				result["brief"] = str(result.get("brief", "")) + data
			elif text_target == "description" and current.is_empty():
				result["description"] = str(result.get("description", "")) + data
			elif not current.is_empty():
				# Inline text directly under <member>/<constant>, or text
				# inside a nested <description> for <method>/<signal> —
				# either shape is this item's own description.
				current["description"] = str(current.get("description", "")) + data

		elif node_type == XMLParser.NODE_ELEMENT_END:
			var closing := parser.get_node_name()
			match closing:
				"brief_description", "description":
					text_target = ""
				"method":
					current["signature"] = _format_method_signature(current, current_params)
					current["description"] = _clean_text(str(current.get("description", "")))
					(result["methods"] as Array).append(current)
					current = {}
					current_params = []
				"signal":
					current["signature"] = _format_signal_signature(current, current_params)
					current["description"] = _clean_text(str(current.get("description", "")))
					(result["signals"] as Array).append(current)
					current = {}
					current_params = []
				"member":
					current["description"] = _clean_text(str(current.get("description", "")))
					(result["members"] as Array).append(current)
					current = {}
				"constant":
					current["description"] = _clean_text(str(current.get("description", "")))
					(result["constants"] as Array).append(current)
					current = {}
				"methods", "signals", "members", "constants":
					section = ""

	result["brief"] = _clean_text(str(result.get("brief", "")))
	result["description"] = _clean_text(str(result.get("description", "")))
	return result

# Doc XML wraps prose across many lines with leading tabs/spaces per line
# (it's hand-formatted engine source) — collapse that back into normal
# paragraph text instead of handing the model a wall of ragged-indented
# lines.
static func _clean_text(s: String) -> String:
	var collapsed := s.strip_edges()
	var re := RegEx.new()
	re.compile("[ \\t]*\\n[ \\t]*")
	collapsed = re.sub(collapsed, " ", true)
	re = RegEx.new()
	re.compile("[ \\t]{2,}")
	return re.sub(collapsed, " ", true)

static func _format_method_signature(m: Dictionary, params: Array) -> String:
	var parts := PackedStringArray()
	for p_v in params:
		var p: Dictionary = p_v
		var seg := "%s: %s" % [str(p.get("name", "")), str(p.get("type", ""))]
		var dflt := str(p.get("default", ""))
		if dflt != "":
			seg += " = " + dflt
		parts.append(seg)
	var qualifiers := str(m.get("qualifiers", "")).strip_edges()
	var qual_note := "  [%s]" % qualifiers if qualifiers != "" else ""
	return "%s(%s) -> %s%s" % [str(m.get("name", "")), ", ".join(parts), str(m.get("return", "void")), qual_note]

static func _format_signal_signature(s: Dictionary, params: Array) -> String:
	var parts := PackedStringArray()
	for p_v in params:
		var p: Dictionary = p_v
		parts.append("%s: %s" % [str(p.get("name", "")), str(p.get("type", ""))])
	return "%s(%s)" % [str(s.get("name", "")), ", ".join(parts)]

# --- output formatting --------------------------------------------------

func _describe_class(c: Dictionary) -> ToolResult:
	var out := PackedStringArray()
	out.append("class %s extends %s" % [str(c.get("name", "")), str(c.get("inherits", "")) if str(c.get("inherits", "")) != "" else "(none)"])
	var brief := str(c.get("brief", ""))
	if brief != "":
		out.append(brief)

	var methods: Array = c.get("methods", [])
	if not methods.is_empty():
		out.append("\nMethods (%d):" % methods.size())
		var shown: Array = methods.slice(0, MAX_METHODS_SHOWN)
		for m_v in shown:
			var m: Dictionary = m_v
			out.append("  " + str(m.get("signature", "")))
		if methods.size() > shown.size():
			out.append("  … %d more (call again with `member` to see one by name)" % (methods.size() - shown.size()))

	var signals_arr: Array = c.get("signals", [])
	if not signals_arr.is_empty():
		out.append("\nSignals (%d):" % signals_arr.size())
		for s_v in signals_arr:
			var s: Dictionary = s_v
			out.append("  " + str(s.get("signature", "")))

	var members: Array = c.get("members", [])
	if not members.is_empty():
		out.append("\nProperties (%d):" % members.size())
		for mm_v in members:
			var mm: Dictionary = mm_v
			var dflt := str(mm.get("default", ""))
			var dflt_note := " = %s" % dflt if dflt != "" else ""
			out.append("  %s: %s%s" % [str(mm.get("name", "")), str(mm.get("type", "")), dflt_note])

	var constants: Array = c.get("constants", [])
	if not constants.is_empty():
		out.append("\nConstants (%d):" % constants.size())
		for cc_v in constants:
			var cc: Dictionary = cc_v
			out.append("  %s = %s" % [str(cc.get("name", "")), str(cc.get("value", ""))])

	out.append("\n(Call again with member: \"<name>\" for a method/signal/property/constant's full description.)")
	return ToolResult.ok("\n".join(out), {
		"class": str(c.get("name", "")),
		"method_count": methods.size(),
		"signal_count": signals_arr.size(),
		"member_count": members.size(),
		"constant_count": constants.size(),
	})

func _describe_member(c: Dictionary, member: String) -> ToolResult:
	var needle := member.to_lower()
	for section_key in ["methods", "signals", "members", "constants"]:
		var arr: Array = c.get(section_key, [])
		for item_v in arr:
			var item: Dictionary = item_v
			if str(item.get("name", "")).to_lower() == needle:
				return ToolResult.ok(_render_member(c, section_key, item))
	return ToolResult.not_found(
		"'%s' has no method/signal/property/constant named '%s'." % [str(c.get("name", "")), member]
	)

func _render_member(c: Dictionary, section_key: String, item: Dictionary) -> String:
	var header := "%s.%s" % [str(c.get("name", "")), str(item.get("name", ""))]
	var lines := PackedStringArray()
	match section_key:
		"methods":
			lines.append("method  " + header)
			lines.append(str(item.get("signature", "")))
		"signals":
			lines.append("signal  " + header)
			lines.append(str(item.get("signature", "")))
		"members":
			lines.append("property  " + header)
			var dflt := str(item.get("default", ""))
			lines.append("%s%s" % [str(item.get("type", "")), (" = %s" % dflt) if dflt != "" else ""])
		"constants":
			lines.append("constant  " + header)
			lines.append("= %s" % str(item.get("value", "")))
	var desc := str(item.get("description", ""))
	if desc != "":
		if desc.length() > MAX_FULL_DESC_CHARS:
			desc = desc.substr(0, MAX_FULL_DESC_CHARS) + "…"
		lines.append("")
		lines.append(desc)
	return "\n".join(lines)
