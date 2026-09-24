class_name FindSymbolTool
extends ProjectPathTool

const DEFAULT_LIMIT := 100
const MAX_RESULTS := 1000
const MAX_FILE_BYTES := 1_000_000

func _init() -> void:
	name = "find_symbol"
	description = (
		"Find declarations of a symbol (func/class/class_name/var/const/signal/enum) "
		+ "across the project. Also reports autoload singletons from project.godot's "
		+ "[autoload] section, which aren't .gd declarations and would otherwise look "
		+ "missing."
	)
	required_permission = "READ_PROJECT"
	input_schema = {
		"type": "object",
		"properties": {
			"symbol": {"type": "string"},
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

	# Autoloads are declared in project.godot, not as a class_name/var in a
	# .gd file. Without this check, find_symbol("GameSettings") reports "no
	# declarations found" even though project.godot clearly declares it —
	# which sends small models into a false "the autoload is missing" spiral.
	# Autoload matches are prepended so they appear first in the result.
	var autoload_matches := _find_autoload_matches(symbol)
	matches.append_array(autoload_matches)

	_walk(full, symbol, exts, matches)

	var total := matches.size()
	var window: Array = matches.slice(0, limit)
	var lines := PackedStringArray()
	for m in window:
		var md: Dictionary = m
		lines.append("%s:%d: %s" % [str(md["file"]), int(md["line"]), str(md["text"])])
	var header := "%d declaration(s) found." % total
	if total == 0:
		header = "No declarations of '%s' found." % symbol
	elif total > limit:
		header = "%d declaration(s) found; showing first %d." % [total, limit]
	return ToolResult.ok(header + "\n" + "\n".join(lines), {"total": total})

func _walk(target: String, symbol: String, exts: Array, out: Array) -> void:
	if out.size() >= MAX_RESULTS:
		return
	if DirAccess.dir_exists_absolute(target):
		var d := DirAccess.open(target)
		if d == null:
			return
		d.list_dir_begin()
		var n := d.get_next()
		while n != "":
			if not n.begins_with("."):
				var child := target.path_join(n)
				if d.current_is_dir():
					_walk(child, symbol, exts, out)
				else:
					_scan(child, symbol, exts, out)
			n = d.get_next()
		d.list_dir_end()
	else:
		_scan(target, symbol, exts, out)

func _scan(path: String, symbol: String, exts: Array, out: Array) -> void:
	if not exts.is_empty():
		var ok := false
		var lower := path.to_lower()
		for e in exts:
			if lower.ends_with(str(e)):
				ok = true
				break
		if not ok:
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
	var decl := _build_regex(symbol)
	for i in lines.size():
		var line: String = lines[i]
		if decl.search(line) != null:
			out.append({"file": path, "line": i + 1, "text": line.strip_edges()})
			if out.size() >= MAX_RESULTS:
				return

# Reads project.godot's [autoload] section and returns one match per entry
# whose key matches `symbol`. Uses line 0 as the placeholder line number
# since the config file's exact line isn't tracked by ConfigFile. The text
# field is written to be self-explanatory so a small model sees "this is
# an autoload singleton, not a missing symbol."
func _find_autoload_matches(symbol: String) -> Array:
	var out: Array = []
	if project_root == "":
		return out
	var pg := project_root.path_join("project.godot")
	if not FileAccess.file_exists(pg):
		return out
	var cfg := ConfigFile.new()
	if cfg.load(pg) != OK:
		return out
	if not cfg.has_section("autoload"):
		return out
	for key in cfg.get_section_keys("autoload"):
		if str(key) == symbol:
			var target := str(cfg.get_value("autoload", key, ""))
			out.append({
				"file": pg,
				"line": 0,
				"text": "%s = %s  (autoload singleton, declared in project.godot — this IS the declaration)" % [key, target],
			})
	return out

static func _build_regex(symbol: String) -> RegEx:
	var re := RegEx.new()
	# Matches a declaration line that introduces `symbol` as a name.
	var pattern := (
		"^[ \\t]*"
		+ "(?:@[a-zA-Z_][a-zA-Z0-9_]*(\\([^)]*\\))?[ \\t]+)*"
		+ "(?:class_name|class|func|var|const|signal|enum|static[ \\t]+var)"
		+ "[ \\t]+" + symbol + "\\b"
	)
	re.compile(pattern)
	return re

static func _is_identifier(s: String) -> bool:
	if s == "":
		return false
	var re := RegEx.new()
	re.compile("^[A-Za-z_][A-Za-z0-9_]*$")
	return re.search(s) != null
