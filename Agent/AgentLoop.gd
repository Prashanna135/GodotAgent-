class_name AgentLoop
extends Node

signal state_changed(state: int)
signal assistant_text(text: String)
signal tool_started(tool_name: String, arguments: Dictionary)
signal tool_finished(tool_name: String, result: ToolResult)
signal finished(reason: String)

# Safe fallback if MainWindow never applies a ModelProfile (shouldn't happen
# in practice — it applies one at startup and on every settings change).
# See the `max_tool_result_chars` etc. vars below, set from ModelProfile.
const DEFAULT_MAX_TOOL_RESULT_CHARS := 16_000

# --- loop / thrash detection ----------------------------------------------
const REPEATED_CALL_WINDOW := 8
const THRASH_WINDOW := 6

const WRITE_TOOL_NAMES := ["write_file", "create_file", "edit_file", "edit_file_lines", "delete_file"]

const STATE_CHANGE_TOOL_NAMES := [
	"write_file", "create_file", "edit_file", "edit_file_lines", "delete_file",
	"revert_last_change",
]

static var _CTRL_RE: RegEx = null
const REPEAT_EXEMPT_TOOLS := [
	"read_file",
	"list_directory",
	"search_text",
	"find_files",
	"find_symbol",
	"find_references",
	"check_script",
	"check_project",
	"launch_headless",
]

const PATH_DEFAULT_RES_TOOLS := [
	"check_project",
	"check_script",
	"search_text",
	"find_files",
	"find_symbol",
	"find_references",
	"list_directory",
]

const FILE_PATH_TOOLS := [
	"read_file",
	"edit_file",
	"edit_file_lines",
	"write_file",
	"create_file",
	"delete_file",
	"check_script",
]

const SYMBOL_LOOKUP_TOOLS := ["find_symbol", "find_references"]

# --- diagnostic-task priming ----------------------------------------------
const DIAGNOSTIC_KEYWORDS := ["error", "bug", "broken", "issue", "wrong"]

const DEFAULT_MAX_SYNTHETIC_RECOVERIES := 4

# Runaway protection when recovering tool calls from plain text (see
# _extract_recovered_calls). DeepSeek can legitimately want several tool
# calls in one reply (read, then check_script, say) — the tagged protocol
# supports that, and executing them together saves a browser round trip
# per call. This cap just stops a single reply from ever executing more
# than a handful of calls; it is independent of max_synthetic_recoveries,
# which is the per-TASK ceiling.
const MAX_RECOVERED_CALLS_PER_REPLY := 6

const AUTO_VERIFY_TOOL_NAME := "check_script"
const AUTO_VERIFY_TRIGGER_TOOLS := ["write_file", "create_file", "edit_file", "edit_file_lines"]
const DEFAULT_MAX_AUTO_VERIFY_PER_TASK := 8

const CHECK_FAILURE_TOOL_NAMES := ["check_script", "check_project", "launch_headless"]
const MAX_POST_ERROR_NUDGES := 2

# --- gave-up detection ----------------------------------------------------
const MAX_GAVE_UP_NUDGES := 2
const ACTION_VERB_PREFIXES := [
	"add", "remove", "delete", "fix", "change", "edit", "modify",
	"rename", "update", "create", "replace", "move", "write",
	"implement", "make",
]

const SYMBOL_GUESS_NUDGE_THRESHOLD := 3

# --- no-progress detection ------------------------------------------------
# If the model makes this many tool calls without a single successful
# read_file, inject a nudge. This is the "you cannot edit code you haven't
# read" rule. A model that plans, searches for symbols, lists files, or
# writes plans without ever opening a file is guessing — and small models
# will do exactly that for ten turns in a row if nothing stops them.
#
# The counter only resets on a successful read_file. Successful writes also
# count as "progress" in the sense that the task is advancing, so a write
# resets the counter too — but if the write was wrong because the model
# hadn't read, the syntax-hint and wrong-line mechanisms already cover that.
const NO_READ_CALL_THRESHOLD := 4

var _invalid_arg_tools: PackedStringArray = PackedStringArray()
var _file_not_found_paths: PackedStringArray = PackedStringArray()
var _pending_error_nudge: bool = false
var _post_error_nudges: int = 0

var _last_edit_path: String = ""
var _last_edit_start: int = 0
var _last_edit_end: int = 0

var _task_text: String = ""
var _wrote_something_this_task: bool = false
var _read_something_this_task: bool = false
var _gave_up_nudges: int = 0

var _symbol_guesses_since_read: int = 0
var _symbol_guess_nudged: bool = false

# Counts tool calls since the last successful read_file. Fires the
# no-progress nudge at NO_READ_CALL_THRESHOLD. Reset by any successful
# read_file or any successful write.
var _tool_calls_since_read: int = 0
var _no_read_nudge_fired: bool = false

var state := AgentState.new()
var conversation := Conversation.new()
var context_manager := ContextManager.new()
var tool_manager := ToolManager.new()

var llm_client: LLMClient
var max_iterations: int = 32
var auto_verify_writes: bool = true

# --- per-model-profile knobs -----------------------------------------------
# Set by MainWindow from AppSettings.resolved_profile() (a ModelProfile) at
# startup and whenever settings change. The defaults below are the safe
# fallback if that never happens — equivalent to a SMALL-tier profile, since
# an unconfigured harness should err toward too much hand-holding rather
# than a silently unassisted small model.
var max_tool_result_chars: int = DEFAULT_MAX_TOOL_RESULT_CHARS
var max_synthetic_recoveries: int = DEFAULT_MAX_SYNTHETIC_RECOVERIES
var max_auto_verify_per_task: int = DEFAULT_MAX_AUTO_VERIFY_PER_TASK
var enable_gave_up_escalation: bool = true
var enable_no_read_nudge: bool = true
var enable_symbol_guess_nudge: bool = true
var inject_diagnostic_priming: bool = true
# Optional free-form addition to the per-task priming, from ModelProfile.
# Injected as a system message once, at the start of a task, alongside the
# diagnostic hint. Empty by default (unused by any built-in tier).
var extra_system_hint: String = ""

# Token budget passed to ContextManager.build(). Set from
# ModelProfile.context_max_tokens — see that field's doc comment for why
# WEB_CHAT sets this far above the default (compaction forces a costly
# full resend through the bridge for no benefit, since DeepSeek's own
# thread never loses the history Godot's local copy compacts away).
var context_max_tokens: int = ContextManager.DEFAULT_MAX_TOKENS

# Web-chat-bridge mode: when true, and the model wrote more than one JSON
# object in a single reply, surface a one-time nudge explaining that only
# the first was executed. Gated by ModelProfile.inject_web_chat_protocol
# so a normal API tool-calling model never sees it.
var enable_web_chat_single_call_hint: bool = false

var _running := false
var _iterations := 0

var _empty_retries: int = 0
const MAX_EMPTY_RETRIES := 1

var _synthetic_recoveries: int = 0

var _auto_verify_count: int = 0
var _auto_verify_disabled: bool = false

var _call_history: Array = []
var _call_counter: int = 0
var _last_write_idx: int = -1
var _thrash_nudged: bool = false

func _ready() -> void:
	state.state_changed.connect(func(_p, c): state_changed.emit(c))
	tool_manager.approval_requested.connect(_on_approval_requested)
	tool_manager.approval_answered.connect(_on_approval_answered)

func is_busy() -> bool:
	return _running

func start(task: String) -> void:
	if _running:
		push_warning("AgentLoop already running")
		return
	if llm_client == null:
		push_error("AgentLoop.start: llm_client is not set")
		return
	_running = true
	_iterations = 0
	_empty_retries = 0
	_synthetic_recoveries = 0
	_auto_verify_count = 0
	_auto_verify_disabled = false
	_call_history.clear()
	_call_counter = 0
	_last_write_idx = -1
	_thrash_nudged = false
	_invalid_arg_tools.clear()
	_file_not_found_paths.clear()
	_pending_error_nudge = false
	_post_error_nudges = 0
	_last_edit_path = ""
	_last_edit_start = 0
	_last_edit_end = 0
	_task_text = task
	_wrote_something_this_task = false
	_read_something_this_task = false
	_gave_up_nudges = 0
	_symbol_guesses_since_read = 0
	_symbol_guess_nudged = false
	_tool_calls_since_read = 0
	_no_read_nudge_fired = false
	conversation.add_user(task)
	if inject_diagnostic_priming and _is_diagnostic_task(task):
		conversation.add_system(_diagnostic_hint())
	var hint := extra_system_hint.strip_edges()
	if hint != "":
		if not hint.begins_with("[system]"):
			hint = "[system] " + hint
		conversation.add_system(hint)
	_set_state(AgentState.State.THINKING)
	_step()

func stop() -> void:
	_running = false
	_set_state(AgentState.State.CANCELLED)

func _is_diagnostic_task(task: String) -> bool:
	var t := task.to_lower().strip_edges()
	if t == "" or t.length() > 160:
		return false
	var file_re := RegEx.new()
	file_re.compile("\\.(gd|tscn|tres|godot)\\b")
	if file_re.search(t) != null:
		return false
	for kw in DIAGNOSTIC_KEYWORDS:
		if t.find(kw) != -1:
			return true
	return false

func _diagnostic_hint() -> String:
	return (
		"[system] This looks like a general diagnostic task, and you have "
		+ "not yet inspected the project. Your FIRST action must be a tool "
		+ "call, not a text reply. Call check_project with {\"path\": \"res://\"} "
		+ "to find every parse/compile error in the project. Then read_file "
		+ "around each reported line and apply the fix. Do NOT ask the user "
		+ "which file contains the error or what the error message is — "
		+ "check_project answers both questions. Only ask for clarification "
		+ "if check_project reports zero errors but the user still believes "
		+ "something is broken."
	)

func _task_looks_actionable() -> bool:
	if _task_text == "":
		return false
	var t := _task_text.to_lower()
	for verb in ACTION_VERB_PREFIXES:
		var re := RegEx.new()
		re.compile("(?<![a-z])" + verb + "[a-z]*\\b")
		if re.search(t) != null:
			return true
	return false

func _step() -> void:
	if not _running:
		return
	_iterations += 1
	if _iterations > max_iterations:
		_fail(
			(
				"iteration ceiling reached (%d round trips). The task was "
				+ "still making progress — this is a task-length limit, not "
				+ "a failure of the work so far. Send another message and "
				+ "the agent will continue from its current state."
			) % max_iterations
		)
		return
	var messages := context_manager.build(conversation, context_max_tokens)
	var tools := tool_manager.all_schemas()
	_set_state(AgentState.State.THINKING)
	llm_client.send(messages, tools)

func _on_response(response: LLMResponse) -> void:
	if not _running:
		return
	if response == null:
		_fail("null response")
		return
	if response.text != "":
		assistant_text.emit(response.text)

	var has_text := response.text.strip_edges() != ""
	if not has_text and response.tool_calls.is_empty():
		if _empty_retries < MAX_EMPTY_RETRIES:
			_empty_retries += 1
			conversation.add_system(
				"[system] Your last turn was empty. You must either call a tool "
				+ "or give a final text answer. If a previous tool call failed, "
				+ "read the error message and retry with corrected arguments."
			)
			_step()
			return
		_running = false
		_set_state(AgentState.State.FAILED)
		finished.emit("failed: Model returned an empty response (finish_reason=%s)" % response.stop_reason)
		return

	_empty_retries = 0

	var effective_tool_calls: Array = response.tool_calls
	var recovered := false
	var recovered_discarded_count := 0
	if effective_tool_calls.is_empty() and has_text and _synthetic_recoveries < max_synthetic_recoveries:
		var found := _extract_recovered_calls(response.text)
		var usable: Array = []
		for f_v in found:
			var f: Dictionary = f_v
			if tool_manager.has(str(f.get("name", ""))):
				usable.append(f)
		if not usable.is_empty():
			# Batch execution: take as many as this reply's recovery budget
			# and the per-reply cap allow, in the order the model wrote
			# them. Anything beyond that is reported as discarded, not
			# silently dropped.
			var budget := mini(MAX_RECOVERED_CALLS_PER_REPLY, max_synthetic_recoveries - _synthetic_recoveries)
			recovered_discarded_count = maxi(0, usable.size() - budget)
			usable = usable.slice(0, budget)
			var calls: Array = []
			for f_v in usable:
				var f: Dictionary = f_v
				_synthetic_recoveries += 1
				var synthetic_id := "synthetic_%d_%d" % [_iterations, _synthetic_recoveries]
				var args_v: Variant = f.get("arguments", {})
				if typeof(args_v) != TYPE_DICTIONARY:
					args_v = {}
				calls.append({
					"id": synthetic_id,
					"type": "function",
					"function": {
						"name": str(f["name"]),
						"arguments": JSON.stringify(args_v),
					},
				})
			effective_tool_calls = calls
			recovered = true

	conversation.add_assistant(response.text, effective_tool_calls)

	if recovered:
		if enable_web_chat_single_call_hint:
			# Web-chat bridge: EVERY tool call arrives as recovered text —
			# there is no other "tool-calling mechanism" to fall back to,
			# so the generic "use the real mechanism" nudge below is false
			# on this tier.
			#
			# There is deliberately NO nudge for a prose prefix before the
			# first TOOL: line. _extract_tagged_calls anchors the TOOL:
			# regex to line start, not reply start, so a lead-in sentence
			# before the pair is harmless — and on this tier every system
			# message costs a full browser round trip. Spending one to
			# scold a cosmetic deviation the model's own training makes it
			# want to write, which caused no failure and which the protocol
			# section now explicitly permits, is worse than the deviation.
			#
			# The discarded-calls nudge below is kept: it fires only when
			# calls were actually lost, which is a real functional problem.
			if recovered_discarded_count > 0:
				var total := recovered_discarded_count + effective_tool_calls.size()
				conversation.add_system(
					(
						"[system] Your last reply requested %d tool call(s), but "
						+ "only %d ran this turn — the rest were discarded, not "
						+ "queued. Re-issue the remaining call(s) in a later reply "
						+ "once you have these results."
					) % [total, effective_tool_calls.size()]
				)
		else:
			# Non-web-chat tiers: a real tool-calling mechanism exists and
			# the model chose to describe the call in text instead of
			# using it — this nudge is accurate only in that case.
			conversation.add_system(
				"[system] Your previous reply described a tool call in plain "
				+ "text instead of actually issuing it, so it never ran. I "
				+ "detected the intent and executed it for you this time as "
				+ "a one-time recovery. Going forward you MUST issue tool "
				+ "calls through the tool-calling mechanism itself, not by "
				+ "writing JSON or describing the call in your text response "
				+ "— text alone is never executed."
			)

	# Recovery-budget-exhausted guard. Reaching here with no effective tool
	# calls AND the recovery budget used up AND the reply containing
	# recoverable tool-call syntax means the recovery block above was
	# skipped purely because _synthetic_recoveries >= max_synthetic_recoveries
	# — not because the model chose to write prose instead of a call. That
	# is a harness refusal, not a task completion. Fail loudly so the UI
	# shows FAILED rather than COMPLETED, and the user knows a fresh message
	# resets the budget.
	#
	# Gated on max_synthetic_recoveries > 0 so tiers that never use recovery
	# (STANDARD, POWERFUL) don't misfire on a model that wrongly writes JSON
	# in text — on those tiers the existing nudge path below is the correct
	# handling, not a hard failure.
	if not recovered \
			and effective_tool_calls.is_empty() \
			and has_text \
			and max_synthetic_recoveries > 0 \
			and _synthetic_recoveries >= max_synthetic_recoveries \
			and not _extract_recovered_calls(response.text).is_empty():
		_running = false
		_set_state(AgentState.State.FAILED)
		finished.emit(
			(
				"failed: tool-call recovery budget exhausted (%d recovered "
				+ "this task). Your last reply contained tool calls the "
				+ "harness could not accept — this is a harness limit, not "
				+ "a task completion. Send another message to reset the "
				+ "budget and continue where you left off."
			) % max_synthetic_recoveries
		)
		return

	if effective_tool_calls.is_empty():
		if _pending_error_nudge and _post_error_nudges < MAX_POST_ERROR_NUDGES:
			_post_error_nudges += 1
			_pending_error_nudge = false
			conversation.add_system(
				(
					"[system] The last check reported a real error in the project, "
					+ "but you responded with text only and no tool call. If the "
					+ "user's task is to fix errors, issue the fix NOW as an actual "
					+ "tool call — do not describe it in text, do not write Python "
					+ "or JSON snippets in prose. If the task was diagnosis-only, "
					+ "or you need more information before you can fix anything, "
					+ "say so explicitly and stop."
				)
			)
			_step()
			return

		if enable_gave_up_escalation \
				and not _wrote_something_this_task \
				and _task_looks_actionable() \
				and _gave_up_nudges < MAX_GAVE_UP_NUDGES:
			var stage := _gave_up_nudges + 1
			_gave_up_nudges += 1
			if stage == 1:
				conversation.add_system(
					"[system] You have not modified any files, but the task "
					+ "asked you to make a change. A text-only reply is not a "
					+ "completed task. Either issue the actual tool calls that "
					+ "make the change now, or explicitly tell the user you "
					+ "cannot complete the task and why. Do NOT describe the "
					+ "change in prose and call it done — the change must be "
					+ "applied with write_file, edit_file, or edit_file_lines."
				)
			else:
				conversation.add_system(_stage_two_give_up_hint())
			_step()
			return

		var outcome := _classify_completion(response.text)
		_running = false
		_set_state(outcome["state"])
		finished.emit(outcome["reason"])
		return

	_execute_tool_calls(effective_tool_calls)

func _stage_two_give_up_hint() -> String:
	var base := (
		"[system] You still haven't made any change, and you haven't read a "
		+ "single file. Guessing at names will not work — you are searching "
		+ "for a value (not a symbol), or for code whose name you don't know. "
		+ "Stop guessing. Do this in order:\n"
		+ "  1. read_file one of the files listed below (pick the one whose "
		+ "name is closest to the user's task).\n"
		+ "  2. Read the whole file (or the relevant range) before making any "
		+ "change.\n"
		+ "  3. Then edit the exact lines you need to edit.\n"
	)
	var listing := context_manager.project_files_summary
	if listing.strip_edges() != "":
		base += "\nFiles available to read:\n" + listing + "\n"
	base += (
		"\n`find_symbol` only matches IDENTIFIERS (function/variable/class "
		+ "names). It cannot find numeric values like `60`, string literals, "
		+ "or comments. If your query isn't an identifier, use `read_file` "
		+ "or `search_text` instead."
	)
	return base

# Decides what a turn that ended with no tool calls and no further nudge
# actually represents, instead of always reporting COMPLETED (see
# AgentState.State's BLOCKED/GAVE_UP doc comment and handoff_file §5.1 —
# "the UI must not show COMPLETED" when the model gave up without fixing).
#
# Both checks below rely only on state the harness already tracks or a
# plain textual fact about the reply — no keyword-guessing at intent,
# consistent with rule #12 (hints derive from structured data, never a
# wrong guess dressed up as a fact).
func _classify_completion(final_text: String) -> Dictionary:
	# GAVE_UP: reaching this point at all already means the gave-up
	# escalation branch above did NOT fire this turn — which happens when
	# either it's disabled, the task didn't look actionable, something was
	# already written, OR (the case that matters here) its nudge budget is
	# exhausted. That last case is a genuine abandoned task: the harness
	# already told the model twice that it hadn't made the requested
	# change, and it still stopped without doing so.
	if enable_gave_up_escalation \
			and _task_looks_actionable() \
			and not _wrote_something_this_task \
			and _gave_up_nudges >= MAX_GAVE_UP_NUDGES:
		return {
			"state": AgentState.State.GAVE_UP,
			"reason": (
				"gave_up: model stopped without making the requested change, "
				+ "after %d escalation nudge(s)"
			) % _gave_up_nudges,
		}

	# BLOCKED: the model's final reply reads as a question. Deliberately
	# just "ends with a question mark" — a keyword list trying to guess
	# intent would be exactly the kind of unstructured guess rule #12
	# warns against. False negatives (a genuine question that doesn't end
	# in "?") just fall through to COMPLETED, same as before this feature
	# existed — no regression, only a strict improvement on the clear cases.
	if _final_text_is_a_question(final_text):
		return {
			"state": AgentState.State.BLOCKED,
			"reason": "blocked: model is waiting on information from the user",
		}

	return {"state": AgentState.State.COMPLETED, "reason": "completed"}

static func _final_text_is_a_question(text: String) -> bool:
	var t := text.strip_edges()
	return t != "" and t.ends_with("?")

func _on_request_failed(message: String) -> void:
	if not _running:
		return
	_fail(message)

func _on_approval_requested(_tool_name: String, _args: Dictionary, _perm: String) -> void:
	_set_state(AgentState.State.WAITING_FOR_APPROVAL)

func _on_approval_answered(_approved: bool) -> void:
	if _running:
		_set_state(AgentState.State.EXECUTING_TOOL)

func _execute_tool_calls(calls: Array) -> void:
	_set_state(AgentState.State.EXECUTING_TOOL)
	var paths_to_verify: Dictionary = {}
	_invalid_arg_tools.clear()
	_file_not_found_paths.clear()

	for call_v in calls:
		if typeof(call_v) != TYPE_DICTIONARY:
			continue
		var call: Dictionary = call_v
		var call_id: String = str(call.get("id", ""))

		var fn_v: Variant = call.get("function", {})
		if typeof(fn_v) != TYPE_DICTIONARY:
			continue
		var fn: Dictionary = fn_v
		var tool_name: String = str(fn.get("name", ""))
		var args_str: String = str(fn.get("arguments", "{}"))
		var args_v: Variant = JSON.parse_string(args_str)
		var arguments: Dictionary = args_v if typeof(args_v) == TYPE_DICTIONARY else {}

		if tool_name in PATH_DEFAULT_RES_TOOLS:
			var p := str(arguments.get("path", "")).strip_edges()
			if p == "":
				arguments["path"] = "res://"

		var sig := "%s|%s" % [tool_name, JSON.stringify(arguments)]
		var path_arg := str(arguments.get("path", ""))

		if _is_repeated_call(sig, tool_name):
			tool_started.emit(tool_name, arguments)
			var dup_msg := _repeated_call_message(tool_name)
			var dup_result := ToolResult.repeated_call(dup_msg)
			tool_finished.emit(tool_name, dup_result)
			if _running:
				_set_state(AgentState.State.EXECUTING_TOOL)
			conversation.add_tool(_truncate_tool_result(dup_result.describe()), call_id, tool_name)
			_record_call(sig, tool_name, path_arg)
			_tool_calls_since_read += 1
			continue

		tool_started.emit(tool_name, arguments)
		var result: ToolResult = await tool_manager.execute(tool_name, arguments)
		if result == null:
			result = ToolResult.failure("Tool produced no result: %s" % tool_name)
		tool_finished.emit(tool_name, result)

		if _running:
			_set_state(AgentState.State.EXECUTING_TOOL)

		if tool_name in CHECK_FAILURE_TOOL_NAMES:
			if result.success:
				_pending_error_nudge = false
			else:
				_pending_error_nudge = true

		# Read tracking: a successful read_file flips the task-wide flag,
		# resets the symbol-guess counter, AND resets the no-progress counter.
		# This is the one tool call that counts as "the model has seen what
		# it's editing."
		if result.success and tool_name == "read_file":
			_read_something_this_task = true
			_symbol_guesses_since_read = 0
			_tool_calls_since_read = 0
		else:
			_tool_calls_since_read += 1

		if tool_name in SYMBOL_LOOKUP_TOOLS:
			_symbol_guesses_since_read += 1

		if result.success and tool_name == "revert_last_change":
			_call_history.clear()
			# Revert counts as progress — the project state changed.
			_tool_calls_since_read = 0
		elif result.success and path_arg != "" and tool_name in WRITE_TOOL_NAMES:
			_invalidate_path(path_arg)
			_pending_error_nudge = false
			_wrote_something_this_task = true
			# A write also counts as progress; reset the counter. (If the
			# write was wrong because the model hadn't read, the auto-verify
			# check_script and wrong-line note will catch that downstream.)
			_tool_calls_since_read = 0
			_last_edit_path = path_arg
			if tool_name == "edit_file_lines":
				_last_edit_start = int(arguments.get("start_line", 0))
				_last_edit_end = int(arguments.get("end_line", arguments.get("start_line", 0)))
			else:
				_last_edit_start = 0
				_last_edit_end = 0
			if tool_name in AUTO_VERIFY_TRIGGER_TOOLS:
				paths_to_verify[path_arg] = true
		elif not result.success and result.error_kind == ToolResult.ErrorKind.INVALID_ARGUMENT:
			if not (tool_name in _invalid_arg_tools):
				_invalid_arg_tools.append(tool_name)
		elif not result.success \
				and result.error_kind == ToolResult.ErrorKind.NOT_FOUND \
				and tool_name in FILE_PATH_TOOLS \
				and path_arg != "":
			if not (path_arg in _file_not_found_paths):
				_file_not_found_paths.append(path_arg)

		var payload := _truncate_tool_result(result.describe())
		conversation.add_tool(payload, call_id, tool_name)
		_record_call(sig, tool_name, path_arg)

	for path_arg in paths_to_verify.keys():
		await _maybe_auto_verify(str(path_arg))

	if not _invalid_arg_tools.is_empty():
		conversation.add_system(
			(
				"[system] Tool call(s) rejected for invalid arguments: %s. "
				+ "You must retry with corrected arguments using the actual "
				+ "tool-calling mechanism. Do NOT describe the retry in plain "
				+ "text, and do NOT treat the rejection as a final answer — "
				+ "text alone is never executed. Re-read the tool's argument "
				+ "schema if you're unsure what's required."
			) % ", ".join(_invalid_arg_tools)
		)

	if not _file_not_found_paths.is_empty():
		conversation.add_system(_file_not_found_message())

	# No-progress nudge. Fires when the model has made several tool calls
	# without a single successful read_file this task. Every small model we
	# have tested will, without this, plan/search/list for many turns and
	# then try to write code it has never seen. This says plainly: you can't
	# edit what you haven't read.
	if enable_no_read_nudge \
			and not _no_read_nudge_fired \
			and _tool_calls_since_read >= NO_READ_CALL_THRESHOLD \
			and not _read_something_this_task:
		_no_read_nudge_fired = true
		conversation.add_system(_no_read_hint())

	# Symbol-guess nudge. Fires once per task when the model has made
	# several identifier-lookup calls without reading anything. Names the
	# specific failing case (identifier vs literal) and directs it to
	# read_file.
	if enable_symbol_guess_nudge \
			and not _symbol_guess_nudged \
			and not _read_something_this_task \
			and _symbol_guesses_since_read >= SYMBOL_GUESS_NUDGE_THRESHOLD:
		_symbol_guess_nudged = true
		conversation.add_system(
			"[system] You have made %d symbol-lookup calls without reading "
			% _symbol_guesses_since_read
			+ "any file, and none of them have found what you're looking for. "
			+ "`find_symbol` and `find_references` only match IDENTIFIERS "
			+ "(function, variable, class, signal names). They cannot find "
			+ "numeric values (like `60`), string literals, or comments. "
			+ "Before continuing, `read_file` the file most likely to contain "
			+ "what the task is about — or `search_text` for a substring "
			+ "likely to appear near it."
		)

	_check_thrash()
	_step()

# The no-read nudge. Directive and specific: names the rule, points at the
# file list, forbids continuing until a file has been read.
func _no_read_hint() -> String:
	var base := (
		"[system] You have made %d tool calls without opening a single "
		% _tool_calls_since_read
		+ "file. You cannot make changes to code you have not read — and you "
		+ "have not read any. Stop planning and searching. Do this next:\n"
		+ "  1. Choose the file from the list below whose name is closest "
		+ "to the user's request. If you're unsure, `search_text` for a "
		+ "specific word from the request (not a symbol — a word that would "
		+ "appear in the code, like \"timer\" or \"minutes\").\n"
		+ "  2. `read_file` that file.\n"
		+ "  3. Only then decide what to edit, and edit it with "
		+ "`edit_file`/`edit_file_lines`."
	)
	var listing := context_manager.project_files_summary
	if listing.strip_edges() != "":
		base += "\n\nProject files you can read:\n" + listing
	return base

func _file_not_found_message() -> String:
	var guessed := ", ".join(_file_not_found_paths)
	var listing := context_manager.project_files_summary
	if listing.strip_edges() == "":
		return (
			"[system] These paths do not exist: %s. Do NOT guess paths. Use "
			+ "`find_files` or `list_directory` to discover what actually "
			+ "exists before retrying."
		) % guessed
	return (
		"[system] These paths do not exist: %s.\n"
		+ "Do NOT guess paths. Pick from the list below, which is the "
		+ "complete set of source files in this project:\n\n%s\n\n"
		+ "If none of them is the right file for this task, use "
		+ "`search_text` to find a substring the target file likely "
		+ "contains, or `list_directory` to inspect a folder."
	) % [guessed, listing]

func _repeated_call_message(tool_name: String) -> String:
	if tool_name in REPEAT_EXEMPT_TOOLS:
		return (
			"You already called '%s' with these exact arguments, and nothing "
			+ "has been written since — the result is identical to the one "
			+ "already in your conversation history above. Do not repeat this "
			+ "call. Use the earlier result, change the arguments, or move on "
			+ "to a different tool."
		) % tool_name
	return (
		"You already called '%s' with these exact arguments recently — the "
		+ "result is already in your conversation history above. Do not repeat "
		+ "this call; use the earlier result, change the arguments, or move on."
	) % tool_name

func _truncate_tool_result(text: String) -> String:
	# Strip ANSI/VT100 sequences before anything else — raw ESC (0x1B)
	# bytes in a tool result crash the web bridge's strict JSON parser,
	# and they're visual noise the model doesn't need regardless. This is
	# the single choke point every tool result passes through, so one
	# strip here covers all sources.
	text = ErrorParser.strip_ansi(text)
	text = _strip_control_chars(text)
	if text.find("\uFFFD") != -1:
		var cleaned := text.replace("\uFFFD", "?")
		cleaned += (
			"\n[note: file contains invalid UTF-8 bytes — those were replaced "
			+ "with '?'. The file may need to be re-saved as UTF-8.]"
		)
		text = cleaned

	if text.length() <= max_tool_result_chars:
		return text
	var head := text.substr(0, max_tool_result_chars)
	var dropped := text.length() - max_tool_result_chars
	return head + "\n…[truncated %d chars — use a narrower query if you need more]" % dropped

func _maybe_auto_verify(path_arg: String) -> void:
	if not auto_verify_writes or _auto_verify_disabled:
		return
	if not path_arg.to_lower().ends_with(".gd"):
		return
	if not tool_manager.has(AUTO_VERIFY_TOOL_NAME):
		return
	if _auto_verify_count >= max_auto_verify_per_task:
		return
	_auto_verify_count += 1

	var args := {"path": path_arg}
	tool_started.emit(AUTO_VERIFY_TOOL_NAME, args)
	var result: ToolResult = await tool_manager.execute(AUTO_VERIFY_TOOL_NAME, args)
	if result == null:
		result = ToolResult.failure("Tool produced no result: %s" % AUTO_VERIFY_TOOL_NAME)
	tool_finished.emit(AUTO_VERIFY_TOOL_NAME, result)
	if _running:
		_set_state(AgentState.State.EXECUTING_TOOL)

	if not result.success and result.error_kind == ToolResult.ErrorKind.INVALID_ARGUMENT:
		_auto_verify_disabled = true

	if not result.success:
		_pending_error_nudge = true

	var sig := "%s|%s" % [AUTO_VERIFY_TOOL_NAME, JSON.stringify(args)]
	_record_call(sig, AUTO_VERIFY_TOOL_NAME, path_arg)

	var message := (
		"[auto-verify] check_script on %s (ran automatically after your edit):\n%s"
		% [path_arg, _truncate_tool_result(result.describe())]
	)
	var extra := _wrong_line_note(path_arg, result)
	if extra != "":
		message += "\n" + extra

	conversation.add_system(message)

	if _auto_verify_count == max_auto_verify_per_task:
		conversation.add_system(
			(
				"[system] Automatic post-edit verification has run %d times this task "
				+ "and will not run again automatically. Call check_script/check_project "
				+ "yourself if you need further verification."
			) % max_auto_verify_per_task
		)

func _wrong_line_note(path_arg: String, result: ToolResult) -> String:
	if result.success:
		return ""
	if _last_edit_path != path_arg:
		return ""
	if _last_edit_start <= 0 or _last_edit_end <= 0:
		return ""
	var events_v: Variant = result.metadata.get("events", [])
	if typeof(events_v) != TYPE_ARRAY:
		return ""
	var events: Array = events_v
	if events.is_empty():
		return ""
	var first_v: Variant = events[0]
	if typeof(first_v) != TYPE_DICTIONARY:
		return ""
	var err_line := int((first_v as Dictionary).get("line", 0))
	if err_line <= 0:
		return ""
	if err_line >= _last_edit_start and err_line <= _last_edit_end:
		return ""
	return (
		"[!] NOTE: you edited line(s) %d-%d, but the remaining error is at "
		+ "line %d — OUTSIDE the range you just changed. The lines you edited "
		+ "are not the problem. Re-read the lines around %d and edit line %d "
		+ "specifically."
	) % [_last_edit_start, _last_edit_end, err_line, err_line, err_line]

# Extracts every recoverable tool call from a plain-text reply, in the
# order they appear. Tries the tagged TOOL:/ARGS: protocol first (see
# MainWindow.SYSTEM_PROMPT_WEB_CHAT_PROTOCOL and §6.1 of the bridge
# handoff) since that's what a web-chat-tier model is instructed to write;
# falls back to the legacy bare-JSON shapes for models/tiers still using
# the older `{"name": ..., "arguments": {...}}` convention. Each returned
# Dictionary has "name", "arguments", and "start" (character offset of the
# call's first token in `text`, used only to decide whether there was a
# prose prefix — see _on_response).
static func _extract_recovered_calls(text: String) -> Array:
	if text.strip_edges() == "":
		return []
	var tagged := _extract_tagged_calls(text)
	if not tagged.is_empty():
		return tagged
	return _extract_legacy_json_calls(text)

# Parses one or more `TOOL: <name>` / `ARGS: {...}` pairs. Pairs may repeat
# back-to-back for batched calls; anything between a matched ARGS object
# and the next TOOL: line (there shouldn't be anything) is ignored rather
# than rejecting the whole reply, since a model that's 95% compliant is
# still worth recovering.
static func _extract_tagged_calls(text: String) -> Array:
	var out: Array = []
	var tool_re := RegEx.new()
	tool_re.compile("(?m)^[ \\t]*TOOL:[ \\t]*([A-Za-z_][A-Za-z0-9_]*)[ \\t]*$")
	var args_re := RegEx.new()
	args_re.compile("(?m)^[ \\t]*ARGS:[ \\t]*")
	var search_from := 0
	while true:
		var tm := tool_re.search(text, search_from)
		if tm == null:
			break
		var tool_name := tm.get_string(1)
		var am := args_re.search(text, tm.get_end())
		if am == null:
			break
		var brace_start := text.find("{", am.get_end())
		if brace_start < 0:
			break
		var brace_end := _find_matching_brace(text, brace_start)
		if brace_end < 0:
			break
		var parsed: Variant = JSON.parse_string(text.substr(brace_start, brace_end - brace_start + 1))
		out.append({
			"name": tool_name,
			"arguments": parsed if typeof(parsed) == TYPE_DICTIONARY else {},
			"start": tm.get_start(),
		})
		search_from = brace_end + 1
	return out

# Legacy recovery path, kept for backward compatibility with the older
# bare-JSON protocol (and as a safety net if a web-chat-tier model reverts
# to writing plain `{"name": ...}` on its own). Scans for every balanced
# JSON object in the text rather than stopping at the first, so a model
# that writes several bare-JSON calls in one reply still gets batched.
static func _extract_legacy_json_calls(text: String) -> Array:
	var out: Array = []
	for candidate in _find_json_objects(text):
		var parsed: Variant = JSON.parse_string(candidate)
		if typeof(parsed) != TYPE_DICTIONARY:
			continue
		var d: Dictionary = parsed
		var tool_name := ""
		var args: Dictionary = {}
		if d.has("function") and typeof(d["function"]) == TYPE_DICTIONARY:
			var fn: Dictionary = d["function"]
			tool_name = str(fn.get("name", ""))
			args = _coerce_args(fn.get("arguments", fn.get("parameters", {})))
		elif d.has("name"):
			tool_name = str(d["name"])
			args = _coerce_args(d.get("arguments", d.get("parameters", {})))
		elif d.has("tool"):
			tool_name = str(d["tool"])
			args = _coerce_args(d.get("arguments", d.get("parameters", {})))
		if tool_name == "":
			continue
		out.append({"name": tool_name, "arguments": args, "start": text.find(candidate)})
	if not out.is_empty():
		return out

	# Last resort: DeepSeek's web frontend (or its SSE stream) sometimes
	# drops the leading `{"name": ` prefix from a tool call the model
	# wrote, leaving only the shape
	#     "tool_name", "arguments": { ... }}
	# Recover the single call from that truncated shape.
	var truncated := _recover_truncated_tool_call(text)
	if truncated.is_empty():
		return []
	truncated["start"] = 0
	return [truncated]

# Finds the index of the `}` that closes the `{` at `brace_start`.
# Returns -1 if the braces never balance.
static func _find_matching_brace(text: String, brace_start: int) -> int:
	var depth := 0
	for i in range(brace_start, text.length()):
		var ch := text[i]
		if ch == "{":
			depth += 1
		elif ch == "}":
			depth -= 1
			if depth == 0:
				return i
	return -1

# Handles the "prefix dropped mid-stream" malformation observed when
# DeepSeek Web emits a tool call after writing prose. Finds a
# `"<identifier>", "arguments":` sequence and takes the identifier as the
# tool name plus the first balanced {...} after it as the argument object.
# The caller checks the recovered name against the registered tool set, so
# a coincidental identifier in prose is very unlikely to be misread as a
# call — it would have to exactly match a real tool name AND be followed
# by `, "arguments": {`.
static func _recover_truncated_tool_call(text: String) -> Dictionary:
	var needle := '"arguments":'
	var idx := text.rfind(needle)
	if idx < 0:
		return {}
	var head := text.substr(0, idx).rstrip(" \t\r\n")
	if not head.ends_with(","):
		return {}
	head = head.substr(0, head.length() - 1).rstrip(" \t\r\n")
	if not head.ends_with('"'):
		return {}
	head = head.substr(0, head.length() - 1)
	var name_open := head.rfind('"')
	if name_open < 0:
		return {}
	var tool_name := head.substr(name_open + 1)
	if tool_name == "" or not tool_name.is_valid_identifier():
		return {}
	var brace_start := text.find("{", idx)
	if brace_start < 0:
		return {}
	var depth := 0
	var brace_end := -1
	for i in range(brace_start, text.length()):
		var ch := text[i]
		if ch == "{":
			depth += 1
		elif ch == "}":
			depth -= 1
			if depth == 0:
				brace_end = i
				break
	if brace_end < 0:
		return {}
	var args_json := text.substr(brace_start, brace_end - brace_start + 1)
	var parsed: Variant = JSON.parse_string(args_json)
	if typeof(parsed) != TYPE_DICTIONARY:
		return {}
	return {"name": tool_name, "arguments": parsed}

static func _coerce_args(args_v: Variant) -> Dictionary:
	if typeof(args_v) == TYPE_DICTIONARY:
		return args_v
	if typeof(args_v) == TYPE_STRING:
		var parsed: Variant = JSON.parse_string(str(args_v))
		if typeof(parsed) == TYPE_DICTIONARY:
			return parsed
	return {}

static func _find_json_objects(text: String) -> Array:
	var out: Array = []
	var depth := 0
	var start := -1
	for i in range(text.length()):
		var ch := text[i]
		if ch == "{":
			if depth == 0:
				start = i
			depth += 1
		elif ch == "}":
			if depth > 0:
				depth -= 1
				if depth == 0 and start != -1:
					out.append(text.substr(start, i - start + 1))
					start = -1
	return out

func _is_repeated_call(sig: String, tool_name: String) -> bool:
	var window_start := maxi(0, _call_history.size() - REPEATED_CALL_WINDOW)
	var matched_idx := -1
	for i in range(window_start, _call_history.size()):
		var entry: Dictionary = _call_history[i]
		if str(entry.get("sig", "")) == sig:
			matched_idx = int(entry.get("idx", -1))
			break
	if matched_idx < 0:
		return false
	if tool_name in WRITE_TOOL_NAMES:
		return true
	if tool_name in REPEAT_EXEMPT_TOOLS:
		return _last_write_idx < matched_idx
	return true

func _record_call(sig: String, tool_name: String, path_arg: String) -> void:
	_call_counter += 1
	if tool_name in STATE_CHANGE_TOOL_NAMES:
		_last_write_idx = _call_counter
	_call_history.append({
		"sig": sig,
		"tool_name": tool_name,
		"path": path_arg,
		"idx": _call_counter,
	})
	var cap := REPEATED_CALL_WINDOW + THRASH_WINDOW
	var overflow := _call_history.size() - cap
	if overflow > 0:
		_call_history = _call_history.slice(overflow)

func _invalidate_path(path_arg: String) -> void:
	if path_arg == "":
		return
	var kept: Array = []
	for entry in _call_history:
		if str((entry as Dictionary).get("path", "")) != path_arg:
			kept.append(entry)
	_call_history = kept

func _check_thrash() -> void:
	if _call_history.size() < THRASH_WINDOW:
		return
	var window: Array = _call_history.slice(_call_history.size() - THRASH_WINDOW)
	var first_name := str((window[0] as Dictionary).get("tool_name", ""))
	if first_name == "" or first_name in STATE_CHANGE_TOOL_NAMES:
		_thrash_nudged = false
		return
	var all_same := true
	for entry in window:
		if str((entry as Dictionary).get("tool_name", "")) != first_name:
			all_same = false
			break
	if not all_same:
		_thrash_nudged = false
		return
	if _thrash_nudged:
		return
	_thrash_nudged = true
	var msg := (
		"[system] You have called '%s' %d times in a row without writing any "
		+ "files. You appear to be looping. Stop, summarize what you have "
		+ "learned so far, and either make a concrete change or ask the user "
		+ "for clarification."
	) % [first_name, THRASH_WINDOW]
	conversation.add_system(msg)

func _fail(message: String) -> void:
	_running = false
	_set_state(AgentState.State.FAILED)
	push_error("AgentLoop failed: " + message)
	finished.emit("failed: " + message)

func _set_state(s: AgentState.State) -> void:
	state.current = s



# Strips any remaining C0 control characters except tab and newline. Even
# after ANSI stripping, a binary file read or odd subprocess output can
# leave these in a string, and any of them breaks the JSON body on the
# way to the model.
static func _strip_control_chars(text: String) -> String:
	if _CTRL_RE == null:
		_CTRL_RE = RegEx.new()
		_CTRL_RE.compile("[\\x00-\\x08\\x0B-\\x0C\\x0E-\\x1F\\x7F]")
	return _CTRL_RE.sub(text, " ", true)
