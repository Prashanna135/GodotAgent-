class_name ProjectScanner
extends RefCounted

# Walks the project once at open time and returns a compact listing of the
# source files the model can read or edit. Injected into the conversation as
# a fixed leading system message (see ContextManager.project_files_summary),
# so the model has an authoritative answer to "does this .gd/.tscn exist?"
# without needing a tool call.
#
# SOURCE-ONLY BY DESIGN. The previous "list everything except generated
# files" approach produced lists where code files were outnumbered 10:1 by
# assets, license text, and git metadata. The list is a fixed leading system
# message paid for on every single turn — its signal-to-noise matters far
# more than its exhaustiveness. If the model needs to know "does Player.png
# exist?", find_files answers that in one round trip.

# Cap on total characters in the listing. Source-only lists stay well under
# this on any normal project; the cap is runaway protection for projects
# with thousands of scripts.
const MAX_LISTING_CHARS := 12_000

# Only these extensions are listed. Everything else — assets, images, audio,
# fonts, 3D models, licenses, URL shortcuts, git metadata, generated files —
# is discoverable via find_files if the model genuinely needs it, but is NOT
# indexed by default.
#
# Rationale for each entry:
#   .gd / .cs        — source code, the primary thing the model edits
#   .tscn / .tres    — text scene and resource files the model reads
#   .godot           — project config (one per project, always relevant)
#   .gdshader/.shader — GPU program source
#   .json / .cfg     — data and config the model may read or edit
#   .md              — docs; AGENT.md in particular lives here
const INCLUDE_EXTENSIONS := [
	".gd",
	".tscn",
	".tres",
	".godot",
	".gdshader",
	".shader",
	".cs",
	".json",
	".cfg",
	".md",
]

# Directories never walked. Dot-directories are skipped categorically by the
# leading-dot rule in _walk; this list catches name-without-dot cases and
# documents the intent.
const SKIP_DIR_NAMES := [".godot", ".git", ".import", "__pycache__"]

static func scan(root_path: String) -> String:
	var root := root_path.replace("\\", "/").simplify_path().rstrip("/")
	if root == "" or not DirAccess.dir_exists_absolute(root):
		return ""

	var files: Array = []
	_walk(root, root, files)
	if files.is_empty():
		return ""

	files.sort()

	var total := files.size()
	var shown := PackedStringArray()
	var accumulated := 0
	var truncated := false
	for rel in files:
		var line := "res://" + str(rel)
		if accumulated + line.length() + 1 > MAX_LISTING_CHARS:
			truncated = true
			break
		shown.append(line)
		accumulated += line.length() + 1

	var header: String
	if truncated:
		header = "Project source files (%d total, showing first %d):" % [total, shown.size()]
	else:
		header = "Project source files (%d):" % total

	var body := "\n".join(shown)
	var footer := (
		"(Source files only — assets, images, audio, generated files, and "
		+ "git metadata are not listed. Use find_files or list_directory to "
		+ "locate anything not shown. Do not guess paths that aren't listed.)"
	)
	return header + "\n" + body + "\n" + footer

static func _walk(root: String, current: String, out: Array) -> void:
	var d := DirAccess.open(current)
	if d == null:
		return
	d.list_dir_begin()
	var n := d.get_next()
	while n != "":
		# Skip dotfiles and dot-directories categorically. Covers .git,
		# .gitignore, .gitattributes, .godot, .vscode, .DS_Store, and any
		# other hidden metadata.
		if n.begins_with("."):
			n = d.get_next()
			continue
		if d.current_is_dir():
			if not (n in SKIP_DIR_NAMES):
				_walk(root, current.path_join(n), out)
		else:
			if _is_included(n):
				var full := current.path_join(n)
				var rel := full.substr(root.length())
				while rel.begins_with("/"):
					rel = rel.substr(1)
				out.append(rel)
		n = d.get_next()
	d.list_dir_end()

static func _is_included(filename: String) -> bool:
	var lower := filename.to_lower()
	for ext in INCLUDE_EXTENSIONS:
		if lower.ends_with(ext):
			return true
	return false
