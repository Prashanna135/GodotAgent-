class_name ProjectPathTool
extends Tool

# Resolves a project-relative path (e.g. "res://Player.gd") to an absolute path.
# Returns "" if the resolved path escapes the project sandbox.
func resolve_path(path: String) -> String:
	if project_root == "":
		return ""
	var root := project_root.replace("\\", "/").simplify_path().rstrip("/")
	var normalized := path.strip_edges()
	if normalized.begins_with("res://"):
		normalized = normalized.substr(6)
	elif normalized.begins_with("user://"):
		return ""  # not supported in this slice
	while normalized.begins_with("/") or normalized.begins_with("\\"):
		normalized = normalized.substr(1)
	var combined := root.path_join(normalized).replace("\\", "/").simplify_path()
	if not _is_inside(root, combined):
		return ""
	return combined

func _is_inside(root: String, candidate: String) -> bool:
	return candidate == root or candidate.begins_with(root + "/")

# --- indentation helpers ---------------------------------------------------
#
# GDScript requires consistent indentation within a file: either tabs or
# spaces, but not mixed. Godot's parser reports a line that breaks the
# convention as "Used space character for indentation instead of tab" or the
# reverse. Small models routinely paste space-indented content into a
# tab-indented file (or vice versa), which then fails on the next check.
#
# These helpers let the write tools auto-normalize leading whitespace on
# new content to match the target file's existing style. Only leading
# whitespace is touched — indentation of continuation lines, string
# interiors, etc. are all preserved.

# Returns "\t" if the file uses tabs, " " if it uses spaces, "" if it's
# empty or uses no indentation at all. When the file is mixed (has both
# tabs and spaces in leading positions), tabs wins — Godot's default, and
# almost always what a user actually wants when the mix is a mistake.
static func detect_indent_char(content: String) -> String:
	if content == "":
		return ""
	var tab_lines := 0
	var space_lines := 0
	var lines := content.split("\n")
	# Cap the scan: a multi-megabyte file's first 200 lines tell us the
	# style without scanning the whole thing.
	var limit := mini(lines.size(), 200)
	for i in limit:
		var line: String = lines[i]
		if line.begins_with("\t"):
			tab_lines += 1
		elif line.begins_with(" "):
			space_lines += 1
	if tab_lines > 0:
		return "\t"
	if space_lines > 0:
		return " "
	return ""

# Convert leading whitespace on each line of `content` to `target`
# ("\t" or " "). The column model: 1 tab = 4 spaces. A run of leading
# whitespace on a line is measured in columns; on output, that column count
# is rendered as the target character with round-up-to-tab for "\t"
# (so 5 spaces → 2 tabs, since 5 columns can't be exactly 1 tab).
#
# Returns {"content": String, "changed": int} where `changed` is the number
# of lines whose leading whitespace was rewritten. Callers use that count
# to decide whether to surface a note to the model.
static func normalize_indent(content: String, target: String) -> Dictionary:
	if target == "" or content == "":
		return {"content": content, "changed": 0}
	var lines := content.split("\n")
	var out := PackedStringArray()
	var changed := 0
	for line in lines:
		var converted := _convert_leading_ws(line, target)
		if converted != line:
			changed += 1
		out.append(converted)
	return {"content": "\n".join(out), "changed": changed}

static func _convert_leading_ws(line: String, target: String) -> String:
	# Measure leading whitespace in columns: 1 tab = 4 spaces.
	var cols := 0
	var i := 0
	while i < line.length():
		var c := line[i]
		if c == "\t":
			cols += 4
			i += 1
		elif c == " ":
			cols += 1
			i += 1
		else:
			break
	if i == 0:
		return line  # no leading whitespace to touch
	var rest := line.substr(i)
	if target == "\t":
		# Round up: 1-4 columns → 1 tab, 5-8 → 2 tabs, etc. GDScript only
		# cares about indent LEVELS, not alignment, so a small column drift
		# is harmless. Rounding up rather than down avoids flattening.
		var tabs := int(ceil(cols / 4.0))
		return "\t".repeat(tabs) + rest
	else:
		return " ".repeat(cols) + rest
