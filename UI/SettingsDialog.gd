class_name SettingsDialog
extends Window

signal settings_applied()

const PROVIDERS := [
	{
		"name": "Google AI Studio",
		"endpoint": "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions",
		"model": "gemini-3.6-flash",
	},
	{
		"name": "OpenAI",
		"endpoint": "https://api.openai.com/v1/chat/completions",
		"model": "gpt-4o-mini",
	},
	{
		"name": "OpenRouter (Auto Free)",
		"endpoint": "https://openrouter.ai/api/v1/chat/completions",
		"model": "openrouter/free",
	},
	{
		"name": "Groq",
		"endpoint": "https://api.groq.com/openai/v1/chat/completions",
		"model": "llama-3.3-70b-versatile",
	},
	{
		"name": "Ollama (local)",
		"endpoint": "http://localhost:11434/v1/chat/completions",
		"model": "qwen2.5-coder:7b",
	},
	{
		"name": "LM Studio (local)",
		"endpoint": "http://localhost:1234/v1/chat/completions",
		"model": "local-model",
	},
	{
		"name": "DeepSeek Web Bridge (localhost)",
		"endpoint": "http://127.0.0.1:5000/v1/chat/completions",
		"model": "deepseek-web",
	},
	{
		"name": "Custom",
		"endpoint": "",
		"model": "",
	},
]

# Dropdown order matches ModelProfile.Tier plus a leading "Auto" meta-option.
# TIER_VALUES[0] ("auto") is not a real tier — AppSettings.resolved_profile()
# treats it as "guess from the model name".
const TIER_LABELS := ["Auto", "Tiny", "Small", "Standard", "Powerful", "Web Chat"]
const TIER_VALUES := ["auto", "tiny", "small", "standard", "powerful", "web_chat"]

var _provider: OptionButton
var _api_key: LineEdit
var _endpoint: LineEdit
var _model: LineEdit
var _model_tier: OptionButton
var _tier_hint: Label
var _timeout: LineEdit
var _godot: LineEdit
var _auto_scroll: CheckBox
var _auto_verify: CheckBox
var _tool_launch_editor: CheckBox
var _tool_launch_project: CheckBox
var _tool_plan: CheckBox
var _tool_scene: CheckBox
var _tool_run_scenario: CheckBox
var _tool_analysis: CheckBox
var _tool_api_lookup: CheckBox
var _font_scale: HSlider
var _font_scale_label: Label
var _dark_btn: Button
var _light_btn: Button
var _saved_label: Label
var _root: VBoxContainer

func _init() -> void:
	title = "Settings"
	size = Vector2i(680, 700)
	unresizable = false
	# Window.visible defaults to true; without this the dialog appears every
	# time MainWindow builds its UI and has to be dismissed by hand.
	visible = false
	close_requested.connect(hide)

func _ready() -> void:
	hide()

	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 20)
	margin.add_theme_constant_override("margin_right", 20)
	margin.add_theme_constant_override("margin_top", 16)
	margin.add_theme_constant_override("margin_bottom", 16)
	add_child(margin)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	margin.add_child(scroll)

	_root = VBoxContainer.new()
	_root.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_root.add_theme_constant_override("separation", 14)
	scroll.add_child(_root)

	# --- Provider section ---------------------------------------------------
	_root.add_child(_section("Model provider"))

	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 14)
	grid.add_theme_constant_override("v_separation", 10)
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_root.add_child(grid)

	grid.add_child(_lbl("Provider"))
	_provider = OptionButton.new()
	for p in PROVIDERS:
		_provider.add_item(str(p["name"]))
	_provider.item_selected.connect(_on_provider_changed)
	_provider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.add_child(_provider)

	grid.add_child(_lbl("API key"))
	_api_key = LineEdit.new()
	_api_key.secret = true
	_api_key.placeholder_text = "sk-… / AIza… (blank is fine for local models and the bridge)"
	_api_key.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.add_child(_api_key)

	grid.add_child(_lbl("Endpoint"))
	_endpoint = LineEdit.new()
	_endpoint.placeholder_text = "https://…/v1/chat/completions"
	_endpoint.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.add_child(_endpoint)

	grid.add_child(_lbl("Model"))
	_model = LineEdit.new()
	_model.placeholder_text = "gemini-2.5-flash"
	_model.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_model.text_changed.connect(func(_t: String): _refresh_tier_hint())
	grid.add_child(_model)

	grid.add_child(_lbl("Model tier"))
	var tier_row := HBoxContainer.new()
	tier_row.add_theme_constant_override("separation", 8)
	tier_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_model_tier = OptionButton.new()
	for label in TIER_LABELS:
		_model_tier.add_item(label)
	_model_tier.tooltip_text = (
		"How much hand-holding the harness adds for this model: a syntax "
		+ "cheat sheet, extra nudges, and smaller read/tool-output caps. "
		+ "'Auto' guesses from the model name — cloud-class models "
		+ "(GPT-4/5-class, Claude, Gemini, 70B+ local) get none of it by "
		+ "default, and 'deepseek-web' / 'web-chat' names resolve to Web "
		+ "Chat. Pick Web Chat manually if you're on a bridge endpoint that "
		+ "has no native function-calling but doesn't say so in its name."
	)
	_model_tier.item_selected.connect(func(_i: int): _refresh_tier_hint())
	_model_tier.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tier_row.add_child(_model_tier)
	_tier_hint = Label.new()
	ThemeManager.set_font(_tier_hint, 11)
	tier_row.add_child(_tier_hint)
	grid.add_child(tier_row)

	grid.add_child(_lbl("Timeout (s)"))
	_timeout = LineEdit.new()
	_timeout.placeholder_text = "120"
	_timeout.tooltip_text = (
		"How long to wait for the LLM's full response before giving up. Only "
		+ "matters when the connection is fine but the reply is just slow "
		+ "(e.g. a local model chaining several tool calls) — a dropped "
		+ "connection is detected immediately regardless of this value.\n"
		+ "Set to 0 for no timeout (wait indefinitely). Use the ✕ Cancel "
		+ "button in the top bar to manually abort a stuck request.\n"
		+ "For the DeepSeek Web Bridge, set this generously (e.g. 600s) — "
		+ "each tool-call round trip is a real browser type→wait cycle."
	)
	_timeout.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.add_child(_timeout)

	# --- Tools section --------------------------------------------------
	# Unregistering an unused tool drops its schema from every single API
	# call — real, if unglamorous, token savings for tools most setups
	# never touch. See MainWindow._apply_tool_registration().
	_root.add_child(_section("Tools"))

	var tools_box := VBoxContainer.new()
	tools_box.add_theme_constant_override("separation", 8)
	_root.add_child(tools_box)

	var tools_note := Label.new()
	tools_note.text = "Unchecking a tool removes it entirely — its schema is no longer sent to the model, saving tokens on every call."
	ThemeManager.set_font(tools_note, 10)
	tools_note.add_theme_color_override("font_color", ThemeManager.c("text_mute"))
	tools_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	tools_box.add_child(tools_note)

	_tool_launch_editor = CheckBox.new()
	_tool_launch_editor.text = "launch_editor — open the Godot editor for the project"
	tools_box.add_child(_tool_launch_editor)

	_tool_launch_project = CheckBox.new()
	_tool_launch_project.text = "launch_project — run the project's main scene"
	tools_box.add_child(_tool_launch_project)

	_tool_plan = CheckBox.new()
	_tool_plan.text = "write_plan / update_plan — task plan shown in the UI"
	_tool_plan.tooltip_text = "Only useful if you watch the plan as the agent works. Both tools are added or removed together — update_plan has nothing to update without write_plan."
	tools_box.add_child(_tool_plan)

	_tool_scene = CheckBox.new()
	_tool_scene.text = "Scene tools — inspect_scene / find_node / get_node_property / find_scene_users"
	_tool_scene.tooltip_text = (
		"Parses .tscn files into a node tree instead of leaving the model to read raw "
		+ "resource syntax. All four are added or removed together. Worth disabling only "
		+ "if your project is script-only (no scenes worth inspecting) and you want the "
		+ "token savings."
	)
	tools_box.add_child(_tool_scene)

	_tool_run_scenario = CheckBox.new()
	_tool_run_scenario.text = "run_scenario — headless runtime verification"
	_tool_run_scenario.tooltip_text = (
		"Lets the agent write a small GDScript test, boot the REAL project headlessly "
		+ "(real scene, autoloads, collision layers) around it, and read back a PASS/FAIL "
		+ "verdict — the only way it can observe behavior instead of just reasoning about "
		+ "source. Scenario files are written under res://.agent_scenarios/."
	)
	tools_box.add_child(_tool_run_scenario)

	_tool_analysis = CheckBox.new()
	_tool_analysis.text = "Analysis tools — list_autoloads / find_rpc_calls / find_signal_wiring"
	_tool_analysis.tooltip_text = (
		"Project-wide analysis helpers: list_autoloads reads project.godot's [autoload] "
		+ "section in one call (autoloads aren't .gd declarations, so find_symbol can't see "
		+ "them); find_rpc_calls reports every @rpc declaration and every rpc()/rpc_id() call "
		+ "site, grouped by method — the direct fix for chasing a multiplayer RPC bug across "
		+ "two separate searches; find_signal_wiring is find_references specifically for a "
		+ "signal, reporting every .connect(...)/.emit(...) site together. All three are added "
		+ "or removed together."
	)
	tools_box.add_child(_tool_analysis)

	_tool_api_lookup = CheckBox.new()
	_tool_api_lookup.text = "godot_api_lookup — Godot class reference on demand"
	_tool_api_lookup.tooltip_text = (
		"Reads the engine's own class reference (bundled docs, extracted once via "
		+ "`godot --doctool`) so the model can check a built-in class's real methods, "
		+ "signals, and properties instead of guessing names from memory — the biggest "
		+ "lever against hallucinated API calls. The first call per machine generates "
		+ "the doc cache and can take up to a minute; later calls are instant."
	)
	tools_box.add_child(_tool_api_lookup)

	# --- Godot section ------------------------------------------------------
	_root.add_child(_section("Godot"))

	var ggrid := GridContainer.new()
	ggrid.columns = 2
	ggrid.add_theme_constant_override("h_separation", 14)
	ggrid.add_theme_constant_override("v_separation", 10)
	ggrid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_root.add_child(ggrid)

	ggrid.add_child(_lbl("Executable"))
	var gr := HBoxContainer.new()
	gr.add_theme_constant_override("separation", 8)
	gr.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_godot = LineEdit.new()
	_godot.placeholder_text = "C:/Godot/Godot_v4.7.2.exe"
	_godot.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	gr.add_child(_godot)
	var browse := Button.new()
	browse.text = "Browse…"
	browse.pressed.connect(_on_browse_godot)
	gr.add_child(browse)
	ggrid.add_child(gr)

	# --- Interface section --------------------------------------------------
	_root.add_child(_section("Interface"))

	var iface := VBoxContainer.new()
	iface.add_theme_constant_override("separation", 8)
	_root.add_child(iface)

	var theme_row := HBoxContainer.new()
	theme_row.add_theme_constant_override("separation", 8)
	var theme_lbl := Label.new()
	theme_lbl.text = "Theme"
	theme_lbl.custom_minimum_size.x = 90
	theme_row.add_child(theme_lbl)
	_dark_btn = Button.new()
	_dark_btn.text = "Dark"
	_dark_btn.toggle_mode = true
	_dark_btn.pressed.connect(func(): _on_theme_pick(ThemeManager.Mode.DARK))
	theme_row.add_child(_dark_btn)
	_light_btn = Button.new()
	_light_btn.text = "Light"
	_light_btn.toggle_mode = true
	_light_btn.pressed.connect(func(): _on_theme_pick(ThemeManager.Mode.LIGHT))
	theme_row.add_child(_light_btn)
	iface.add_child(theme_row)

	_auto_scroll = CheckBox.new()
	_auto_scroll.text = "Auto-scroll chat"
	iface.add_child(_auto_scroll)

	_auto_verify = CheckBox.new()
	_auto_verify.text = "Auto-run check_script after edits"
	_auto_verify.tooltip_text = (
		"After a successful write/create/edit on a .gd file, automatically run "
		+ "check_script and feed the result back to the model, up to the "
		+ "current model tier's per-task cap (0 for Standard/Powerful/Web Chat, "
		+ "8 for Tiny/Small). Turn off if the extra Godot process spawns are "
		+ "unwanted."
	)
	iface.add_child(_auto_verify)

	var font_row := HBoxContainer.new()
	font_row.add_theme_constant_override("separation", 8)
	var font_lbl := Label.new()
	font_lbl.text = "Text size"
	font_lbl.custom_minimum_size.x = 90
	font_row.add_child(font_lbl)
	_font_scale = HSlider.new()
	_font_scale.min_value = ThemeManager.FONT_SCALE_MIN
	_font_scale.max_value = ThemeManager.FONT_SCALE_MAX
	_font_scale.step = 0.05
	_font_scale.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_font_scale.tooltip_text = (
		"Scales every font in the app — chat bubbles, panels, buttons — so the "
		+ "text stays readable when sitting further from the screen. Applied "
		+ "immediately as you drag, and saved with the rest of the settings."
	)
	_font_scale.value_changed.connect(_on_font_scale_changed)
	font_row.add_child(_font_scale)
	_font_scale_label = Label.new()
	_font_scale_label.custom_minimum_size.x = 46
	font_row.add_child(_font_scale_label)
	iface.add_child(font_row)

	var note := Label.new()
	note.text = "Settings persist to user://agent_settings.cfg."
	ThemeManager.set_font(note, 10)
	note.add_theme_color_override("font_color", ThemeManager.c("text_mute"))
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_root.add_child(note)

	var actions := HBoxContainer.new()
	actions.add_theme_constant_override("separation", 8)
	_saved_label = Label.new()
	_saved_label.text = ""
	_saved_label.add_theme_color_override("font_color", ThemeManager.c("success"))
	actions.add_child(_saved_label)
	var sp2 := Control.new()
	sp2.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	actions.add_child(sp2)
	var cancel := Button.new()
	cancel.text = "Cancel"
	cancel.pressed.connect(hide)
	actions.add_child(cancel)
	var save := Button.new()
	save.text = "Save"
	save.pressed.connect(_on_save)
	actions.add_child(save)
	_root.add_child(actions)

	apply_theme()

func _section(t: String) -> Label:
	var l := Label.new()
	l.text = t
	ThemeManager.set_font(l, 12)
	l.add_theme_color_override("font_color", ThemeManager.c("accent"))
	return l

func _lbl(t: String) -> Label:
	var l := Label.new()
	l.text = t
	l.custom_minimum_size.x = 90
	l.add_theme_color_override("font_color", ThemeManager.c("text_dim"))
	return l

func open_with_current() -> void:
	_provider.selected = clampi(AppSettings.provider_index, 0, PROVIDERS.size() - 1)
	_api_key.text = AppSettings.api_key
	_endpoint.text = AppSettings.endpoint
	_model.text = AppSettings.model
	var tier_idx := TIER_VALUES.find(AppSettings.model_tier.strip_edges().to_lower())
	_model_tier.selected = tier_idx if tier_idx >= 0 else 0
	_timeout.text = str(int(AppSettings.llm_request_timeout))
	_godot.text = AppSettings.godot_executable
	_auto_scroll.button_pressed = AppSettings.auto_scroll_chat
	_auto_verify.button_pressed = AppSettings.auto_verify_writes
	_tool_launch_editor.button_pressed = not ("launch_editor" in AppSettings.disabled_tools)
	_tool_launch_project.button_pressed = not ("launch_project" in AppSettings.disabled_tools)
	_tool_plan.button_pressed = not ("write_plan" in AppSettings.disabled_tools)
	_tool_scene.button_pressed = not ("inspect_scene" in AppSettings.disabled_tools)
	_tool_run_scenario.button_pressed = not ("run_scenario" in AppSettings.disabled_tools)
	_tool_analysis.button_pressed = not ("list_autoloads" in AppSettings.disabled_tools)
	_tool_api_lookup.button_pressed = not ("godot_api_lookup" in AppSettings.disabled_tools)
	_font_scale.value = clampf(AppSettings.ui_font_scale, ThemeManager.FONT_SCALE_MIN, ThemeManager.FONT_SCALE_MAX)
	_refresh_font_scale_label()
	_saved_label.text = ""
	_sync_theme_buttons()
	_refresh_tier_hint()
	popup_centered()

func _refresh_font_scale_label() -> void:
	if _font_scale_label != null:
		_font_scale_label.text = "%d%%" % int(round(_font_scale.value * 100.0))

# Live preview: rescale the whole UI as the slider moves, without persisting
# yet (Save does that). set_font_scale(persist=false) still emits
# theme_changed, which MainWindow._on_theme_changed() turns into a full
# reapply_fonts() walk.
func _on_font_scale_changed(v: float) -> void:
	_refresh_font_scale_label()
	ThemeManager.set_font_scale(v, false)

func _sync_theme_buttons() -> void:
	var dark := ThemeManager.is_dark()
	if _dark_btn != null:
		_dark_btn.button_pressed = dark
	if _light_btn != null:
		_light_btn.button_pressed = not dark

func _on_theme_pick(m: ThemeManager.Mode) -> void:
	ThemeManager.set_mode(m)
	_sync_theme_buttons()

func _on_provider_changed(index: int) -> void:
	if index < 0 or index >= PROVIDERS.size():
		return
	var p: Dictionary = PROVIDERS[index]
	if str(p["name"]) == "Custom":
		return
	_endpoint.text = str(p["endpoint"])
	_model.text = str(p["model"])
	_refresh_tier_hint()

# Shown next to the tier dropdown only while "Auto" is selected — makes the
# guess visible instead of leaving the user to wonder which tier a model
# name resolved to.
func _refresh_tier_hint() -> void:
	if _tier_hint == null or _model_tier == null or _model == null:
		return
	if _model_tier.selected == 0:
		var t := ModelProfile.resolve_tier_from_model_name(_model.text)
		_tier_hint.text = "→ %s" % ModelProfile.tier_display_name(t)
		_tier_hint.add_theme_color_override("font_color", ThemeManager.c("text_mute"))
	else:
		_tier_hint.text = ""

func _on_browse_godot() -> void:
	var fd := FileDialog.new()
	fd.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	fd.access = FileDialog.ACCESS_FILESYSTEM
	fd.title = "Select Godot executable"
	fd.file_selected.connect(func(path: String):
		_godot.text = path
		fd.queue_free()
	)
	fd.canceled.connect(func(): fd.queue_free())
	add_child(fd)
	fd.popup_centered_ratio(0.6)

func _on_save() -> void:
	AppSettings.provider_index = _provider.selected
	AppSettings.api_key = _api_key.text.strip_edges()
	AppSettings.endpoint = _endpoint.text.strip_edges()
	AppSettings.model = _model.text.strip_edges()
	AppSettings.model_tier = TIER_VALUES[_model_tier.selected]

	var raw_t := _timeout.text.strip_edges()
	var t: float
	if raw_t == "":
		t = 120.0
	else:
		t = maxf(0.0, raw_t.to_float())
	AppSettings.llm_request_timeout = clampf(t, 0.0, 3600.0)

	AppSettings.godot_executable = _godot.text.strip_edges()
	AppSettings.auto_scroll_chat = _auto_scroll.button_pressed
	AppSettings.auto_verify_writes = _auto_verify.button_pressed
	AppSettings.ui_font_scale = clampf(_font_scale.value, ThemeManager.FONT_SCALE_MIN, ThemeManager.FONT_SCALE_MAX)

	var disabled: Array[String] = []
	if not _tool_launch_editor.button_pressed:
		disabled.append("launch_editor")
	if not _tool_launch_project.button_pressed:
		disabled.append("launch_project")
	if not _tool_plan.button_pressed:
		disabled.append("write_plan")
		disabled.append("update_plan")
	if not _tool_scene.button_pressed:
		disabled.append("inspect_scene")
		disabled.append("find_node")
		disabled.append("get_node_property")
		disabled.append("find_scene_users")
	if not _tool_run_scenario.button_pressed:
		disabled.append("run_scenario")
	if not _tool_analysis.button_pressed:
		disabled.append("list_autoloads")
		disabled.append("find_rpc_calls")
		disabled.append("find_signal_wiring")
	if not _tool_api_lookup.button_pressed:
		disabled.append("godot_api_lookup")
	AppSettings.disabled_tools = disabled

	var ok := AppSettings.save_settings()
	AppSettings.settings_changed.emit()
	if ok:
		_saved_label.text = "Saved ✓"
		settings_applied.emit()
		hide()
	else:
		_saved_label.text = "Save failed — see console"
		_saved_label.add_theme_color_override("font_color", ThemeManager.c("error"))

func apply_theme() -> void:
	if _root == null:
		return
	_sync_theme_buttons()
