class_name MainWindow
extends Control

# --- project instructions (AGENT.md) --------------------------------------
# Loaded at project-open time and injected into ContextManager as its own
# system message on every ContextManager.build() call. No tool is required —
# the model can re-read the raw file at any time with read_file("res://AGENT.md").
const PROJECT_INSTRUCTIONS_FILE := "AGENT.md"
const MAX_PROJECT_INSTRUCTIONS_CHARS := 16_000

# Tools that exist but aren't always useful enough to justify their schema
# cost on every API call (see SettingsDialog's Tools section). Instances are
# created once in _setup_agent() and registered/unregistered against
# ToolManager by _apply_tool_registration() based on AppSettings.disabled_tools —
# never recreated, so re-enabling one mid-session picks up right where it
# left off.
#
# The scene tools (inspect_scene/find_node/get_node_property/find_scene_users),
# run_scenario, and the analysis tools (list_autoloads/find_rpc_calls/
# find_signal_wiring) are optional for the same reason launch_editor/
# write_plan are: every registered tool's schema is a fixed cost paid on
# every single API call (rule #16 in handoff_file — token budget is a
# first-class design constraint), and not every task touches scenes, needs
# runtime verification, or needs multiplayer/signal analysis. See
# handoff_file §5.2/§5.3 and the roadmap's §5.1 for what each does.
const OPTIONAL_TOOL_NAMES := [
	"launch_editor", "launch_project", "write_plan", "update_plan",
	"inspect_scene", "find_node", "get_node_property", "find_scene_users",
	"run_scenario",
	"list_autoloads", "find_rpc_calls", "find_signal_wiring",
	"godot_api_lookup",
]

# --- system prompt, split into pieces gated by tier / tool availability ---
# See _rebuild_system_prompt(). SYSTEM_PROMPT_BASE/_TAIL are always
# included; SYSTEM_PROMPT_ACT_DONT_ASK and SYSTEM_PROMPT_SYNTAX_CHEATSHEET
# are small-model accommodations gated by the resolved ModelProfile;
# SYSTEM_PROMPT_PLAN_TOOLS/SYSTEM_PROMPT_SCENE_TOOLS/SYSTEM_PROMPT_RUN_SCENARIO/
# SYSTEM_PROMPT_ANALYSIS_TOOLS are each gated by whether their tool(s) are
# currently registered — telling the model to call a tool that doesn't exist
# would just produce a failed tool call.
const SYSTEM_PROMPT_INTRO := "You are a Godot 4 coding agent.\n"

const SYSTEM_PROMPT_ACT_DONT_ASK := (
	"You are expected to ACT, not just discuss. When the user asks you to do "
	+ "something — fix, find, check, refactor, add — your first move is "
	+ "almost always a tool call, not a clarification question. Before asking "
	+ "the user for information, check whether a tool can answer it yourself: "
	+ "check_project and check_script find errors, find_files and find_symbol "
	+ "locate code, search_text finds substrings, read_file reads content, "
	+ "list_directory lists folders. Only ask the user for information the "
	+ "tools genuinely cannot obtain.\n"
)

const SYSTEM_PROMPT_SYNTAX_CHEATSHEET := (
	"GDScript syntax (Godot 4) — most parse errors come from getting these wrong:\n"
	+ "- Comments start with `#`, never `//`. `//` is integer division, not a comment.\n"
	+ "- Indentation: use TABs. Method bodies are indented; class-level `var`, `const`, `func`, `signal`, `enum`, `class_name`, and `extends` all start at column 0 — never indent them.\n"
	+ "- Functions: `func name(args) -> ReturnType:`. Not `def`, not `function`, no `void` keyword.\n"
	+ "- Inheritance: `extends Node2D` on its own line, not `class X extends Y`.\n"
	+ "- Booleans `true`/`false` and `null` — all lowercase.\n"
	+ "- `@onready var x := $Node` for node references; `@export var x: int = 0` for editor-visible fields.\n"
	+ "- Signals: `button.pressed.connect(_on_pressed)`. Not `connect(\"pressed\", self, \"_on_pressed\")` — that's Godot 3.\n"
)

# Web-chat bridge protocol. Gated by ModelProfile.inject_web_chat_protocol.
# This is the section that actually makes a large model behave like an
# API client despite having no native function-calling: it defines the
# tagged TOOL:/ARGS: call format (AgentLoop._extract_tagged_calls parses
# it), explains that several calls can be batched in one reply — up to
# AgentLoop.MAX_RECOVERED_CALLS_PER_REPLY are actually executed; beyond
# that the harness tells the model which were discarded so it can re-issue
# them, rather than the model waiting forever on a result that never
# comes — and permits a short lead-in sentence before the pair, which the
# parser tolerates and which the model's training makes it want to write.
# A tagged line is far less natural for the model to write as incidental
# prose than a JSON object is, which is why this replaced the original
# bare-`{...}` protocol — see §6.1 of the bridge handoff doc.
#
# The read_files bullet below is the productivity feature this round: on
# this tier every tool call is a full browser round trip, so a model that
# already knows it needs several files should ask for all of them in one
# read_files call instead of one read_file call per file, per reply.
const SYSTEM_PROMPT_WEB_CHAT_PROTOCOL := (
	"TOOL-CALL PROTOCOL — you are accessed through a web-chat bridge that "
	+ "has NO native function-calling. To call a tool, write these two "
	+ "lines:\n"
	+ "    TOOL: tool_name\n"
	+ "    ARGS: {\"key\": \"value\"}\n"
	+ "The parser looks for a `TOOL:` line followed by an `ARGS:` line "
	+ "carrying one JSON object. A short lead-in sentence before the "
	+ "pair is harmless; what matters is that both lines are present, "
	+ "each on its own line, whenever you intend to call a tool.\n"
	+ "- You MAY call several tools in one reply: write another "
	+ "TOOL:/ARGS: pair after the previous one's closing `}`. They run "
	+ "in the order written and you get every result back together in "
	+ "your next turn.\n"
	+ "- Every tool call here costs a real round trip (a browser wait, "
	+ "not an instant API response). If you already know you need "
	+ "several files — a script and the scene/autoload it references, "
	+ "for example — call `read_files` once with all of their paths "
	+ "instead of issuing a separate `read_file` call for each one.\n"
	+ "- Write the pairs as plain text, not wrapped in code fences or "
	+ "XML-style tags — those are easy for the parser to misread.\n"
	+ "- When you do NOT need a tool — because you are done, or because "
	+ "you need to ask the user something — reply in plain prose with NO "
	+ "TOOL:/ARGS: pair anywhere in that reply.\n"
	+ "- Never describe a tool call in prose and stop. If you say you are "
	+ "going to read a file, include the TOOL:/ARGS: pair for read_file "
	+ "(or read_files) in the same reply.\n"
)

const SYSTEM_PROMPT_BASE := (
	"Use tools to inspect and modify files inside the selected project. "
	+ "Prefer small, verifiable changes. Use res:// paths for all file arguments. "
	+ "If you already know you'll need several files, call read_files with all "
	+ "of their paths in one call instead of several separate read_file calls — "
	+ "it returns every result together and saves a round trip per file. "
	+ "You must issue tool calls through the actual tool-calling mechanism "
	+ "only. Never write out a tool call as JSON text, and never say things "
	+ "like 'Executing this now...' without a real tool call attached in the "
	+ "same turn — text descriptions of a tool call are not executed. "
	+ "For text edits, use edit_file when you are certain of the exact "
	+ "existing text; use edit_file_lines instead when you only have a line "
	+ "number (e.g. from a check_script error) or aren't fully sure of the "
	+ "exact current text — it edits by line number and never fails on a "
	+ "whitespace/formatting mismatch. "
	+ "After you successfully write/create/edit a .gd file, check_script runs "
	+ "on it automatically and its result is reported to you as a system "
	+ "message — you don't need to call check_script yourself right after an "
	+ "edit, but still run check_project after a larger batch of changes, or "
	+ "when a scene outside the boot path might be affected. "
	+ "check_script/check_project errors name a file and line number — when they do, "
	+ "call read_file with start_line/end_line around that line instead of reading the "
	+ "whole file; large files return only a line count until you specify a range. "
	+ "After making changes, verify them with launch_headless when it makes sense. "
	+ "launch_headless only parses scripts reachable from the project's boot "
	+ "scene — a script attached only to a scene reached by a button press or "
	+ "other runtime navigation will NOT be caught by it. After a batch of "
	+ "edits, or if you're unsure a scene outside the boot path is affected, "
	+ "run check_project to syntax-check every .gd file directly. "
	+ "If a change turns out to be wrong, use revert_last_change to undo it "
	+ "rather than trying to manually reconstruct the previous content. "
)

# Conditional on write_plan/update_plan being registered — see
# _rebuild_system_prompt().
const SYSTEM_PROMPT_PLAN_TOOLS := (
	"For multi-step tasks, call write_plan once you have a concrete plan, "
	+ "and update_plan to mark steps in_progress/done/blocked as you go. "
)

# Conditional on inspect_scene being registered (the four scene tools are
# enabled/disabled together — see SettingsDialog). handoff_file §5.2.
const SYSTEM_PROMPT_SCENE_TOOLS := (
	"Scene files (.tscn) are structured data, not something to read as raw text "
	+ "when you just need the tree: use inspect_scene for a node-tree overview, "
	+ "find_node to locate a node by name/type substring, get_node_property to "
	+ "check one property's value without re-reading the whole file, and "
	+ "find_scene_users before renaming, moving, or deleting a scene to see "
	+ "what instances or preloads it. "
)

# Conditional on run_scenario being registered. handoff_file §5.3 — the
# harness's only tool that lets the model OBSERVE behavior instead of only
# reasoning about source. Kept deliberately short: the tool's own
# description carries the real instructions on the `setup` argument.
const SYSTEM_PROMPT_RUN_SCENARIO := (
	"When you need to verify runtime behavior that reading code cannot confirm "
	+ "— movement, damage, signals, save/load, AI decisions — use run_scenario "
	+ "to drive the real project headlessly and get a PASS/FAIL verdict, rather "
	+ "than asking the user to test it manually. After a fix, re-run the same "
	+ "scenario name with no `setup` argument to confirm it now passes. "
)

# Conditional on list_autoloads being registered (the three analysis tools
# are enabled/disabled together — see SettingsDialog). handoff_file's
# roadmap §5.1 — cheap, project-wide analysis helpers that replace a couple
# of manual searches each.
const SYSTEM_PROMPT_ANALYSIS_TOOLS := (
	"For project-wide analysis instead of piecing it together from separate "
	+ "searches: list_autoloads reports every autoload singleton in one call "
	+ "(autoloads aren't .gd declarations, so find_symbol won't find them); "
	+ "find_rpc_calls reports every @rpc-annotated function and every "
	+ "rpc()/rpc_id() call site, grouped by method name — use it for "
	+ "multiplayer RPC bugs instead of two separate search_text calls; "
	+ "find_signal_wiring is find_references specifically for a signal, "
	+ "reporting every .connect(...) and .emit()/emit_signal(...) site "
	+ "together, plus its declaration. "
)

# Conditional on godot_api_lookup being registered. handoff_file's roadmap
# §5.2 — "biggest lever against hallucinated API calls." The tool's own
# description already explains the member argument and caching behavior,
# so this section only needs to tell the model WHEN to reach for it.
const SYSTEM_PROMPT_API_LOOKUP := (
	"Before assuming whether a built-in Godot class has a particular method, signal, or "
	+ "property, call godot_api_lookup with that class's name — it reads the engine's own "
	+ "class reference, so it's authoritative where memory of the API might be wrong or "
	+ "out of date. Use it especially for less-common classes (AnimationTree state "
	+ "machines, MultiplayerSynchronizer, NavigationAgent) where a wrong guess at a method "
	+ "name produces a silent runtime error instead of a parse error. "
)

const SYSTEM_PROMPT_TAIL := (
	"When you don't know which file contains something, don't guess a "
	+ "specific filename or identifier — start with `find_files('*.gd')` "
	+ "to see the project layout, then search for a short substring that's "
	+ "likely to appear in the surrounding code. If the user asks you to "
	+ "ADD something, the thing to search for is what EXISTS around it, "
	+ "not the thing being added (it doesn't exist yet). "
	+ "Before renaming or changing the signature of an existing function, "
	+ "variable, or signal, use find_references to see every place it is "
	+ "used — find_symbol only shows the declaration, and a rename that "
	+ "misses a call site leaves the project broken. String-literal "
	+ "references (connect(\"signal\", ...), call(\"method\", ...)) are "
	+ "reported with a [string] tag and must be updated too. "
	+ "Once you have located the code you need to change, act on it — do not "
	+ "re-search for information that is already visible in your context. Each "
	+ "tool call costs an API round trip and, on some providers, counts against "
	+ "a tight daily quota. One targeted read is worth more than three "
	+ "confirming searches."
)

var process_manager: GodotProcessManager
var _approval_dialog: ConfirmationDialog
var _approval_ctx: Dictionary = {}

var project_panel: ProjectPanel
var chat_panel: ChatPanel
var activity_panel: ActivityPanel
var status_bar: StatusBar
var settings_dialog: SettingsDialog
var diff_dialog: DiffDialog

var agent: AgentLoop
var project_manager := ProjectManager.new()
var llm_client: LLMClient
var plan_store: PlanStore
var _checkpoint_manager: CheckpointManager

# Instances for the optional tools (see OPTIONAL_TOOL_NAMES), created once
# and registered/unregistered without being recreated.
var _optional_tools: Dictionary = {}   # name -> Tool

var _tool_count: int = 0
var _project_loaded: bool = false

var _status_pill: PanelContainer
var _status_pill_label: Label
var _status_dot: Label
var _theme_btn: Button
var _cancel_btn: Button

func _ready() -> void:
	_setup_agent()
	_build_ui()
	_wire_agent()
	ThemeManager.theme_changed.connect(_on_theme_changed)
	AppSettings.save_failed.connect(_on_save_failed)
	_apply_persisted_settings()
	_try_restore_last_project()
	_on_theme_changed()

func _setup_agent() -> void:
	agent = AgentLoop.new()
	agent.name = "AgentLoop"
	add_child(agent)

	llm_client = LLMClient.new()
	llm_client.name = "LLMClient"
	add_child(llm_client)
	agent.llm_client = llm_client

	process_manager = GodotProcessManager.new()
	process_manager.name = "GodotProcessManager"
	add_child(process_manager)

	_checkpoint_manager = CheckpointManager.new()
	agent.tool_manager.checkpoint_manager = _checkpoint_manager

	# Read tools
	agent.tool_manager.register(ReadFileTool.new())
	# Batches several read_file-shaped reads into one call — see
	# ReadFilesTool.gd's header comment. Registered unconditionally
	# alongside read_file since it benefits every tier, not just WEB_CHAT,
	# though the round-trip savings matter most there.
	agent.tool_manager.register(ReadFilesTool.new())
	agent.tool_manager.register(ListDirectoryTool.new())
	agent.tool_manager.register(SearchTextTool.new())
	agent.tool_manager.register(FindFilesTool.new())
	agent.tool_manager.register(FindSymbolTool.new())
	agent.tool_manager.register(FindReferencesTool.new())

	# Write tools
	agent.tool_manager.register(WriteFileTool.new())
	agent.tool_manager.register(CreateFileTool.new())
	agent.tool_manager.register(EditFileTool.new())
	agent.tool_manager.register(EditFileLinesTool.new())
	agent.tool_manager.register(DeleteFileTool.new())
	var revert_tool := RevertLastChangeTool.new()
	revert_tool.checkpoint_manager = _checkpoint_manager
	agent.tool_manager.register(revert_tool)

	plan_store = PlanStore.new()
	plan_store.plan_changed.connect(_on_plan_changed)

	# Godot process tools (always-on)
	agent.tool_manager.register(LaunchHeadlessTool.new())
	agent.tool_manager.register(CheckScriptTool.new())
	agent.tool_manager.register(CheckProjectTool.new())

	# Optional tools: instantiated now so their wiring (plan_store, etc.) is
	# set up once, but NOT registered yet — _apply_tool_registration() (run
	# from _apply_persisted_settings()) decides which are actually enabled,
	# based on AppSettings.disabled_tools.
	var write_plan_tool := WritePlanTool.new()
	write_plan_tool.plan_store = plan_store
	_optional_tools["write_plan"] = write_plan_tool
	var update_plan_tool := UpdatePlanTool.new()
	update_plan_tool.plan_store = plan_store
	_optional_tools["update_plan"] = update_plan_tool
	_optional_tools["launch_editor"] = LaunchEditorTool.new()
	_optional_tools["launch_project"] = LaunchProjectTool.new()

	# Scene inspection tools (handoff_file §5.2). Plain ProjectPathTool
	# subclasses — _apply_tool_registration()'s generic loop wires
	# project_root the same way it does for every other tool; no special
	# casing needed here beyond instantiation.
	_optional_tools["inspect_scene"] = InspectSceneTool.new()
	_optional_tools["find_node"] = FindNodeTool.new()
	_optional_tools["get_node_property"] = GetNodePropertyTool.new()
	_optional_tools["find_scene_users"] = FindSceneUsersTool.new()

	# Runtime observation (handoff_file §5.3). Extends GodotTool, so the
	# generic GodotTool cast in _apply_tool_registration() wires
	# process_manager/godot_executable/model_profile automatically, exactly
	# like launch_editor/launch_project above.
	_optional_tools["run_scenario"] = RunScenarioTool.new()

	# Project-wide analysis tools (handoff_file roadmap §5.1 — "cheap
	# wins"). Plain ProjectPathTool subclasses, same wiring story as the
	# scene tools above: _apply_tool_registration()'s generic loop sets
	# project_root and nothing else is needed.
	_optional_tools["list_autoloads"] = ListAutoloadsTool.new()
	_optional_tools["find_rpc_calls"] = FindRpcCallsTool.new()
	_optional_tools["find_signal_wiring"] = FindSignalWiringTool.new()

	# Godot API/docs lookup (handoff_file roadmap §5.2). Extends GodotTool,
	# so the generic GodotTool cast in _apply_tool_registration() wires
	# process_manager/godot_executable/model_profile automatically, exactly
	# like run_scenario/launch_editor/launch_project above.
	_optional_tools["godot_api_lookup"] = GodotApiLookupTool.new()

	_tool_count = agent.tool_manager.all_schemas().size()

	# The system prompt itself (base + optional sections) is assembled by
	# _rebuild_system_prompt(), called from _apply_persisted_settings() once
	# the model tier and enabled tool set are known — not here.

func _wire_agent() -> void:
	llm_client.response_received.connect(agent._on_response)
	llm_client.request_failed.connect(agent._on_request_failed)
	llm_client.request_retrying.connect(_on_request_retrying)

	agent.assistant_text.connect(_on_assistant_text)
	agent.tool_started.connect(_on_tool_started)
	agent.tool_finished.connect(_on_tool_finished)
	agent.state_changed.connect(_on_state_changed)
	agent.finished.connect(_on_agent_finished)

	agent.tool_manager.approval_requested.connect(_on_approval_requested)

	project_panel.project_open_requested.connect(_on_project_open_requested)
	chat_panel.message_submitted.connect(_on_user_message)

	process_manager.process_output.connect(_on_process_output)
	process_manager.process_started.connect(func(id, cmd): activity_panel.log_info("spawn[%d]: %s" % [id, cmd]))
	process_manager.process_exited.connect(func(id, code): activity_panel.log_info("exit[%d]: %d" % [id, code]))

func _on_approval_requested(tool_name: String, args: Dictionary, permission: String) -> void:
	_approval_ctx = {"tool": tool_name, "args": args, "permission": permission}
	if _approval_dialog == null:
		_approval_dialog = ConfirmationDialog.new()
		_approval_dialog.title = "Permission required"
		_approval_dialog.ok_button_text = "Allow"
		_approval_dialog.cancel_button_text = "Deny"
		_approval_dialog.confirmed.connect(func(): agent.tool_manager.respond_approval(true))
		_approval_dialog.canceled.connect(func(): agent.tool_manager.respond_approval(false))
		add_child(_approval_dialog)
	_approval_dialog.dialog_text = (
		"Tool: %s\nPermission: %s\nArguments:\n%s"
		% [tool_name, permission, JSON.stringify(args, "  ")]
	)
	_approval_dialog.popup_centered(Vector2i(520, 280))

func _on_request_retrying(attempt: int, delay: float) -> void:
	activity_panel.log_info("rate limited (429) — retrying in %.0fs (attempt %d/%d)" % [delay, attempt, LLMClient.MAX_RETRIES])
	status_bar.set_status("Rate limited, retrying…")
	chat_panel.set_status_phase("Rate limited — retrying in %.0fs" % delay)

func _on_plan_changed() -> void:
	var prog: Dictionary = plan_store.progress()
	activity_panel.log_info(
		"plan updated (%d/%d done):\n%s" % [prog.get("done", 0), prog.get("total", 0), plan_store.describe()]
	)
	_save_session()

func _on_revert_button_pressed() -> void:
	if _checkpoint_manager == null:
		chat_panel.add_error("Checkpoint manager not available.")
		return
	if not _checkpoint_manager.has_checkpoints():
		chat_panel.add_system("Nothing to revert — no checkpointed changes yet.")
		return
	var res: Dictionary = _checkpoint_manager.revert_last()
	if bool(res.get("success", false)):
		var msg := str(res.get("message", "Reverted."))
		chat_panel.add_system(msg)
		activity_panel.log_info("manual revert: " + msg)
		if diff_dialog != null and diff_dialog.visible:
			diff_dialog.refresh()
		_save_session()
	else:
		var err := str(res.get("message", "Revert failed."))
		chat_panel.add_error(err)
		activity_panel.log_error("manual revert failed: " + err)

func _on_diff_reverted(count: int, message: String) -> void:
	chat_panel.add_system(message)
	activity_panel.log_info("reverted %d change(s) from history" % count)
	_save_session()

func _on_cancel_pressed() -> void:
	if not agent.is_busy():
		return
	agent.stop()
	llm_client.cancel_pending()
	activity_panel.log_info("cancelled by user")
	chat_panel.add_system("Cancelled.")
	_save_session()

func _on_process_output(id: int, text: String, is_stderr: bool) -> void:
	var trimmed := text.strip_edges()
	if trimmed == "":
		return
	if is_stderr:
		activity_panel.log_error("[%d] %s" % [id, trimmed])
	else:
		activity_panel.log_info("[%d] %s" % [id, trimmed])

func _build_ui() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)

	var root := VBoxContainer.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_theme_constant_override("separation", 0)
	add_child(root)

	root.add_child(_build_top_bar())

	var split := HSplitContainer.new()
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	split.split_offset = 260
	root.add_child(split)

	project_panel = ProjectPanel.new()
	project_panel.custom_minimum_size.x = 240
	split.add_child(project_panel)

	var right := VSplitContainer.new()
	right.split_offset = 560
	split.add_child(right)

	chat_panel = ChatPanel.new()
	chat_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	right.add_child(chat_panel)

	activity_panel = ActivityPanel.new()
	activity_panel.custom_minimum_size.y = 140
	right.add_child(activity_panel)

	status_bar = StatusBar.new()
	root.add_child(status_bar)
	status_bar.set_tool_count(_tool_count)
	status_bar.set_model(AppSettings.model)

	settings_dialog = SettingsDialog.new()
	add_child(settings_dialog)
	# Window.visible defaults to true — never show the dialog unprompted.
	settings_dialog.hide()
	settings_dialog.settings_applied.connect(_on_settings_applied)

	diff_dialog = DiffDialog.new()
	diff_dialog.set_checkpoint_manager(_checkpoint_manager)
	add_child(diff_dialog)
	diff_dialog.hide()
	diff_dialog.reverted.connect(_on_diff_reverted)

func _build_top_bar() -> Control:
	var bar := PanelContainer.new()
	bar.custom_minimum_size.y = 52
	var style := StyleBoxFlat.new()
	style.bg_color = ThemeManager.c("bg_panel")
	style.border_width_bottom = 1
	style.border_color = ThemeManager.c("border")
	style.content_margin_left = 16
	style.content_margin_right = 16
	style.content_margin_top = 8
	style.content_margin_bottom = 8
	bar.add_theme_stylebox_override("panel", style)
	bar.set_meta("is_topbar", true)

	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 10)
	bar.add_child(h)

	var mark := Label.new()
	mark.text = "◆"
	ThemeManager.set_font(mark, 15)
	mark.add_theme_color_override("font_color", ThemeManager.c("accent"))
	h.add_child(mark)

	var title := Label.new()
	title.text = "Godot Agent"
	ThemeManager.set_font(title, 14)
	title.add_theme_color_override("font_color", ThemeManager.c("text"))
	h.add_child(title)

	h.add_child(VSeparator.new())

	var file_menu := MenuButton.new()
	file_menu.text = "File"
	file_menu.flat = true
	var fp := file_menu.get_popup()
	fp.add_item("Open Project…", 0)
	fp.add_item("Close Project", 1)
	fp.add_separator()
	fp.add_item("Settings…", 2)
	fp.add_separator()
	fp.add_item("Quit", 3)
	fp.id_pressed.connect(_on_file_menu)
	h.add_child(file_menu)

	var help_menu := MenuButton.new()
	help_menu.text = "Help"
	help_menu.flat = true
	var hp := help_menu.get_popup()
	hp.add_item("About", 0)
	hp.id_pressed.connect(_on_help_menu)
	h.add_child(help_menu)

	var sp := Control.new()
	sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(sp)

	# Visible confirmation that saved settings actually loaded.
	_status_pill = PanelContainer.new()
	var pill_h := HBoxContainer.new()
	pill_h.add_theme_constant_override("separation", 6)
	_status_pill.add_child(pill_h)
	_status_dot = Label.new()
	_status_dot.text = "●"
	ThemeManager.set_font(_status_dot, 10)
	pill_h.add_child(_status_dot)
	_status_pill_label = Label.new()
	ThemeManager.set_font(_status_pill_label, 11)
	pill_h.add_child(_status_pill_label)
	h.add_child(_status_pill)

	h.add_child(VSeparator.new())

	var settings_btn := Button.new()
	settings_btn.text = "Settings"
	settings_btn.tooltip_text = "API key, endpoint, model, model tier, enabled tools, Godot executable"
	settings_btn.pressed.connect(func(): settings_dialog.open_with_current())
	h.add_child(settings_btn)

	var history_btn := Button.new()
	history_btn.text = "History"
	history_btn.tooltip_text = "View and revert past file changes"
	history_btn.pressed.connect(func(): diff_dialog.open())
	h.add_child(history_btn)

	var revert_btn := Button.new()
	revert_btn.text = "Revert"
	revert_btn.tooltip_text = "Undo the most recent agent file change (write/create/edit/delete)"
	revert_btn.pressed.connect(_on_revert_button_pressed)
	h.add_child(revert_btn)

	_cancel_btn = Button.new()
	_cancel_btn.text = "Cancel"
	_cancel_btn.tooltip_text = "Abort the current turn — use if a request hangs (e.g. timeout set very high/unlimited)"
	_cancel_btn.disabled = true
	_cancel_btn.pressed.connect(_on_cancel_pressed)
	h.add_child(_cancel_btn)

	_theme_btn = Button.new()
	_theme_btn.custom_minimum_size.x = 40
	_theme_btn.tooltip_text = "Toggle dark / light theme"
	_theme_btn.pressed.connect(func(): ThemeManager.toggle())
	h.add_child(_theme_btn)

	return bar

func _apply_persisted_settings() -> void:
	llm_client.api_key = AppSettings.api_key
	llm_client.endpoint = AppSettings.endpoint
	llm_client.model = AppSettings.model
	llm_client.request_timeout = AppSettings.llm_request_timeout
	agent.auto_verify_writes = AppSettings.auto_verify_writes
	if AppSettings.godot_executable != "":
		project_manager.set_godot_executable(AppSettings.godot_executable)
	_refresh_status_pill()
	for v in agent.tool_manager._tools.values():
		var gt := v as GodotTool
		if gt != null:
			gt.godot_executable = AppSettings.godot_executable
	_apply_tool_registration()
	_apply_model_profile()

# Registers or unregisters each optional tool against ToolManager to match
# AppSettings.disabled_tools. Instances live in _optional_tools and are
# never recreated — a tool re-enabled mid-session is wired here exactly as
# _open_project()'s loop would have wired it at project-open time, since
# that loop only touches tools that were already registered when it ran.
func _apply_tool_registration() -> void:
	for tool_name in OPTIONAL_TOOL_NAMES:
		var t: Tool = _optional_tools.get(tool_name, null)
		if t == null:
			continue
		var should_enable :bool= not (tool_name in AppSettings.disabled_tools)
		var is_registered := agent.tool_manager.has(tool_name)
		if should_enable and not is_registered:
			agent.tool_manager.register(t)
			if project_manager.current != null:
				t.project_root = project_manager.current.root_path
			var gt := t as GodotTool
			if gt != null:
				gt.process_manager = process_manager
				gt.godot_executable = AppSettings.godot_executable
		elif not should_enable and is_registered:
			agent.tool_manager.unregister(tool_name)

	_tool_count = agent.tool_manager.all_schemas().size()
	if status_bar != null:
		status_bar.set_tool_count(_tool_count)

# Resolves the current model tier (AppSettings.model_tier, "auto" or an
# explicit override) into a ModelProfile and pushes its knobs into every
# place that used to hardcode small-model accommodations: AgentLoop's
# nudges and caps, ReadFileTool's large-file threshold, GodotTool's
# syntax-hint gate, and the system prompt's optional sections. Called at
# startup and every time Settings is saved, so switching models or
# providers re-tunes the harness without a restart.
func _apply_model_profile() -> void:
	var profile := AppSettings.resolved_profile()

	agent.max_tool_result_chars = profile.max_tool_result_chars
	agent.max_synthetic_recoveries = profile.max_synthetic_recoveries
	agent.max_auto_verify_per_task = profile.max_auto_verify_per_task
	agent.max_iterations = profile.max_iterations
	agent.enable_gave_up_escalation = profile.enable_gave_up_escalation
	agent.enable_no_read_nudge = profile.enable_no_read_nudge
	agent.enable_symbol_guess_nudge = profile.enable_symbol_guess_nudge
	agent.inject_diagnostic_priming = profile.inject_diagnostic_priming
	agent.extra_system_hint = profile.extra_system_hint
	agent.enable_web_chat_single_call_hint = profile.inject_web_chat_protocol
	agent.context_max_tokens = profile.context_max_tokens
	llm_client.retry_on_429 = profile.retry_429_locally

	for v in agent.tool_manager._tools.values():
		var rt := v as ReadFileTool
		if rt != null:
			rt.set_large_file_line_threshold(profile.large_file_line_threshold)
		# read_files shares read_file's large-file threshold so the two
		# tools report the same cutoff to the model — see ReadFilesTool.gd.
		var rft := v as ReadFilesTool
		if rft != null:
			rft.set_large_file_line_threshold(profile.large_file_line_threshold)
		var gt := v as GodotTool
		if gt != null:
			gt.model_profile = profile

	_rebuild_system_prompt(profile)
	status_bar.set_model("%s  ·  %s" % [AppSettings.model, ModelProfile.tier_display_name(profile.tier)])

func _rebuild_system_prompt(profile: ModelProfile) -> void:
	var prompt := SYSTEM_PROMPT_INTRO
	# Web-chat protocol goes FIRST — right after the one-line intro — so
	# it's the highest-attention block in the prompt. A large model reads
	# top-down; putting the "you can't emit real tool calls" rule after
	# the general tool-usage paragraph would make it look like a footnote.
	if profile.inject_web_chat_protocol:
		prompt += "\n" + SYSTEM_PROMPT_WEB_CHAT_PROTOCOL + "\n"
	if profile.inject_act_dont_ask:
		prompt += SYSTEM_PROMPT_ACT_DONT_ASK
	if profile.inject_syntax_cheatsheet:
		prompt += "\n" + SYSTEM_PROMPT_SYNTAX_CHEATSHEET
	prompt += "\n" + SYSTEM_PROMPT_BASE
	if agent.tool_manager.has("write_plan"):
		prompt += SYSTEM_PROMPT_PLAN_TOOLS
	if agent.tool_manager.has("inspect_scene"):
		prompt += SYSTEM_PROMPT_SCENE_TOOLS
	if agent.tool_manager.has("run_scenario"):
		prompt += SYSTEM_PROMPT_RUN_SCENARIO
	if agent.tool_manager.has("list_autoloads"):
		prompt += SYSTEM_PROMPT_ANALYSIS_TOOLS
	if agent.tool_manager.has("godot_api_lookup"):
		prompt += SYSTEM_PROMPT_API_LOOKUP
	prompt += SYSTEM_PROMPT_TAIL
	agent.context_manager.system_prompt = prompt

func _on_settings_applied() -> void:
	_apply_persisted_settings()
	activity_panel.log_info("settings saved and applied")

func _refresh_status_pill() -> void:
	if _status_pill == null:
		return
	var connected := AppSettings.has_saved_credentials()
	var dot_color := ThemeManager.c("success") if connected else ThemeManager.c("text_mute")

	var s := StyleBoxFlat.new()
	s.bg_color = ThemeManager.c("bg_input")
	s.border_color = ThemeManager.c("border")
	s.set_border_width_all(1)
	s.set_corner_radius_all(20)
	s.content_margin_left = 12
	s.content_margin_right = 12
	s.content_margin_top = 5
	s.content_margin_bottom = 5
	_status_pill.add_theme_stylebox_override("panel", s)

	if _status_dot != null:
		_status_dot.add_theme_color_override("font_color", dot_color)

	if _status_pill_label != null:
		_status_pill_label.text = AppSettings.model if connected else "No API key set"
		_status_pill_label.add_theme_color_override(
			"font_color",
			ThemeManager.c("text") if connected else ThemeManager.c("text_dim")
		)

func _on_save_failed(reason: String) -> void:
	chat_panel.add_error("Could not save settings: %s" % reason)

func _try_restore_last_project() -> void:
	if AppSettings.last_project == "":
		return
	if not DirAccess.dir_exists_absolute(AppSettings.last_project):
		return
	_open_project(AppSettings.last_project)

func _on_file_menu(id: int) -> void:
	match id:
		0:
			_open_project_dialog()
		1:
			_close_project()
		2:
			settings_dialog.open_with_current()
		3:
			get_tree().quit()

func _on_help_menu(id: int) -> void:
	if id == 0:
		chat_panel.add_system(
			"GodotAgent — a Godot-native coding agent.\n"
			+ "Pick a provider and API key in Settings, then open a project."
		)

func _on_project_open_requested(path: String) -> void:
	if path == "":
		_open_project_dialog()
	else:
		_open_project(path)

func _open_project_dialog() -> void:
	var fd := FileDialog.new()
	fd.file_mode = FileDialog.FILE_MODE_OPEN_DIR
	fd.access = FileDialog.ACCESS_FILESYSTEM
	fd.title = "Select a Godot project folder"
	fd.dir_selected.connect(func(path: String):
		fd.queue_free()
		_open_project(path)
	)
	fd.canceled.connect(func(): fd.queue_free())
	add_child(fd)
	fd.popup_centered_ratio(0.7)

func _open_project(path: String) -> void:
	if not DirAccess.dir_exists_absolute(path):
		chat_panel.add_error("Not a directory: %s" % path)
		return

	# Persist whatever session was active before switching away from it (a
	# no-op if none was loaded yet — see _save_session's own guard), then
	# clear in-memory state so it can't bleed into the project we're about
	# to open. Without this, conversation/plan/checkpoint history from the
	# previous project silently carried over into the new one.
	_save_session()
	_reset_session_state()

	var info := project_manager.open(path)
	if info == null:
		chat_panel.add_error("Failed to open project: %s" % path)
		return

	for v in agent.tool_manager._tools.values():
		var t := v as Tool
		if t == null:
			continue
		t.project_root = info.root_path
		var gt := t as GodotTool
		if gt != null:
			gt.process_manager = process_manager
			gt.godot_executable = AppSettings.godot_executable

	project_panel.load_project(info.root_path)
	AppSettings.add_recent_project(info.root_path)
	AppSettings.last_project = info.root_path
	AppSettings.save_settings()

	_load_project_instructions(info.root_path)
	_load_project_files(info.root_path)
	_project_loaded = true
	status_bar.set_project("%s — %s" % [info.name, info.root_path])
	chat_panel.add_system("Opened project [b]%s[/b] at [code]%s[/code]" % [info.name, info.root_path])
	activity_panel.log_info("project opened: " + info.root_path)

	_maybe_offer_resume(info.root_path)

# --- session persistence ---------------------------------------------------
#
# Saves { conversation, plan steps, checkpoint stack summary } to
# user://sessions/<id>/session.json after every turn — never AppSettings.
# api_key or anything else credential-shaped. See SessionManager.

func _save_session() -> void:
	if not _project_loaded or project_manager.current == null:
		return
	if agent.conversation.messages.is_empty() and plan_store.is_empty() and not _checkpoint_manager.has_checkpoints():
		return   # nothing worth writing yet
	SessionManager.save(
		project_manager.current.root_path,
		agent.conversation.to_array(),
		plan_store.steps,
		_checkpoint_manager.to_session_data()
	)

# Clears in-memory conversation/plan/checkpoint state (and the chat log's
# visual mirror of it) so it never bleeds across a project switch. Called
# before opening a different project and before closing one — see
# _open_project/_close_project.
func _reset_session_state() -> void:
	agent.conversation.messages.clear()
	plan_store.set_plan([])
	_checkpoint_manager.clear_all()
	chat_panel.clear()

# Offers to resume a previously-saved session for the just-opened project.
# Declining just leaves the freshly-reset state in place — the next
# _save_session() call naturally overwrites the old file with the new
# (empty, then growing) conversation, so there's nothing extra to clean up.
func _maybe_offer_resume(root_path: String) -> void:
	if not SessionManager.has_session(root_path):
		return
	var data := SessionManager.load(root_path)
	if data.is_empty():
		return
	var conv_v: Variant = data.get("conversation", [])
	var has_content := typeof(conv_v) == TYPE_ARRAY and not (conv_v as Array).is_empty()
	if not has_content:
		return

	var dlg := ConfirmationDialog.new()
	dlg.title = "Resume session?"
	dlg.ok_button_text = "Resume"
	dlg.cancel_button_text = "Start Fresh"
	dlg.dialog_text = (
		"Found a previous session for this project — %s.\n\nResume where you left off?"
		% SessionManager.describe(data)
	)
	dlg.confirmed.connect(func():
		_resume_session(data)
		dlg.queue_free()
	)
	dlg.canceled.connect(func(): dlg.queue_free())
	add_child(dlg)
	dlg.popup_centered(Vector2i(440, 190))

func _resume_session(data: Dictionary) -> void:
	var conv_v: Variant = data.get("conversation", [])
	if typeof(conv_v) == TYPE_ARRAY:
		agent.conversation.load_from_array(conv_v)
	var plan_v: Variant = data.get("plan_steps", [])
	if typeof(plan_v) == TYPE_ARRAY and not (plan_v as Array).is_empty():
		plan_store.set_plan(plan_v)
	var cp_v: Variant = data.get("checkpoints", [])
	if typeof(cp_v) == TYPE_ARRAY:
		_checkpoint_manager.restore_from_session_data(cp_v)

	chat_panel.load_conversation(agent.conversation)
	chat_panel.add_system("Resumed previous session — %s." % SessionManager.describe(data))
	activity_panel.log_info("session resumed for " + str(data.get("last_project", "")))
	if diff_dialog != null and diff_dialog.visible:
		diff_dialog.refresh()

# Scans the project once and stores the file listing on ContextManager,
# where it's injected as a fixed leading system message on every build().
# Gives the model an authoritative answer to "does this file exist?" so it
# stops hallucinating paths like res://Scripts/player.gd.
func _load_project_files(root_path: String) -> void:
	if agent == null or agent.context_manager == null:
		return
	var listing := ProjectScanner.scan(root_path)
	agent.context_manager.project_files_summary = listing
	if listing == "":
		activity_panel.log_info("project file list: empty (no readable files)")
		return
	var lines := listing.split("\n")
	var count := lines.size() - 2  # minus header + footer
	activity_panel.log_info("project file list loaded (%d entries, %d chars)" % [count, listing.length()])
	# Log each entry on its own line, skipping the header and footer that
	# ProjectScanner already includes in the listing block. One entry per
	# line keeps the Activity panel readable and lets you see the full list
	# without the log-line character cap kicking in.
	for i in range(1, lines.size() - 1):
		var line: String = lines[i]
		if line == "" or line.begins_with("Project source files") or line.begins_with("("):
			continue
		activity_panel.log_info("  " + line)
# --- project instructions (AGENT.md) --------------------------------------
#
# Loads res://AGENT.md into ContextManager.project_instructions, or clears the
# field if the file is absent/empty. Called on every project open so a stale
# file from a previous project never survives a project switch.
#
# No tool is needed: the instructions are injected as a system message on
# every ContextManager.build() call, and the model can re-read the raw file
# at any time via read_file("res://AGENT.md") if it wants the source text.
func _load_project_instructions(root_path: String) -> void:
	if agent == null or agent.context_manager == null:
		return
	var path := root_path.path_join(PROJECT_INSTRUCTIONS_FILE)
	if not FileAccess.file_exists(path):
		agent.context_manager.project_instructions = ""
		return
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		agent.context_manager.project_instructions = ""
		activity_panel.log_error(
			"AGENT.md exists but could not be opened (error %d)" % FileAccess.get_open_error()
		)
		return
	var text := f.get_as_text()
	f.close()

	if text.strip_edges() == "":
		agent.context_manager.project_instructions = ""
		return

	var truncated := text.length() > MAX_PROJECT_INSTRUCTIONS_CHARS
	if truncated:
		text = text.substr(0, MAX_PROJECT_INSTRUCTIONS_CHARS) \
			+ "\n\n…[AGENT.md truncated at %d chars — read the file directly for the rest]" \
			% MAX_PROJECT_INSTRUCTIONS_CHARS

	agent.context_manager.project_instructions = (
		"Project instructions from res://AGENT.md — these are the project's "
		+ "own conventions and constraints. Follow them unless the user's "
		+ "message explicitly overrides them:\n\n" + text
	)

	chat_panel.add_system(
		"Loaded project instructions from [code]res://AGENT.md[/code]%s."
		% (" (truncated)" if truncated else "")
	)
	activity_panel.log_info("AGENT.md loaded (%d chars%s)" % [
		text.length(), ", truncated" if truncated else ""
	])

func _close_project() -> void:
	_save_session()
	_reset_session_state()
	project_manager.current = null
	_project_loaded = false
	agent.context_manager.project_instructions = ""
	agent.context_manager.project_files_summary = ""
	status_bar.set_project("No project")
	activity_panel.log_info("project closed")

func _on_user_message(text: String) -> void:
	if not _project_loaded:
		chat_panel.add_error("Open a project first (File → Open Project…).")
		return
	if AppSettings.endpoint.strip_edges() == "":
		chat_panel.add_error("Endpoint is empty — set it in Settings.")
		return
	chat_panel.add_user(text)
	activity_panel.log_info("user task submitted")
	_apply_persisted_settings()
	status_bar.start_timer()
	chat_panel.show_status_indicator()
	agent.start(text)
	_save_session()

func _on_assistant_text(text: String) -> void:
	chat_panel.add_assistant(text)
	activity_panel.log_info("assistant responded")
	_save_session()

func _on_tool_started(tool_name: String, args: Dictionary) -> void:
	chat_panel.add_tool_started(tool_name, args)
	activity_panel.log_tool_started(tool_name, args)
	chat_panel.set_status_phase("Running %s" % tool_name)

func _on_tool_finished(tool_name: String, result: ToolResult) -> void:
	chat_panel.add_tool_finished(result)
	activity_panel.log_tool_finished(tool_name, result)
	_save_session()

func _on_state_changed(state: int) -> void:
	status_bar.set_status(AgentState.name_of(state))
	_cancel_btn.disabled = state in [
		AgentState.State.IDLE,
		AgentState.State.COMPLETED,
		AgentState.State.FAILED,
		AgentState.State.CANCELLED,
	]
	match state:
		AgentState.State.COMPLETED, AgentState.State.FAILED, AgentState.State.CANCELLED:
			status_bar.stop_timer()
			chat_panel.hide_status_indicator()
		AgentState.State.IDLE:
			pass
		_:
			chat_panel.set_status_phase(_phase_for_state(state))

func _phase_for_state(state: int) -> String:
	match state:
		AgentState.State.THINKING:
			return "Thinking"
		AgentState.State.EXECUTING_TOOL:
			return "Running tool"
		AgentState.State.WAITING_FOR_APPROVAL:
			return "Waiting for your approval"
		AgentState.State.VERIFYING:
			return "Verifying"
		AgentState.State.COMPACTING:
			return "Compacting context"
		_:
			return "Working"

func _on_agent_finished(reason: String) -> void:
	activity_panel.log_info("agent finished: " + reason)
	status_bar.stop_timer()
	chat_panel.hide_status_indicator()
	if reason.begins_with("failed"):
		chat_panel.add_error(reason)
	_save_session()

func _on_theme_changed() -> void:
	theme = ThemeManager.theme
	# Re-derive every per-node font override from its remembered base size so
	# a text-scale change (or theme swap) reaches nodes that set their own size.
	ThemeManager.reapply_fonts(self)
	_theme_btn.text = "☀" if ThemeManager.is_dark() else "☾"
	var bg := StyleBoxFlat.new()
	bg.bg_color = ThemeManager.c("bg")
	add_theme_stylebox_override("panel", bg)
	_refresh_status_pill()
	if project_panel != null:
		project_panel.apply_theme()
	if chat_panel != null:
		chat_panel.apply_theme()
	if activity_panel != null:
		activity_panel.apply_theme()
	if status_bar != null:
		status_bar.apply_theme()
	if settings_dialog != null:
		settings_dialog.apply_theme()
	if diff_dialog != null:
		diff_dialog.apply_theme()
