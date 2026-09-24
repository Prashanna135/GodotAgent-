class_name FindRpcCallsTool
extends ProjectPathTool

# Cheap-win roadmap tool (handoff_file §5.1) — direct answer to the recurring
# "host calling rpc_id(1, ...) on itself" bug class named in the roadmap.
# Catching that today requires two separate manual searches (the @rpc
# declaration, then every call site) merged by eye. This tool does both in
# one pass and groups call sites under the declaration they call.
#
# Best-effort text scan, same philosophy as SearchTextTool/FindReferencesTool
# — not a real GDScript parser. Two call syntaxes are recognized:
#   new (Godot 4 Callable-based):  node.method_name.rpc(...)  /  .rpc_id(...)
#   legacy (string-based):         rpc("method_name", ...)    /  rpc_id(peer, "method_name", ...)

const MAX_RESULTS := 500
const MAX_FILE_BYTES := 1_000_000
const SKIP_DIR_NAMES := [".godot", ".git", ".import", "__pycache__"]

func _init() -> void:
	name = "find_rpc_calls"
	description = (
		"Find every @rpc-annotated function declaration and every rpc()/rpc_id() call site "
		+ "across the project's .gd files, grouped by method name. Use instead of two separate "
		+ "search_text calls when tracking down multiplayer RPC bugs — e.g. a host calling "
		+ "rpc_id(1, ...) on itself, or a call with no matching declaration."
	)
	required_permission = "READ_PROJECT"
	input_schema = {
		"type": "object",
		"properties": {
			"path": {"type": "string", "description": "Directory to search; default res://"},
		},
	}

func execute(arguments: Dictionary) -> ToolResult:
	if project_root == "":
		return ToolResult.invalid_argument("No project is open")
	var raw_path := str(arguments.get("path", "res://"))
	var full := resolve_path(raw_path)
	if full == "":
		return ToolResult.sandbox_violation("Path is outside the project sandbox: %s" % raw_path)
	if not DirAccess.dir_exists_absolute(full) and not FileAccess.file_exists(full):
		return ToolResult.not_found("Path does not exist: %s" % raw_path)

	var decl_re := RegEx.new()
	decl_re.compile("^[ \\t]*@rpc\\b")
	var func_re := RegEx.new()
	func_re.compile("func[ \\t]+([A-Za-z_][A-Za-z0-9_]*)")
	var call_new_re := RegEx.new()
	call_new_re.compile("([A-Za-z_][A-Za-z0-9_]*)\\.rpc(_id)?[ \\t]*\\(")
	var call_legacy_rpcid_re := RegEx.new()
	call_legacy_rpcid_re.compile("\\brpc_id[ \\t]*\\([ \\t]*[^,]+,[ \\t]*[\"']([A-Za-z_][A-Za-z0-9_]*)[\"']")
	var call_legacy_rpc_re := RegEx.new()
	call_legacy_rpc_re.compile("\\brpc[ \\t]*\\([ \\t]*[\"']([A-Za-z_][A-Za-z0-9_]*)[\"']")

	var declarations: Dictionary = {}   # name -> {file, line}
	var calls: Dictionary = {}          # name -> Array[{file, line, text}]
	var unmatched: Array = []

	_walk(full, decl_re, func_re, call_new_re, call_legacy_rpcid_re, call_legacy_rpc_re, declarations, calls, unmatched)

	var total_calls := 0
	for k in calls.keys():
		total_calls += (calls[k] as Array).size()
	total_calls += unmatched.size()

	if declarations.is_empty() and total_calls == 0:
		return ToolResult.ok("No @rpc declarations or rpc()/rpc_id() call sites found under %s." % raw_path)

	var out := PackedStringArray()
	var decl_names: Array = declarations.keys()
	decl_names.sort()
	for dname_v in decl_names:
		var dname := str(dname_v)
		var d: Dictionary = declarations[dname]
		out.append("@rpc %s  (declared %s:%d)" % [dname, str(d["file"]), int(d["line"])])
		var call_list: Array = calls.get(dname, [])
		if call_list.is_empty():
			out.append("  (no call sites found)")
		else:
			for c_v in call_list:
				var c: Dictionary = c_v
				out.append("  %s:%d: %s" % [str(c["file"]), int(c["line"]), str(c["text"])])
		calls.erase(dname)

	# Calls whose captured name matched no known @rpc declaration — still
	# worth showing: the declaration may live outside the searched path, or
	# the call is a typo / calls a method that dropped its @rpc annotation.
	var leftover_names: Array = calls.keys()
	leftover_names.sort()
	for name_v in leftover_names:
		var cname := str(name_v)
		var call_list: Array = calls[cname]
		out.append("%s  (no matching @rpc declaration found)" % cname)
		for c_v in call_list:
			var c: Dictionary = c_v
			out.append("  %s:%d: %s" % [str(c["file"]), int(c["line"]), str(c["text"])])

	if not unmatched.is_empty():
		out.append("Other rpc()/rpc_id() call(s) whose method name could not be determined:")
		for c_v in unmatched:
			var c: Dictionary = c_v
			out.append("  %s:%d: %s" % [str(c["file"]), int(c["line"]), str(c["text"])])

	var header := "%d @rpc declaration(s), %d call site(s)." % [declarations.size(), total_calls]
	return ToolResult.ok(header + "\n" + "\n".join(out), {
		"declarations": declarations.size(),
		"calls": total_calls,
	})

func _walk(
		target: String,
		decl_re: RegEx, func_re: RegEx,
		call_new_re: RegEx, call_legacy_rpcid_re: RegEx, call_legacy_rpc_re: RegEx,
		declarations: Dictionary, calls: Dictionary, unmatched: Array
) -> void:
	if DirAccess.dir_exists_absolute(target):
		var d := DirAccess.open(target)
		if d == null:
			return
		d.list_dir_begin()
		var n := d.get_next()
		while n != "":
			if n.begins_with("."):
				n = d.get_next()
				continue
			var child := target.path_join(n)
			if d.current_is_dir():
				if not (n in SKIP_DIR_NAMES):
					_walk(child, decl_re, func_re, call_new_re, call_legacy_rpcid_re, call_legacy_rpc_re, declarations, calls, unmatched)
			else:
				if n.to_lower().ends_with(".gd"):
					_scan_file(child, decl_re, func_re, call_new_re, call_legacy_rpcid_re, call_legacy_rpc_re, declarations, calls, unmatched)
			n = d.get_next()
		d.list_dir_end()
	else:
		if target.to_lower().ends_with(".gd"):
			_scan_file(target, decl_re, func_re, call_new_re, call_legacy_rpcid_re, call_legacy_rpc_re, declarations, calls, unmatched)

func _scan_file(
		path: String,
		decl_re: RegEx, func_re: RegEx,
		call_new_re: RegEx, call_legacy_rpcid_re: RegEx, call_legacy_rpc_re: RegEx,
		declarations: Dictionary, calls: Dictionary, unmatched: Array
) -> void:
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

		if decl_re.search(line) != null:
			# Look ahead a few lines for the func this @rpc annotation
			# applies to — other annotations (@export, etc.) or blank lines
			# may sit between the two.
			for j in range(i, mini(i + 4, lines.size())):
				var fm := func_re.search(lines[j])
				if fm != null:
					var fname := fm.get_string(1)
					if not declarations.has(fname):
						declarations[fname] = {"file": path, "line": j + 1}
					break

		var new_m := call_new_re.search(line)
		var legacy_id_m := call_legacy_rpcid_re.search(line)
		var legacy_m := call_legacy_rpc_re.search(line)

		if new_m != null:
			_add_call(calls, new_m.get_string(1), path, i + 1, line.strip_edges())
		elif legacy_id_m != null:
			_add_call(calls, legacy_id_m.get_string(1), path, i + 1, line.strip_edges())
		elif legacy_m != null:
			_add_call(calls, legacy_m.get_string(1), path, i + 1, line.strip_edges())
		elif line.find(".rpc(") != -1 or line.find(".rpc_id(") != -1 or line.find("rpc_id(") != -1:
			# A call exists but the method name couldn't be extracted (e.g.
			# the name is stored in a variable, not a literal) — surfaced
			# unmatched rather than silently dropped.
			unmatched.append({"file": path, "line": i + 1, "text": line.strip_edges()})

		if declarations.size() + calls.size() + unmatched.size() >= MAX_RESULTS:
			return

static func _add_call(calls: Dictionary, method_name: String, path: String, line_no: int, text: String) -> void:
	if not calls.has(method_name):
		calls[method_name] = []
	(calls[method_name] as Array).append({"file": path, "line": line_no, "text": text})
