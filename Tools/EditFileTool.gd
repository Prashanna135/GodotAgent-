class_name EditFileTool
extends ProjectPathTool

func _init() -> void:
	name = "edit_file"
	description = (
		"Replace an exact, unique block of text — `old` must appear exactly once "
		+ "or the edit is rejected. Empty `old` appends to the end of the file. Use "
		+ "create_file for new files; use edit_file_lines instead if you only have "
		+ "a line number, not the exact text."
	)
	required_permission = "WRITE_PROJECT"
	input_schema = {
		"type": "object",
		"properties": {
			"path": {"type": "string", "description": "Path relative to project root"},
			"old":  {"type": "string", "description": "Exact substring to replace; must be unique. Empty = append."},
			"new":  {"type": "string", "description": "Replacement text."},
		},
		"required": ["path", "new"],
	}

func execute(arguments: Dictionary) -> ToolResult:
	var raw_path := str(arguments.get("path", ""))
	if raw_path == "":
		return ToolResult.invalid_argument("Missing required argument: path")
	if not arguments.has("new"):
		return ToolResult.invalid_argument("edit_file requires 'new'")

	var old_text := str(arguments.get("old", ""))
	var new_text := str(arguments["new"])

	var full := resolve_path(raw_path)
	if full == "":
		return ToolResult.sandbox_violation("Path is outside the project sandbox: %s" % raw_path)
	if not FileAccess.file_exists(full):
		return ToolResult.not_found("File not found: %s" % raw_path)

	var f := FileAccess.open(full, FileAccess.READ)
	if f == null:
		return ToolResult.io_error("Cannot open file for read: %s (error %d)" % [raw_path, FileAccess.get_open_error()])
	var text := f.get_as_text()
	f.close()

	# Normalize the replacement text's leading whitespace to match the file's
	# existing indentation. The `old` block is untouched — it must match the
	# file's actual content exactly, and normalizing it would break matching.
	var indent_note := ""
	var target_indent := detect_indent_char(text)
	if target_indent != "" and new_text != "":
		var norm: Dictionary = normalize_indent(new_text, target_indent)
		var changed := int(norm.get("changed", 0))
		if changed > 0:
			new_text = str(norm["content"])
			var char_name := "tabs" if target_indent == "\t" else "spaces"
			indent_note = (
				"\n(Note: leading whitespace on %d line(s) of the new content "
				+ "was normalized to %s to match the file's existing indentation.)"
				% [changed, char_name]
			)

	var updated: String
	var mode: String
	if old_text == "":
		# Append to end of file.
		var sep := "" if text == "" or text.ends_with("\n") else "\n"
		updated = text + sep + new_text
		mode = "append"
	else:
		var occurrences := _count_occurrences(text, old_text)
		if occurrences == 0:
			return ToolResult.not_found(
				"`old` block not found in %s. Re-read the file first — it may have changed." % raw_path
			)
		if occurrences > 1:
			return ToolResult.invalid_argument(
				"`old` block matches %d times in %s; add more surrounding context so it is unique."
				% [occurrences, raw_path]
			)
		var idx := text.find(old_text)
		updated = text.substr(0, idx) + new_text + text.substr(idx + old_text.length())
		mode = "replace"

	var wf := FileAccess.open(full, FileAccess.WRITE)
	if wf == null:
		return ToolResult.io_error("Cannot open file for write: %s (error %d)" % [raw_path, FileAccess.get_open_error()])
	wf.store_string(updated)
	wf.close()

	var delta := updated.length() - text.length()
	var delta_str := ("+%d" % delta) if delta >= 0 else str(delta)
	return ToolResult.ok(
		"Edited %s (%s, %s chars)%s" % [raw_path, mode, delta_str, indent_note],
		{"path": raw_path, "mode": mode, "delta": delta}
	)

static func _count_occurrences(haystack: String, needle: String) -> int:
	var n := 0
	var from := 0
	while true:
		var i := haystack.find(needle, from)
		if i == -1:
			break
		n += 1
		from = i + needle.length()
	return n
