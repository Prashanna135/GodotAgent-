class_name FindSignalWiringTool
extends ProjectPathTool

# Cheap-win roadmap tool (handoff_file §5.1) — the find_symbol/find_references
# split, applied to signals instead of declarations. find_references matches
# any identifier use, which is noisy for a signal name that's also used as a
# plain string/argument name elsewhere; this tool matches only the shapes
# that actually wire a signal up (connect/emit, new- and legacy-syntax both),
# and reports the declaration too so the whole picture — declared, wired,
# fired — comes back in one call.

const DEFAULT_LIMIT := 100
const MAX_RESULTS := 1000
const MAX_FILE_BYTES := 1_000_000
const SKIP_DIR_NAMES := [".godot", ".git", ".import", "__pycache__"]

func _init() -> void:
	name = "find_signal_wiring"
	description = (
		"Companion to find_references, specifically for signals: reports every "
		+ ".connect(...)/connect(\"name\", ...) and every .emit(...)/emit_signal(\"name\", ...) "
		+ "site for a signal name together, plus its `signal name` declaration if found. Use "
		+ "before renaming a signal or tracing why a handler isn't firing."
	)
	required_permission = "READ_PROJECT"
	input_schema = {
		"type": "object",
		"properties": {
			"symbol": {"type": "string", "description": "The signal name."},
			"path": {"type": "string", "description": "Directory to search; default res://"},
			"limit": {"type": "integer"},
		},
		"required": ["symbol"],
	}

func execute(arguments: Dictionary) -> ToolResult:
	var symbol := str(arguments.get("symbol", "")).strip_edges()
	if symbol == "":
		return ToolResult.invalid_argument("Missing required argument: symbol")
	if not _is_identifier(symbol):
		return ToolResult.invalid_argument("Not a valid identifier: %s" % symbol)

	var raw_path := str(arguments.get("path", "res://"))
	var full := resolve_path(raw_path)
	if full == "":
		return ToolResult.sandbox_violation("Path is outside the project sandbox: %s" % raw_path)
	if not DirAccess.dir_exists_absolute(full) and not FileAccess.file_exists(full):
		return ToolResult.not_found("Path does not exist: %s" % raw_path)

	var limit := int(arguments.get("limit", DEFAULT_LIMIT))

	var connect_new_re := _build_new_call_regex(symbol, "connect")
	var connect_legacy_re := _build_legacy_call_regex(symbol, "connect")
	var emit_new_re := _build_new_call_regex(symbol, "emit")
	var emit_legacy_re := _build_legacy_emit_signal_regex(symbol)
	var decl_re := _build_decl_regex(symbol)

	var matches: Array = []
	_walk(full, connect_new_re, connect_legacy_re, emit_new_re, emit_legacy_re, decl_re, matches)

	var total := matches.size()
	if total == 0:
		return ToolResult.ok(
			(
				"No connect/emit sites found for signal '%s'.\n"
				+ "(find_symbol can confirm whether a signal with this name is declared anywhere.)"
			) % symbol
		)
	var window: Array = matches.slice(0, limit)
	var lines := PackedStringArray()
	for m_v in window:
		var m: Dictionary = m_v
		lines.append("%s:%d: [%s] %s" % [str(m["file"]), int(m["line"]), str(m["kind"]), str(m["text"])])
	var header := "%d site(s) for signal '%s'." % [total, symbol]
	if total > limit:
		header = "%d site(s) for signal '%s'; showing first %d." % [total, symbol, limit]
	return ToolResult.ok(header + "\n" + "\n".join(lines), {"total": total})

# --- regex builders ---------------------------------------------------

static func _build_new_call_regex(symbol: String, method: String) -> RegEx:
	var re := RegEx.new()
	re.compile("(?<![A-Za-z0-9_])" + symbol + "\\." + method + "[ \\t]*\\(")
	return re

static func _build_legacy_call_regex(symbol: String, method: String) -> RegEx:
	var re := RegEx.new()
	re.compile("\\b" + method + "[ \\t]*\\([ \\t]*[\"']" + symbol + "[\"']")
	return re

static func _build_legacy_emit_signal_regex(symbol: String) -> RegEx:
	var re := RegEx.new()
	re.compile("\\bemit_signal[ \\t]*\\([ \\t]*[\"']" + symbol + "[\"']")
	return re

static func _build_decl_regex(symbol: String) -> RegEx:
	var re := RegEx.new()
	re.compile("(?<![A-Za-z0-9_])signal[ \\t]+" + symbol + "\\b")
	return re

# --- walking / scanning ------------------------------------------------

func _walk(
		target: String,
		connect_new_re: RegEx, connect_legacy_re: RegEx,
		emit_new_re: RegEx, emit_legacy_re: RegEx,
		decl_re: RegEx, out: Array
) -> void:
	if out.size() >= MAX_RESULTS:
		return
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
			if out.size() >= MAX_RESULTS:
				d.list_dir_end()
				return
			var child := target.path_join(n)
			if d.current_is_dir():
				if not (n in SKIP_DIR_NAMES):
					_walk(child, connect_new_re, connect_legacy_re, emit_new_re, emit_legacy_re, decl_re, out)
			else:
				if n.to_lower().ends_with(".gd"):
					_scan(child, connect_new_re, connect_legacy_re, emit_new_re, emit_legacy_re, decl_re, out)
			n = d.get_next()
		d.list_dir_end()
	else:
		if target.to_lower().ends_with(".gd"):
			_scan(target, connect_new_re, connect_legacy_re, emit_new_re, emit_legacy_re, decl_re, out)

func _scan(
		path: String,
		connect_new_re: RegEx, connect_legacy_re: RegEx,
		emit_new_re: RegEx, emit_legacy_re: RegEx,
		decl_re: RegEx, out: Array
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
		var kind := ""
		if decl_re.search(line) != null:
			kind = "declared"
		elif connect_new_re.search(line) != null or connect_legacy_re.search(line) != null:
			kind = "connect"
		elif emit_new_re.search(line) != null or emit_legacy_re.search(line) != null:
			kind = "emit"
		else:
			continue
		out.append({"file": path, "line": i + 1, "kind": kind, "text": line.strip_edges()})
		if out.size() >= MAX_RESULTS:
			return

static func _is_identifier(s: String) -> bool:
	if s == "":
		return false
	var re := RegEx.new()
	re.compile("^[A-Za-z_][A-Za-z0-9_]*$")
	return re.search(s) != null
