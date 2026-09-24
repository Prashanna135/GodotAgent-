class_name ReadFileTool
extends ProjectPathTool

# Default if MainWindow never applies a ModelProfile (see
# set_large_file_line_threshold() below). Files larger than this many lines
# won't be dumped whole on an unranged read_file call — the model must
# supply start_line/end_line. Prevents a silent
# AgentLoop.max_tool_result_chars truncation from handing back a chunk that
# doesn't even contain the part of the file the model needs (e.g. a parse
# error reported by check_project at a line past the cut).
const DEFAULT_LARGE_FILE_LINE_THRESHOLD := 400

var large_file_line_threshold: int = DEFAULT_LARGE_FILE_LINE_THRESHOLD

func _init() -> void:
	name = "read_file"
	description = "Read a UTF-8 text file inside the selected project. Returns line-numbered content."
	required_permission = "READ_PROJECT"
	_rebuild_schema()

# Set by MainWindow from the resolved ModelProfile. Rebuilds input_schema so
# the number quoted to the model in start_line/end_line's description always
# matches the threshold actually enforced below — a stale number here would
# have the model believe a different cutoff than the one that fires.
func set_large_file_line_threshold(n: int) -> void:
	large_file_line_threshold = maxi(1, n)
	_rebuild_schema()

func _rebuild_schema() -> void:
	input_schema = {
		"type": "object",
		"properties": {
			"path": {"type": "string", "description": "Path relative to project root, e.g. res://Player.gd"},
			"start_line": {"type": "integer", "description": "1-based start line. REQUIRED for files over %d lines — call read_file without a range first to get the line count, then request the specific range you need (e.g. around a reported error line)." % large_file_line_threshold},
			"end_line": {"type": "integer", "description": "1-based end line. REQUIRED for files over %d lines — see start_line." % large_file_line_threshold},
		},
		"required": ["path"],
	}

func execute(arguments: Dictionary) -> ToolResult:
	var raw_path := str(arguments.get("path", ""))
	if raw_path == "":
		return ToolResult.failure("Missing required argument: path")
	var full := resolve_path(raw_path)
	if full == "":
		return ToolResult.failure("Path is outside the project sandbox: %s" % raw_path)
	if not FileAccess.file_exists(full):
		return ToolResult.failure("File not found: %s" % raw_path)

	var f := FileAccess.open(full, FileAccess.READ)
	if f == null:
		return ToolResult.failure("Cannot open file: %s (error %d)" % [raw_path, FileAccess.get_open_error()])
	var text := f.get_as_text()
	f.close()

	var lines := text.split("\n")
	var total_lines := lines.size()
	var has_range := arguments.has("start_line") or arguments.has("end_line")

	# Large file, no range given: refuse to dump it and tell the model
	# exactly how many lines there are so it can ask for a real range.
	if total_lines > large_file_line_threshold and not has_range:
		return ToolResult.ok(
			(
				"%s has %d lines — too large to return in full. "
				+ "Call read_file again with start_line/end_line to view a specific range "
				+ "(e.g. around a line number from check_script/check_project output, "
				+ "or search_text/find_symbol to locate what you need first)."
			) % [raw_path, total_lines],
			{"path": raw_path, "total_lines": total_lines, "truncated_header_only": true}
		)

	var start_i := 1
	var end_i := total_lines
	if arguments.has("start_line"):
		start_i = max(1, int(arguments["start_line"]))
	if arguments.has("end_line"):
		end_i = min(total_lines, int(arguments["end_line"]))
	if start_i > end_i:
		return ToolResult.failure("Invalid line range: %d..%d" % [start_i, end_i])

	var out := PackedStringArray()
	for i in range(start_i - 1, end_i):
		out.append("%6d\t%s" % [i + 1, lines[i]])
	return ToolResult.ok("\n".join(out), {
		"path": raw_path,
		"start_line": start_i,
		"end_line": end_i,
		"total_lines": total_lines,
	})
