class_name GodotTool
extends ProjectPathTool

# Injected by the harness.
var process_manager = null   # GodotProcessManager (typed loosely, Node)
var godot_executable: String = ""

# Injected by MainWindow from AppSettings.resolved_profile(). Null means "no
# profile applied yet" — treated as hints-enabled, matching the old
# unconditional behavior, so a tool used before MainWindow finishes wiring
# doesn't silently lose its error-recovery hints.
var model_profile: ModelProfile = null

func _resolve_executable() -> String:
	var p := godot_executable.strip_edges()
	if p != "":
		return p
	return "godot"   # let OS resolve via PATH as a fallback

# Whether syntax_hints_for_events() output should be appended to failure
# messages. Gated by ModelProfile.append_syntax_hints — a capable cloud
# model doesn't need "GDScript comments use # not //" spelled out on every
# failed check, and it costs tokens on every single one.
func _hints_enabled() -> bool:
	return model_profile == null or model_profile.append_syntax_hints

# --- structured error output ----------------------------------------------
#
# Godot's headless output mixes engine-internal chatter with the parse/runtime
# errors we actually care about. ErrorParser extracts the real errors as
# DebugEvent records so the tool can hand the model a short, structured
# summary above the raw text.
#
# Returns {"text": String, "events": Array}. `text` is "" when the parser
# found nothing parseable, and callers should then fall back to showing the
# raw output unchanged — a parser miss degrades to the old behavior.

func _annotate_output(raw: String) -> Dictionary:
	var events := ErrorParser.dedupe(ErrorParser.parse(raw))
	if events.is_empty():
		return {"text": "", "events": []}
	var errors := 0
	var warnings := 0
	for e in events:
		var ev := e as DebugEvent
		if ev == null:
			continue
		if ev.severity == DebugEvent.Severity.ERROR:
			errors += 1
		elif ev.severity == DebugEvent.Severity.WARNING:
			warnings += 1
	var header := "Parsed %d issue(s)" % events.size()
	if errors > 0 or warnings > 0:
		header += " (%d error(s), %d warning(s))" % [errors, warnings]
	var body := header + ":\n" + ErrorParser.summarize(events)
	return {"text": body, "events": events}

# --- autoload-aware false positive filtering -------------------------------
#
# `godot --headless --check-only --script <path>` checks a script mostly
# in isolation: it does NOT set up the project's [autoload] singletons the
# way a real scene boot does. Any script that legitimately references an
# autoload (e.g. `GameSettings.mode`) throws a spurious
# "Identifier not found: GameSettings" under --check-only, even though the
# same script loads and runs fine under launch_headless / launch_project.
#
# We read the project's own [autoload] section (the ground truth for what
# singletons actually exist) and, if every "Identifier not found" error in
# a check-only run's output refers to a known autoload name, treat that
# run as a false positive rather than a real compile error.

func _load_autoload_names() -> Array:
	var names: Array = []
	if project_root == "":
		return names
	var pg := project_root.path_join("project.godot")
	if not FileAccess.file_exists(pg):
		return names
	var cfg := ConfigFile.new()
	if cfg.load(pg) != OK:
		return names
	if not cfg.has_section("autoload"):
		return names
	for key in cfg.get_section_keys("autoload"):
		names.append(str(key))
	return names

# Prefer the structured check when the parser produced events; fall back to
# the raw-text regex only when it didn't (unusual/unknown output format).
func _is_false_positive_check(events: Array, raw_text: String, autoload_names: Array) -> bool:
	if autoload_names.is_empty():
		return false
	if not events.is_empty():
		return _is_false_positive_autoload_event(events, autoload_names)
	return _is_false_positive_autoload_error(raw_text, autoload_names)

# Structured equivalent of the legacy text-regex check. Returns true only if
# every ERROR-severity event refers to a known autoload identifier. A single
# genuine error anywhere in the same run still fails the check normally.
#
# LOAD-source events ("Failed to load script X with error Y") are skipped:
# they're wrappers for an underlying parse error and don't carry the
# identifier name, so counting them would poison the decision.
static func _is_false_positive_autoload_event(events: Array, autoload_names: Array) -> bool:
	if autoload_names.is_empty() or events.is_empty():
		return false
	var found_autoload_error := false
	var found_real_error := false
	for e in events:
		var ev := e as DebugEvent
		if ev == null or ev.severity != DebugEvent.Severity.ERROR:
			continue
		if ev.source == DebugEvent.Source.LOAD:
			continue
		var ident := ErrorParser.extract_missing_identifier(ev.message)
		if ident != "" and (ident in autoload_names):
			found_autoload_error = true
		else:
			found_real_error = true
	return found_autoload_error and not found_real_error

# Legacy text-based check — kept as a fallback for outputs the structured
# parser doesn't recognize, and to keep existing call sites compiling.
#
# Returns true only if EVERY "SCRIPT ERROR:" line in `text` is an
# "Identifier not found: <name>" error where <name> is a known autoload.
static func _is_false_positive_autoload_error(text: String, autoload_names: Array) -> bool:
	if autoload_names.is_empty():
		return false
	var re := RegEx.new()
	re.compile("SCRIPT ERROR:.*Identifier not found: (\\w+)")
	var found_autoload_error := false
	var found_real_error := false
	for line in text.split("\n"):
		if line.find("SCRIPT ERROR:") == -1:
			continue
		var m := re.search(line)
		if m != null and (m.get_string(1) in autoload_names):
			found_autoload_error = true
		else:
			found_real_error = true
	return found_autoload_error and not found_real_error

# Convenience for tool metadata: convert DebugEvent objects to plain dicts so
# metadata stays serializable-friendly for a future session persistence pass.
static func events_to_dicts(events: Array) -> Array:
	var out: Array = []
	for e in events:
		var ev := e as DebugEvent
		if ev != null:
			out.append(ev.to_dict())
	return out

# When a check run contains a real error, we still report it as a failure —
# but autoload-reference events inside that same run are still false
# positives and shouldn't be shown to the model as things to fix. This
# strips them out, keeping the LOAD-source wrappers (which name the failed
# file) and any genuine errors.
#
# Returns {"real": Array[DebugEvent], "filtered_idents": PackedStringArray}.
static func filter_false_positive_events(events: Array, autoload_names: Array) -> Dictionary:
	var real: Array = []
	var filtered: PackedStringArray = PackedStringArray()
	for e in events:
		var ev := e as DebugEvent
		if ev == null:
			continue
		if ev.severity != DebugEvent.Severity.ERROR:
			real.append(ev)
			continue
		if ev.source == DebugEvent.Source.LOAD:
			# Wrapper for a real error — the file it names may be the one
			# the model needs to look at, so keep it.
			real.append(ev)
			continue
		var ident := ErrorParser.extract_missing_identifier(ev.message)
		if ident != "" and (ident in autoload_names):
			if not (ident in filtered):
				filtered.append(ident)
			continue
		real.append(ev)
	return {"real": real, "filtered_idents": filtered}

# Build the "Parsed N issue(s)..." block from a filtered event list.
# `filtered_idents` names the autoload identifiers that were stripped, so
# the model sees them acknowledged rather than silently disappeared.
static func summarize_filtered_events(real_events: Array, filtered_idents: PackedStringArray) -> String:
	if real_events.is_empty() and filtered_idents.is_empty():
		return ""
	var errors := 0
	var warnings := 0
	for e in real_events:
		var ev := e as DebugEvent
		if ev == null:
			continue
		if ev.severity == DebugEvent.Severity.ERROR:
			errors += 1
		elif ev.severity == DebugEvent.Severity.WARNING:
			warnings += 1
	var body := "Parsed %d issue(s) (%d error(s), %d warning(s)):" % [real_events.size(), errors, warnings]
	if not real_events.is_empty():
		body += "\n" + ErrorParser.summarize(real_events)
	if not filtered_idents.is_empty():
		var plural := filtered_idents.size() != 1
		body += (
			"\n(Also %d autoload-reference false positive%s filtered: %s. "
			+ "Declared in project.godot's [autoload] section — not real errors.)"
		) % [filtered_idents.size(), ("s" if plural else ""), ", ".join(filtered_idents)]
	return body

# --- error-specific hints (small/local model support) ---------------------
#
# Small models routinely misdiagnose Godot parse errors. The most common
# example: writing a `//` comment (C-family habit) instead of `#`, then
# reading the resulting "Unexpected '/' " error, correctly guessing it's a
# comment-syntax problem in prose, and *making the same mistake again* —
# because the retry prompt never told it the actual fix. Every check tool
# pairs the failure with hints classified from the parsed DebugEvent
# messages (when model_profile.append_syntax_hints allows it — see
# _hints_enabled() above), so the fix is one turn away instead of five.
#
# Deliberately conservative: hints fire only on messages we recognize, and
# hints are deduplicated so a file with three `//` comments gets one hint,
# not three.

static func syntax_hints_for_events(events: Array) -> PackedStringArray:
	var hints: PackedStringArray = PackedStringArray()
	var seen: Dictionary = {}
	for e in events:
		var ev := e as DebugEvent
		if ev == null or ev.severity != DebugEvent.Severity.ERROR:
			continue
		var hint := _hint_for_message(ev.message)
		if hint != "" and not seen.has(hint):
			seen[hint] = true
			hints.append(hint)
	return hints

static func _hint_for_message(msg: String) -> String:
	var lower := msg.to_lower()
	# --- parse-time ---
	if lower.find('unexpected "/"') != -1:
		return "GDScript comments use `#`, not `//`. A `/` at the start of a line is parsed as an operator — replace `//` with `#`."
	# The most common indentation failure: the model wrote spaces where the
	# rest of the file uses tabs (often from copy-pasting prose or Python
	# snippets). Godot reports this as "Used space character for indentation
	# instead of tab as used before in the file." — not as "unindent".
	if lower.find("used space character for indentation") != -1:
		return (
			"This line is indented with SPACES, but the rest of the file uses "
			+ "TABs. GDScript requires consistent indentation per file. Replace "
			+ "the leading spaces with the correct number of TAB characters: "
			+ "`read_file` the surrounding lines to see their indent level, then "
			+ "`edit_file_lines` to replace this line with a tab-indented version."
		)
	if lower.find("used tab character for indentation") != -1:
		return (
			"This line is indented with a TAB, but the surrounding lines use "
			+ "spaces. Match the file's existing convention — replace the leading "
			+ "tab with the same indentation the surrounding lines use."
		)
	if lower.find('unexpected "indent"') != -1:
		return "This line is indented, but class-level declarations (`var`, `const`, `func`, `signal`, `enum`, `class_name`, `extends`) must start at column 0. Remove the leading whitespace."
	if lower.find('unexpected "dedent"') != -1 or lower.find("unindent") != -1:
		return "This line's indentation doesn't match its enclosing block. Use TABs and keep them consistent with the surrounding lines."
	if lower.find("identifier") != -1 and (lower.find("not declared") != -1 or lower.find("not found") != -1):
		return (
			"An identifier is used but not declared in this file. The "
			+ "declaration may be missing, misspelled, or it may live in "
			+ "another file. `find_symbol(\"Name\")` reports declarations "
			+ "elsewhere. If it's a local variable or method that should "
			+ "exist here, `read_file` the surrounding lines to see how "
			+ "it's used, then re-add its declaration."
		)
	if lower.find("not found in base self") != -1:
		return (
			"A method is called on `self` that isn't declared in this "
			+ "class. Either the method was removed, the name is misspelled, "
			+ "or it lives on a parent class. `read_file` around this line "
			+ "and check whether the method body exists elsewhere in the file."
		)
	if lower.find('expected ":"') != -1:
		return "A `:` is missing. GDScript requires it after `func`, `if`, `elif`, `else`, `for`, `while`, `match`, and `class_name`."
	if lower.find('expected "("') != -1 or lower.find('expected ")"') != -1:
		return "A parenthesis is missing or unbalanced on this line."
	if lower.find("expected indented block") != -1:
		return "A `:` was followed by nothing indented. Add a TAB-indented body after it."
	if lower.find("standalone expression") != -1:
		return "This line is a bare expression with no effect. Did you mean `x = ...` (assignment) or `x.method()` (call)?"
	# --- runtime ---
	if lower.find("nonexistent function") != -1:
		return "The function name doesn't exist on that object. Check spelling and the object's actual class — `find_symbol` shows declarations across the project."
	if lower.find("invalid call") != -1:
		return "A method or property is being called that doesn't exist, or with the wrong argument count. Check the receiver's type and method signature."
	if lower.find("invalid get index") != -1 or lower.find("invalid set index") != -1:
		return "Indexing into an array/dictionary with a key or index that doesn't exist. Check the container's size and keys."
	if lower.find("null instance") != -1:
		return "A `null` value is being used as if it were an object. Check that the node or instance has been created and assigned before this line runs."
	return ""
