class_name ErrorParser
extends RefCounted

# Godot's headless output interleaves a few different shapes:
#
#   SCRIPT ERROR: Parse Error: Identifier "foo" not declared in the current scope.
#             at: GDScript::reload (res://Player.gd:42)
#
#   ERROR: Failed to load script "res://Player.gd" with error "Parse error".
#      at: load (modules/gdscript/gdscript.cpp:2936)
#
#   WARNING: Integer division, decimal part will be discarded.
#        at: _process (res://Player.gd:23)
#
# The `at:` continuation line carries the res:// file and line number we want.
# Everything else — C++ source traces, indented stack frames — is engine
# internals and noise for a coding model, so we drop it.
#
# This is a best-effort parser, not a grammar. If a line doesn't look like a
# header or a location, it's skipped. Callers fall back to raw output when
# parse() returns nothing, so a miss is degraded, not broken.

const ERROR_PREFIX := "ERROR:"
const SCRIPT_ERROR_PREFIX := "SCRIPT ERROR:"
const WARNING_PREFIX := "WARNING:"

# Lazily compiled; RegEx.compile() is cheap but we call it per-line in some
# paths, so reusing the instance matters.

const ANSI_PATTERN := "\\x1b\\[[0-9;]*[A-Za-z]"
static var _ANSI_RE: RegEx = null

# Explicit `: RegEx` annotations are load-bearing: without them GDScript
# types these as Variant, `.search()` returns Variant, and every `:=` at a
# call site fails to infer. The annotation is what makes the whole file
# type-check cleanly.
static var _LOCATION_RE: RegEx = null
static var _IDENT_V4_RE: RegEx = null
static var _IDENT_LEGACY_RE: RegEx = null
static var _QUOTED_RES_RE: RegEx = null

# --- public API -------------------------------------------------------------

static func parse(text: String) -> Array:
	var out: Array = []
	if text.strip_edges() == "":
		return out
	var lines := text.split("\n")
	var i := 0
	while i < lines.size():
		var line: String = lines[i]
		var header := _classify_header(line)
		if header.is_empty():
			i += 1
			continue
		var ev := DebugEvent.new()
		ev.severity = header["severity"]
		ev.message = header["message"]
		ev.raw = line
		# Some ERROR lines carry the file inline:
		#   ERROR: Failed to load script "res://board/start_menu.gd" with error "..."
		# Extract it so dedupe() can match the wrapper to its located counterpart.
		# Without this, the wrapper lands as file="" line=0 and survives dedupe,
		# duplicating the underlying parse error in every tool result.
		ev.file = _extract_quoted_res_path(ev.message)
		var loc := _scan_for_location(lines, i + 1, 3)
		if not loc.is_empty():
			ev.file = str(loc.get("file", ev.file))
			ev.line = int(loc.get("line", 0))
			ev.column = int(loc.get("column", 0))
			ev.raw += "\n" + str(loc.get("raw_line", ""))
		ev.source = _classify_source(ev)
		out.append(ev)
		if not loc.is_empty():
			i = int(loc.get("consumed_through", i)) + 1
		else:
			i += 1
	return out

# Collapse duplicates and drop "Failed to load script X" wrapper events when
# X also has a located event of its own — Godot reports the same problem
# twice (underlying parse error + engine-level load failure) and the wrapper
# carries no line number, so it's strictly less useful.
static func dedupe(events: Array) -> Array:
	var seen: Dictionary = {}
	var unique: Array = []
	for e in events:
		var ev := e as DebugEvent
		if ev == null:
			continue
		var key := "%d|%s|%d|%s" % [ev.severity, ev.file, ev.line, ev.message]
		if seen.has(key):
			continue
		seen[key] = true
		unique.append(ev)

	var located_files: Dictionary = {}
	for e in unique:
		var ev := e as DebugEvent
		if ev.line > 0 and ev.file != "":
			located_files[ev.file] = true

	var out: Array = []
	for e in unique:
		var ev := e as DebugEvent
		if ev.file != "" and ev.line == 0 and located_files.has(ev.file):
			if ev.message.find("Failed to load script") != -1:
				continue
		out.append(ev)
	return out

static func summarize(events: Array) -> String:
	if events.is_empty():
		return ""
	var lines := PackedStringArray()
	for e in events:
		var ev := e as DebugEvent
		if ev != null:
			lines.append(ev.to_summary())
	return "\n".join(lines)

# Given a DebugEvent message like:
#   Parse Error: Identifier "GameSettings" not declared in the current scope.
#   Parse Error: Identifier not found: GameSettings
# returns the bare identifier ("GameSettings"), else "".
static func extract_missing_identifier(message: String) -> String:
	if _IDENT_V4_RE == null:
		_IDENT_V4_RE = RegEx.new()
		_IDENT_V4_RE.compile("Identifier \"(\\w+)\" not declared")
	var m: RegExMatch = _IDENT_V4_RE.search(message)
	if m != null:
		return m.get_string(1)
	if _IDENT_LEGACY_RE == null:
		_IDENT_LEGACY_RE = RegEx.new()
		_IDENT_LEGACY_RE.compile("Identifier not found: (\\w+)")
	var m2: RegExMatch = _IDENT_LEGACY_RE.search(message)
	if m2 != null:
		return m2.get_string(1)
	return ""

# --- internals --------------------------------------------------------------

static func _classify_header(line: String) -> Dictionary:
	var sev: int = -1
	var msg := ""
	if line.begins_with(SCRIPT_ERROR_PREFIX):
		sev = DebugEvent.Severity.ERROR
		msg = line.substr(SCRIPT_ERROR_PREFIX.length()).strip_edges()
	elif line.begins_with(ERROR_PREFIX):
		sev = DebugEvent.Severity.ERROR
		msg = line.substr(ERROR_PREFIX.length()).strip_edges()
	elif line.begins_with(WARNING_PREFIX):
		sev = DebugEvent.Severity.WARNING
		msg = line.substr(WARNING_PREFIX.length()).strip_edges()
	else:
		return {}
	if msg == "":
		return {}
	return {"severity": sev, "message": msg}

# Look at the next few lines for a `(file.gd:N)` shape. Godot's `at:` line is
# indented with spaces, so we strip before matching. Stop early if we hit a
# new header, so we don't attach a location from an unrelated block.
static func _scan_for_location(lines: Array, start: int, max_look: int) -> Dictionary:
	if _LOCATION_RE == null:
		_LOCATION_RE = RegEx.new()
		_LOCATION_RE.compile("\\(([^()]+\\.gd):(\\d+)(?::(\\d+))?\\)")
	var end_i := mini(start + max_look, lines.size())
	for j in range(start, end_i):
		var l: String = lines[j]
		if l.strip_edges() == "":
			continue
		if not _classify_header(l).is_empty():
			return {}
		var m: RegExMatch = _LOCATION_RE.search(l)
		if m == null:
			continue
		var file := m.get_string(1).strip_edges()
		var line_no := int(m.get_string(2))
		var col := 0
		if m.get_string(3) != "":
			col = int(m.get_string(3))
		return {
			"file": file,
			"line": line_no,
			"column": col,
			"raw_line": l,
			"consumed_through": j,
		}
	return {}

# Extract `res://...` from a quoted string inside a message, e.g.
#   Failed to load script "res://board/start_menu.gd" with error "..."
# Returns "" when the message has no quoted res:// path. Used to give wrapper
# events a file identity so dedupe() can match them against their located
# counterparts.
static func _extract_quoted_res_path(message: String) -> String:
	if message == "":
		return ""
	if _QUOTED_RES_RE == null:
		_QUOTED_RES_RE = RegEx.new()
		_QUOTED_RES_RE.compile("\"(res://[^\"]+)\"")
	var m: RegExMatch = _QUOTED_RES_RE.search(message)
	if m != null:
		return m.get_string(1)
	return ""

static func _classify_source(ev: DebugEvent) -> int:
	var msg_lower := ev.message.to_lower()
	if msg_lower.find("parse error") != -1 \
			or msg_lower.find("syntax error") != -1 \
			or msg_lower.find("not declared in the current scope") != -1 \
			or msg_lower.find("identifier not found") != -1:
		return DebugEvent.Source.PARSE
	if msg_lower.find("failed to load script") != -1 \
			or msg_lower.find("cannot open file") != -1:
		return DebugEvent.Source.LOAD
	return DebugEvent.Source.RUNTIME


# Strips ANSI/VT100 escape sequences. Godot's own --editor --quit scan
# output (progress bars, colorized log lines) is full of them, and the
# raw ESC byte is exactly what strict JSON parsers reject — so a
# launch_headless result used to poison every subsequent request body.
static func strip_ansi(text: String) -> String:
	if _ANSI_RE == null:
		_ANSI_RE = RegEx.new()
		_ANSI_RE.compile(ANSI_PATTERN)
	return _ANSI_RE.sub(text, "", true)
