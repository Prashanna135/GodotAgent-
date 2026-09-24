class_name EditFileLinesTool
extends ProjectPathTool

func _init() -> void:
	name = "edit_file_lines"
	description = (
		"Replace lines by line number instead of exact text — use when you have a line "
		+ "number (from check_script/check_project or read_file) rather than certain "
		+ "exact text; unlike edit_file, never fails on a whitespace mismatch. 1-based, "
		+ "inclusive. end_line = start_line - 1 inserts without removing; empty content "
		+ "deletes without inserting."
	)
	required_permission = "WRITE_PROJECT"
	input_schema = {
		"type": "object",
		"properties": {
			"path": {"type": "string", "description": "Path relative to project root"},
			"start_line": {"type": "integer", "description": "1-based first line to replace (or insert before)."},
			"end_line": {"type": "integer", "description": "1-based last line to replace, inclusive. Defaults to start_line. Set to start_line - 1 to insert without replacing."},
			"content": {"type": "string", "description": "Replacement text (may be empty or span multiple lines). Empty = delete the range."},
		},
		"required": ["path", "start_line", "content"],
	}

func execute(arguments: Dictionary) -> ToolResult:
	var raw_path := str(arguments.get("path", ""))
	if raw_path == "":
		return ToolResult.invalid_argument("Missing required argument: path")
	if not arguments.has("start_line"):
		return ToolResult.invalid_argument("Missing required argument: start_line")
	if not arguments.has("content"):
		return ToolResult.invalid_argument("Missing required argument: content")

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

	var lines := text.split("\n")
	var total_lines := lines.size()

	var start_i := int(arguments["start_line"])
	var end_i := int(arguments.get("end_line", start_i))
	var content := str(arguments["content"])

	if start_i < 1 or start_i > total_lines + 1:
		return ToolResult.invalid_argument(
			"start_line %d is out of range for %s (file has %d line(s); valid range 1..%d)."
			% [start_i, raw_path, total_lines, total_lines + 1]
		)
	if end_i < start_i - 1 or end_i > total_lines:
		return ToolResult.invalid_argument(
			"end_line %d is out of range for %s given start_line %d (file has %d line(s))."
			% [end_i, raw_path, start_i, total_lines]
		)

	# Indent normalization: convert the leading whitespace of each new line
	# to match the target file's existing style. Saves the model from having
	# to match tabs vs spaces exactly, and prevents the "space indent in a
	# tab file" parse error that would otherwise fire on the next check.
	var indent_note := ""
	var target_indent := detect_indent_char(text)
	if target_indent != "" and content != "":
		var norm: Dictionary = normalize_indent(content, target_indent)
		var changed := int(norm.get("changed", 0))
		if changed > 0:
			content = str(norm["content"])
			var char_name := "tabs" if target_indent == "\t" else "spaces"
			indent_note = (
				"\n(Note: leading whitespace on %d line(s) was normalized to %s "
				+ "to match the file's existing indentation.)" % [changed, char_name]
			)

	var new_lines: PackedStringArray = PackedStringArray() if content == "" else content.split("\n")

	var before: PackedStringArray = lines.slice(0, start_i - 1)
	var after: PackedStringArray = lines.slice(end_i)

	var updated_array := PackedStringArray()
	updated_array.append_array(before)
	updated_array.append_array(new_lines)
	updated_array.append_array(after)
	var updated := "\n".join(updated_array)

	var wf := FileAccess.open(full, FileAccess.WRITE)
	if wf == null:
		return ToolResult.io_error("Cannot open file for write: %s (error %d)" % [raw_path, FileAccess.get_open_error()])
	wf.store_string(updated)
	wf.close()

	var removed := maxi(0, end_i - start_i + 1)
	var inserted := new_lines.size()
	var mode: String
	if removed == 0:
		mode = "inserted %d line(s) before line %d" % [inserted, start_i]
	elif inserted == 0:
		mode = "deleted line(s) %d-%d" % [start_i, end_i]
	else:
		mode = "replaced line(s) %d-%d with %d line(s)" % [start_i, end_i, inserted]

	return ToolResult.ok(
		"Edited %s (%s).%s" % [raw_path, mode, indent_note],
		{"path": raw_path, "start_line": start_i, "end_line": end_i, "removed": removed, "inserted": inserted}
	)
