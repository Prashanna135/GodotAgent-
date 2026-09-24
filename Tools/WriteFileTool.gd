class_name WriteFileTool
extends ProjectPathTool

# Refuse to shrink an existing file below this fraction of its size. Small
# models sometimes call write_file intending to "write the fixed file" and
# instead emit placeholder text like "[[existing content before line 42]]"
# because the real content didn't fit in their context window. That
# replaces a large, working file with a few bytes of garbage. Recovery via
# checkpoints works, but the write should never land in the first place.
const MIN_SHRINK_RATIO := 0.20
# Absolute floor: if the existing file is at least this many bytes, the
# new content must be at least MIN_SHRINK_RATIO of it. Below this size the
# ratio check is skipped — small files legitimately shrink.
const SHRINK_CHECK_MIN_BYTES := 1024

func _init() -> void:
	name = "write_file"
	description = (
		"Overwrite an ENTIRE file. Only use when you have the file's full current "
		+ "content — prefer edit_file for small changes, edit_file_lines when you "
		+ "have a line number. A partial write destroys the rest of the file."
	)
	required_permission = "WRITE_PROJECT"
	input_schema = {
		"type": "object",
		"properties": {
			"path": {"type": "string"},
			"content": {"type": "string"},
		},
		"required": ["path", "content"],
	}

func execute(arguments: Dictionary) -> ToolResult:
	var raw_path := str(arguments.get("path", ""))
	var content := str(arguments.get("content", ""))
	if raw_path == "":
		return ToolResult.failure("Missing required argument: path")
	var full := resolve_path(raw_path)
	if full == "":
		return ToolResult.failure("Path is outside the project sandbox: %s" % raw_path)

	# Catastrophic-shrink guard. Runs before the write, only when the file
	# already exists. A brand-new file is exempt by definition.
	if FileAccess.file_exists(full):
		var existing_size := _file_size(full)
		if existing_size >= SHRINK_CHECK_MIN_BYTES:
			var new_size := content.length()
			if new_size < int(existing_size * MIN_SHRINK_RATIO):
				return ToolResult.invalid_argument(
					(
						"Refusing to write %s: this would replace a %d-byte file "
						+ "with %d bytes (less than %d%% of the original). "
						+ "write_file REPLACES all content — if you don't have "
						+ "the file's full current text, use edit_file (exact "
						+ "old→new replace) or edit_file_lines (by line number) "
						+ "instead. If you genuinely intend to shrink this file, "
						+ "edit it down in steps with edit_file_lines, or delete "
						+ "and recreate it with create_file."
					) % [
						raw_path,
						existing_size,
						new_size,
						int(MIN_SHRINK_RATIO * 100),
					]
				)

	var dir := full.get_base_dir()
	if not DirAccess.dir_exists_absolute(dir):
		var err := DirAccess.make_dir_recursive_absolute(dir)
		if err != OK:
			return ToolResult.failure("Could not create directory %s (error %d)" % [dir, err])
	var f := FileAccess.open(full, FileAccess.WRITE)
	if f == null:
		return ToolResult.failure("Cannot write file: %s (error %d)" % [raw_path, FileAccess.get_open_error()])
	f.store_string(content)
	f.close()
	return ToolResult.ok("Wrote %d bytes to %s" % [content.length(), raw_path], {"path": raw_path})

static func _file_size(path: String) -> int:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return 0
	var n := f.get_length()
	f.close()
	return n
