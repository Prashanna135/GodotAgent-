class_name SearchTextTool
extends ProjectPathTool

const DEFAULT_LIMIT := 50
const MAX_RESULTS := 5000
const MAX_FILE_BYTES := 1_000_000

# Godot generates .import files (one per asset, containing content hashes),
# .uid files (resource UID mappings), and the .godot/ cache directory. None
# of these ever contain user-editable source — they're build artifacts. A
# text search over them is pure noise: common queries like "30", "main", or
# any short string match hex hashes and import paths instead of code. Skip
# them entirely so search results are always something a coding agent could
# act on.
#
# `.git` is included because a project opened without a .gitignore may have
# it sitting under res://, and git object files are compressed binaries that
# bloat the walk.
const SKIP_DIR_NAMES := [".godot", ".git", ".import", "__pycache__"]
const SKIP_FILE_EXTENSIONS := [".import", ".uid", ".tmp", ".log", ".lock"]

# Files whose contents are binary data — images, audio, fonts, 3D models,
# compiled resources, archives. Reading these as text returns
# replacement-character garbage and burns the search budget on matches the
# model can't act on. Skipped from search_text entirely; the model can
# still locate them by path via find_files if it specifically needs to
# reference an asset.
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
	# compiled / packaged Godot resources (the binary counterparts of
	# .tscn/.tres, which are text and stay searchable)
	".res", ".scn", ".pck", ".pak",
	# native / executable
	".exe", ".dll", ".so", ".dylib",
	# archives
	".zip", ".7z", ".tar", ".gz", ".rar",
]

func _init() -> void:
	name = "search_text"
	description = (
		"Search for a plain-text substring across project files (bounded results). "
		+ "Generated files and binary assets are skipped automatically."
	)
	required_permission = "READ_PROJECT"
	input_schema = {
		"type": "object",
		"properties": {
			"query": {"type": "string"},
			"path": {"type": "string", "description": "Directory or file to search; default res://"},
			"limit": {"type": "integer", "description": "Max matches to return; default 50"},
			"offset": {"type": "integer", "description": "Skip the first N matches"},
			"case_sensitive": {"type": "boolean"},
		},
		"required": ["query"],
	}

func execute(arguments: Dictionary) -> ToolResult:
	var query := str(arguments.get("query", ""))
	if query == "":
		return ToolResult.failure("Missing required argument: query")
	var raw_path := str(arguments.get("path", "res://"))
	var full := resolve_path(raw_path)
	if full == "":
		return ToolResult.failure("Path is outside the project sandbox: %s" % raw_path)
	var limit := int(arguments.get("limit", DEFAULT_LIMIT))
	var offset := int(arguments.get("offset", 0))
	var case_sensitive := bool(arguments.get("case_sensitive", false))
	var needle := query if case_sensitive else query.to_lower()

	var matches: Array = []
	_search(full, needle, case_sensitive, matches)

	var total := matches.size()
	var upper := mini(total, offset + limit)
	var window: Array = matches.slice(offset, upper)
	var lines := PackedStringArray()
	for entry in window:
		var m: Dictionary = entry
		lines.append("%s:%d: %s" % [str(m["file"]), int(m["line"]), str(m["text"])])

	var header: String
	if total == 0:
		header = "0 matches found.\n" + _zero_result_hint()
	else:
		header = "%d match(es) found. Showing %d..%d." % [total, offset + 1, upper]
	return ToolResult.ok(header + "\n" + "\n".join(lines), {
		"total": total, "offset": offset, "limit": limit,
	})

# Shown only on zero matches. Most zero-result searches are one of two
# mistakes: searching for something the user asked to ADD (it doesn't exist
# yet — search for the surrounding code instead), or searching for a
# specific name without first confirming it exists. This hint names the
# cheap fallback: enumerate what's actually there, then narrow.
static func _zero_result_hint() -> String:
	return (
		"(No matches. If you were guessing at a name that might not exist — "
		+ "especially if the user asked you to ADD something, which means it "
		+ "doesn't exist yet — try a broader approach: `find_files` with "
		+ "pattern `*.gd` to list every script, or `search_text` with a "
		+ "shorter substring more likely to appear in the surrounding code.)"
	)

func _search(target: String, needle: String, case_sensitive: bool, matches: Array) -> void:
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
			if matches.size() >= MAX_RESULTS:
				d.list_dir_end()
				return
			var child := target.path_join(n)
			if d.current_is_dir():
				_search(child, needle, case_sensitive, matches)
			else:
				_scan_file(child, needle, case_sensitive, matches)
			n = d.get_next()
		d.list_dir_end()
	else:
		_scan_file(target, needle, case_sensitive, matches)

func _scan_file(path: String, needle: String, case_sensitive: bool, matches: Array) -> void:
	var lower := path.to_lower()
	for ext in SKIP_FILE_EXTENSIONS:
		if lower.ends_with(ext):
			return
	# Binary assets: reading them as text yields garbage that has no bearing
	# on the model's task, and grepping a large .png/.glb for a substring
	# wastes the search budget. Skip before opening.
	for ext in BINARY_EXTENSIONS:
		if lower.ends_with(ext):
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
		var hay := line if case_sensitive else line.to_lower()
		if hay.find(needle) != -1:
			matches.append({"file": path, "line": i + 1, "text": line.strip_edges()})
			if matches.size() >= MAX_RESULTS:
				return
