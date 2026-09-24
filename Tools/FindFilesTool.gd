class_name FindFilesTool
extends ProjectPathTool

const DEFAULT_LIMIT := 200
const MAX_RESULTS := 5000

# Same skip lists as SearchTextTool. Godot generates .import files (one per
# asset), .uid files (resource UID mappings), and the .godot/ cache
# directory; none of them contain anything the model can act on. Skipping
# here keeps "find_files('*.gd')" clean and stops an asset-directory walk
# from drowning in .import sidecars.
const SKIP_DIR_NAMES := [".godot", ".git", ".import", "__pycache__"]
const SKIP_FILE_EXTENSIONS := [".import", ".uid", ".tmp", ".log", ".lock"]

# Binary assets. These are legitimate find_files results — the model may
# need to reference "Player.png" by path — but they are never where a code
# question is answered. Non-asset matches sort before asset matches, and
# asset matches are tagged in the output so the model can tell at a glance
# which hits are editable source and which are resources.
const BINARY_EXTENSIONS := [
	# images
	".png", ".jpg", ".jpeg", ".gif", ".webp", ".bmp", ".ico",
	".tga", ".dds", ".exr", ".hdr", ".ktx", ".pvr", ".svg",
	# audio
	".ogg", ".wav", ".mp3", ".flac", ".opus",
	# fonts
	".ttf", ".otf", ".woff", ".woff2", ".fnt",
	# 3D models
	".glb", ".gltf", ".fbx", ".obj", ".dae", ".blend", ".mtl",
	# compiled / packaged Godot resources (.tscn/.tres are text and stay untagged)
	".res", ".scn", ".pck", ".pak",
	# native / executable
	".exe", ".dll", ".so", ".dylib",
	# archives
	".zip", ".7z", ".tar", ".gz", ".rar",
]

func _init() -> void:
	name = "find_files"
	description = (
		"Find files by name — `*`/`?` globs or a plain substring, case-insensitive. "
		+ "Code/scene files sort before assets, and assets are tagged (useful when "
		+ "`Player` matches both Player.gd and Player.png). Generated sidecars and "
		+ "the .godot/ cache are never shown."
	)
	required_permission = "READ_PROJECT"
	input_schema = {
		"type": "object",
		"properties": {
			"pattern": {"type": "string", "description": "e.g. `*.tscn`, `Player*.gd`, or `Player`"},
			"path": {"type": "string", "description": "Directory to search; default res://"},
			"extensions": {
				"type": "array",
				"items": {"type": "string"},
				"description": "Optional extension filter, e.g. ['.gd', '.tscn']",
			},
			"limit": {"type": "integer"},
		},
		"required": ["pattern"],
	}

func execute(arguments: Dictionary) -> ToolResult:
	var pattern := str(arguments.get("pattern", "")).strip_edges()
	if pattern == "":
		return ToolResult.invalid_argument("Missing required argument: pattern")
	var raw_path := str(arguments.get("path", "res://"))
	var full := resolve_path(raw_path)
	if full == "":
		return ToolResult.sandbox_violation("Path is outside the project sandbox: %s" % raw_path)
	if not DirAccess.dir_exists_absolute(full) and not FileAccess.file_exists(full):
		return ToolResult.not_found("Path does not exist: %s" % raw_path)

	var limit := int(arguments.get("limit", DEFAULT_LIMIT))
	var exts: Array = []
	if arguments.has("extensions") and typeof(arguments["extensions"]) == TYPE_ARRAY:
		for v in arguments["extensions"]:
			var s := str(v).to_lower()
			if s != "" and not s.begins_with("."):
				s = "." + s
			exts.append(s)

	var use_glob := pattern.find("*") != -1 or pattern.find("?") != -1
	var needle := pattern if use_glob else pattern.to_lower()
	var results: Array = []
	_walk(full, needle, use_glob, exts, results)

	# Non-asset matches first, then asset matches, alphabetical within each
	# group. A pattern like `*.png` produces an all-asset result set — the
	# sort is then a no-op and the tag just confirms what was asked for.
	results.sort_custom(func(a, b):
		var a_asset := _is_asset(str(a))
		var b_asset := _is_asset(str(b))
		if a_asset != b_asset:
			return not a_asset
		return str(a) < str(b)
	)

	var total := results.size()
	var window: Array = results.slice(0, limit)
	var lines := PackedStringArray()
	for p in window:
		var line := str(p)
		if _is_asset(line):
			line += "  (asset)"
		lines.append(line)
	var header := "%d file(s) matched." % total
	if total > limit:
		header = "%d file(s) matched; showing first %d." % [total, limit]
	return ToolResult.ok(header + "\n" + "\n".join(lines), {"total": total})

func _walk(target: String, needle: String, use_glob: bool, exts: Array, out: Array) -> void:
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
			if n.begins_with("."):
				n = d.get_next()
				continue
			if out.size() >= MAX_RESULTS:
				d.list_dir_end()
				return
			var child := target.path_join(n)
			if d.current_is_dir():
				_walk(child, needle, use_glob, exts, out)
			else:
				if _matches(n, needle, use_glob, exts):
					out.append(child)
			n = d.get_next()
		d.list_dir_end()
	else:
		if _matches(target.get_file(), needle, use_glob, exts):
			out.append(target)

static func _is_asset(path: String) -> bool:
	var lower := path.to_lower()
	for ext in BINARY_EXTENSIONS:
		if lower.ends_with(ext):
			return true
	return false

static func _matches(filename: String, needle: String, use_glob: bool, exts: Array) -> bool:
	var lower := filename.to_lower()
	# Skip generated sidecars by default. The one exception: if the caller
	# explicitly asked for one of those extensions (extensions: [".import"],
	# or pattern "*.import"), honor the request — that's a clear signal of
	# intent, not a substring glob that happened to match a sidecar.
	var honor_skip_exts := false
	for e in exts:
		if str(e) in SKIP_FILE_EXTENSIONS:
			honor_skip_exts = true
			break
	if not honor_skip_exts:
		for ext in SKIP_FILE_EXTENSIONS:
			if lower.ends_with(ext):
				return false
	if not exts.is_empty():
		var ok := false
		for e in exts:
			if lower.ends_with(str(e)):
				ok = true
				break
		if not ok:
			return false
	if use_glob:
		return filename.matchn(needle)
	return lower.find(needle) != -1
