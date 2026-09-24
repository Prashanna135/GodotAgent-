class_name FindReferencesTool
extends ProjectPathTool

const DEFAULT_LIMIT := 100
const MAX_RESULTS := 1000
const MAX_FILE_BYTES := 1_000_000

# Same skip list as SearchTextTool/FindFilesTool — Godot generates .import
# files (one per asset, containing content hashes), .uid files (resource UID
# mappings), and the .godot/ cache directory. None of these ever contain
# user-editable source. Searching them for a common identifier like `_ready`
# returns thousands of hex-hash and resource-path false positives.
const SKIP_DIR_NAMES := [".godot", ".git", ".import", "__pycache__"]
const SKIP_FILE_EXTENSIONS := [".import", ".uid", ".tmp", ".log", ".lock"]

func _init() -> void:
	name = "find_references"
	description = (
		"Find every USE of a symbol — call sites, reads/writes, signal connections. "
		+ "Companion to find_symbol (which finds the declaration); use before renaming "
		+ "to see what depends on it. String-literal references like "
		+ "connect(\"died\", ...) are tagged [string] and must be updated too."
	)
	required_permission = "READ_PROJECT"
	input_schema = {
		"type": "object",
		"properties": {
			"symbol": {"type": "string", "description": "The identifier to find usages of."},
			"path": {"type": "string", "description": "Directory to search; default res://"},
			"extensions": {
				"type": "array",
				"items": {"type": "string"},
				"description": "Defaults to ['.gd']",
			},
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

	var exts: Array = [".gd"]
	if arguments.has("extensions") and typeof(arguments["extensions"]) == TYPE_ARRAY:
		exts.clear()
		for v in arguments["extensions"]:
			var s := str(v).to_lower()
			if s != "" and not s.begins_with("."):
				s = "." + s
			exts.append(s)

	var limit := int(arguments.get("limit", DEFAULT_LIMIT))
	var matches: Array = []

	# Pre-build the three regexes once. Doing it per-line inside the scan
	# would recompile them thousands of times for a project-wide search.
	var ident_re := _build_ident_regex(symbol)
	var string_re := _build_string_regex(symbol)
	var decl_re := _build_decl_regex(symbol)

	_walk(full, ident_re, string_re, decl_re, exts, matches)

	var total := matches.size()
	var window: Array = matches.slice(0, limit)
	var lines := PackedStringArray()
	for m in window:
		var md: Dictionary = m
		lines.append("%s:%d: [%s] %s" % [
			str(md["file"]), int(md["line"]), str(md["kind"]), str(md["text"])
		])
	var header := "%d reference(s) found." % total
	if total == 0:
		header = (
			"No references to '%s' found.\n"
			+ "(If you were guessing at a name that might not exist, "
			+ "find_symbol will tell you whether it is declared anywhere.)"
		) % symbol
	elif total > limit:
		header = "%d reference(s) found; showing first %d." % [total, limit]
	return ToolResult.ok(header + "\n" + "\n".join(lines), {"total": total})

func _walk(target: String, ident_re: RegEx, string_re: RegEx, decl_re: RegEx, exts: Array, out: Array) -> void:
	if out.size() >= MAX_RESULTS:
		return
	if DirAccess.dir_exists_absolute(target):
		var d := DirAccess.open(target)
		if d == null:
			return
		d.list_dir_begin()
		var n := d.get_next()
		while n != "":
			if n in SKIP_DIR_NAMES:
				n = d.get_next()
				continue
			if out.size() >= MAX_RESULTS:
				d.list_dir_end()
				return
			var child := target.path_join(n)
			if d.current_is_dir():
				_walk(child, ident_re, string_re, decl_re, exts, out)
			else:
				_scan(child, ident_re, string_re, decl_re, exts, out)
			n = d.get_next()
		d.list_dir_end()
	else:
		_scan(target, ident_re, string_re, decl_re, exts, out)

func _scan(path: String, ident_re: RegEx, string_re: RegEx, decl_re: RegEx, exts: Array, out: Array) -> void:
	if not exts.is_empty():
		var ok := false
		var lower := path.to_lower()
		for e in exts:
			if lower.ends_with(str(e)):
				ok = true
				break
		if not ok:
			return
	var path_lower := path.to_lower()
	for skip_ext in SKIP_FILE_EXTENSIONS:
		if path_lower.ends_with(skip_ext):
			return

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

		# Skip the line that DECLARES this symbol — that's what find_symbol
		# returns, and mixing it into reference results makes "who calls
		# this?" harder to answer. A line that both declares and uses the
		# symbol (e.g. a recursive `func f(): return f()`) is skipped
		# entirely: the recursive call is discoverable by reading the
		# declaration, which find_symbol already points at.
		if decl_re.search(line) != null:
			continue

		var kind := ""
		if ident_re.search(line) != null:
			kind = "ident"
		elif string_re.search(line) != null:
			kind = "string"
		else:
			continue

		out.append({
			"file": path,
			"line": i + 1,
			"kind": kind,
			"text": line.strip_edges(),
		})
		if out.size() >= MAX_RESULTS:
			return

# Word-boundary identifier match. \b is not sufficient — `_` counts as a
# word character in some regex flavors, so \btake_damage\b would wrongly
# match the tail of `_take_damage`. Explicit [A-Za-z0-9_] on both sides is
# unambiguous and matches GDScript's actual identifier rules.
static func _build_ident_regex(symbol: String) -> RegEx:
	var re := RegEx.new()
	re.compile("(?<![A-Za-z0-9_])" + symbol + "(?![A-Za-z0-9_])")
	return re

# A bare quoted identifier, e.g. "died" or 'died'. Catches the two places
# string-coupled references actually appear in Godot: connect("signal",
# ...) and has_method("name") / call("name"). Deliberately does NOT match
# a symbol embedded in a longer string (get_node("Player/Damage") will not
# report `Player`), because loosening the pattern to allow that turns the
# result into a substring soup of unrelated node paths and asset names.
static func _build_string_regex(symbol: String) -> RegEx:
	var re := RegEx.new()
	re.compile("[\"']" + symbol + "[\"']")
	return re

# Matches a line whose text contains a declaration of `symbol` — a
# class_name/class/func/var/const/signal/enum/static var keyword followed
# by the symbol as a whole word. The `(?<![A-Za-z0-9_])` prefix on the
# keyword prevents matching a substring (e.g. a `var` inside `avatar`),
# and the trailing lookahead ensures `MAX` doesn't get treated as declared
# by `const MAXIMUM := 100`.
static func _build_decl_regex(symbol: String) -> RegEx:
	var re := RegEx.new()
	re.compile(
		"(?<![A-Za-z0-9_])"
		+ "(?:class_name|class|func|var|const|signal|enum|static[ \\t]+var)"
		+ "[ \\t]+" + symbol + "(?![A-Za-z0-9_])"
	)
	return re

static func _is_identifier(s: String) -> bool:
	if s == "":
		return false
	var re := RegEx.new()
	re.compile("^[A-Za-z_][A-Za-z0-9_]*$")
	return re.search(s) != null
