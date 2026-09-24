class_name ReadFilesTool
extends ProjectPathTool

# Batches several read_file-shaped reads into ONE tool call.
#
# Why this exists: on the DeepSeek Web Bridge (ModelProfile.Tier.WEB_CHAT),
# every single tool call is a real browser type -> wait -> parse round trip,
# 30-90s each (see webagent.txt / DEEPSEEK_BRIDGE_HANDOFF.md §1, §7.2). The
# tagged protocol already lets a reply batch several TOOL:/ARGS: pairs
# together (AgentLoop._extract_tagged_calls, MAX_RECOVERED_CALLS_PER_REPLY),
# so batching several read_file calls into one reply was already possible —
# but it still cost one call, one JSON blob, and one result block PER file.
# A model that already knows it needs Player.gd, PlayerState.gd, and the
# scene that owns them should be able to say so once. This tool is that:
# one call, one combined result, same per-file rules as read_file.
#
# Not wired into AgentLoop's per-tool-name tracking (FILE_PATH_TOOLS,
# PATH_DEFAULT_RES_TOOLS, the not-found nudge) because those all assume a
# single `path` argument — this tool reports missing/out-of-sandbox paths
# inline, per file, in its own output text instead.

const DEFAULT_LARGE_FILE_LINE_THRESHOLD := 400
# Hard cap on files per call. Not a round-trip concern (it's still one
# call either way) — it bounds how much text one tool result can dump back
# into the conversation, so a model that lists twenty files by habit still
# gets a bounded, truncation-safe result instead of blowing past
# max_tool_result_chars in one shot.
const MAX_FILES_PER_CALL := 8

var large_file_line_threshold: int = DEFAULT_LARGE_FILE_LINE_THRESHOLD

func _init() -> void:
	name = "read_files"
	description = (
		"Read up to %d files in ONE call. Use this instead of several separate "
		+ "read_file calls whenever you already know you need multiple files — "
		+ "e.g. a script and the scene/autoload it references. Same per-file rules "
		+ "as read_file (line-numbered content; a file over the large-file line "
		+ "threshold returns only its line count unless you give it a range). "
		+ "Every avoided call is a full round trip saved — this matters most on "
		+ "the web-chat bridge, where each tool call is a real browser wait."
	) % MAX_FILES_PER_CALL
	required_permission = "READ_PROJECT"
	_rebuild_schema()

# Set by MainWindow from the resolved ModelProfile, mirroring
# ReadFileTool.set_large_file_line_threshold() — kept in sync so the number
# quoted to the model always matches what's actually enforced below.
func set_large_file_line_threshold(n: int) -> void:
	large_file_line_threshold = maxi(1, n)
	_rebuild_schema()

func _rebuild_schema() -> void:
	input_schema = {
		"type": "object",
		"properties": {
			"files": {
				"type": "array",
				"description": (
					"1-%d files to read. Each item is either a plain path string, "
					+ "or an object {\"path\": ..., \"start_line\": ..., \"end_line\": ...} "
					+ "when you need a specific range for that file. Files over %d "
					+ "lines are returned as a line count only unless you supply "
					+ "start_line/end_line for that item — same rule as read_file."
				) % [MAX_FILES_PER_CALL, large_file_line_threshold],
				"items": {
					"type": ["string", "object"],
					"properties": {
						"path": {"type": "string", "description": "Path relative to project root, e.g. res://Player.gd"},
						"start_line": {"type": "integer", "description": "1-based start line for this file only."},
						"end_line": {"type": "integer", "description": "1-based end line for this file only."},
					},
				},
			},
		},
		"required": ["files"],
	}

func execute(arguments: Dictionary) -> ToolResult:
	var files_v: Variant = arguments.get("files", [])
	if typeof(files_v) != TYPE_ARRAY:
		return ToolResult.invalid_argument(
			"`files` must be an array of paths (or {path, start_line, end_line} objects)"
		)
	var files: Array = files_v
	if files.is_empty():
		return ToolResult.invalid_argument("`files` must not be empty")

	var overflow_note := ""
	if files.size() > MAX_FILES_PER_CALL:
		overflow_note = (
			"\n[note: %d file(s) requested — only the first %d were read this call. "
			+ "Issue a second read_files call for the rest.]"
		) % [files.size(), MAX_FILES_PER_CALL]
		files = files.slice(0, MAX_FILES_PER_CALL)

	var sections := PackedStringArray()
	var per_file: Array = []
	var any_ok := false

	for item_v in files:
		var spec := _normalize_spec(item_v)
		var raw_path := str(spec.get("path", "")).strip_edges()
		if raw_path == "":
			sections.append("=== (missing path) ===\nERROR: this item had no `path`.")
			per_file.append({"path": "", "success": false})
			continue

		var one := _read_one(raw_path, spec)
		var ok := bool(one.get("success", false))
		any_ok = any_ok or ok
		sections.append("=== %s ===\n%s" % [raw_path, str(one.get("text", ""))])
		per_file.append({"path": raw_path, "success": ok})

	var body := "\n\n".join(sections) + overflow_note
	var meta := {"files": per_file, "requested": per_file.size()}

	# Only a total failure (every file missing/out-of-sandbox/unreadable) is
	# reported as an error — a mixed batch (2 read fine, 1 doesn't exist)
	# comes back ok() with the per-file ERROR: line still visible in the
	# body, so a real read isn't punished for a typo in a sibling path.
	if not any_ok:
		return ToolResult.failure(body, ToolResult.ErrorKind.NOT_FOUND, meta)
	return ToolResult.ok(body, meta)

# Accepts either a plain string ("res://X.gd") or
# {"path": ..., "start_line": ..., "end_line": ...}.
static func _normalize_spec(item_v: Variant) -> Dictionary:
	if typeof(item_v) == TYPE_STRING:
		return {"path": item_v}
	if typeof(item_v) == TYPE_DICTIONARY:
		return item_v
	return {}

# Mirrors ReadFileTool.execute()'s logic for a single file, returning
# {"success": bool, "text": String} instead of a ToolResult, since the
# caller is assembling several of these into one combined result.
func _read_one(raw_path: String, spec: Dictionary) -> Dictionary:
	var full := resolve_path(raw_path)
	if full == "":
		return {"success": false, "text": "ERROR: path is outside the project sandbox."}
	if not FileAccess.file_exists(full):
		return {"success": false, "text": "ERROR: file not found."}

	var f := FileAccess.open(full, FileAccess.READ)
	if f == null:
		return {"success": false, "text": "ERROR: cannot open file (error %d)." % FileAccess.get_open_error()}
	var text := f.get_as_text()
	f.close()

	var lines := text.split("\n")
	var total_lines := lines.size()
	var has_range := spec.has("start_line") or spec.has("end_line")

	if total_lines > large_file_line_threshold and not has_range:
		return {
			"success": true,
			"text": (
				"%d lines — too large to return in full. Re-request this file "
				+ "(via read_files or read_file) with start_line/end_line for a "
				+ "specific range."
			) % total_lines,
		}

	var start_i := 1
	var end_i := total_lines
	if spec.has("start_line"):
		start_i = maxi(1, int(spec["start_line"]))
	if spec.has("end_line"):
		end_i = mini(total_lines, int(spec["end_line"]))
	if start_i > end_i:
		return {"success": false, "text": "ERROR: invalid line range: %d..%d." % [start_i, end_i]}

	var out := PackedStringArray()
	for i in range(start_i - 1, end_i):
		out.append("%6d\t%s" % [i + 1, lines[i]])
	return {"success": true, "text": "\n".join(out)}
