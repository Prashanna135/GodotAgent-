extends Node

const CONFIG_PATH := "user://agent_settings.cfg"
const MAX_RECENT := 12

signal settings_changed()
signal save_failed(reason: String)

var api_key: String = ""
var endpoint: String = "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions"
var model: String = "gemini-3.6-flash"
var provider_index: int = 0
var godot_executable: String = ""
var recent_projects: Array[String] = []
var last_project: String = ""
var auto_scroll_chat: bool = true
var theme_mode: String = "dark"
# Global UI text-size multiplier (0.75–2.0). Applied by ThemeManager to both
# the base theme sizes and every per-node font-size override routed through
# ThemeManager.set_font(), so the whole UI scales together.
var ui_font_scale: float = 1.0
var llm_request_timeout: float = 120.0
var auto_verify_writes: bool = true
# "auto", or a lowercase ModelProfile.Tier name ("tiny"/"small"/"standard"/
# "powerful"). "auto" guesses from `model` via ModelProfile's heuristic.
var model_tier: String = "auto"
# Tool names withheld from registration entirely — their schema is never
# sent to the model, saving ~200-400 tokens/call per entry. Only tools the
# user has no use for should go here (see SettingsDialog's Tools section);
# MainWindow._apply_tool_registration() enforces this against ToolManager.
var disabled_tools: Array[String] = []

func _ready() -> void:
	load_settings()

func load_settings() -> void:
	var cfg := ConfigFile.new()
	var err := cfg.load(CONFIG_PATH)
	if err != OK:
		# First run, or file missing/corrupt — defaults above stay in effect.
		return
	api_key = str(cfg.get_value("llm", "api_key", api_key))
	endpoint = str(cfg.get_value("llm", "endpoint", endpoint))
	model = str(cfg.get_value("llm", "model", model))
	provider_index = int(cfg.get_value("llm", "provider_index", provider_index))
	llm_request_timeout = float(cfg.get_value("llm", "request_timeout", llm_request_timeout))
	model_tier = str(cfg.get_value("llm", "model_tier", model_tier))
	godot_executable = str(cfg.get_value("project", "godot_executable", godot_executable))
	last_project = str(cfg.get_value("project", "last_project", last_project))
	auto_scroll_chat = bool(cfg.get_value("ui", "auto_scroll_chat", auto_scroll_chat))
	theme_mode = str(cfg.get_value("ui", "theme_mode", theme_mode))
	ui_font_scale = float(cfg.get_value("ui", "font_scale", ui_font_scale))
	auto_verify_writes = bool(cfg.get_value("agent", "auto_verify_writes", auto_verify_writes))
	var rp: Variant = cfg.get_value("project", "recent_projects", [])
	recent_projects.clear()
	if typeof(rp) == TYPE_ARRAY:
		var arr: Array = rp
		for v in arr:
			var s := str(v)
			if s != "":
				recent_projects.append(s)
	var dt: Variant = cfg.get_value("agent", "disabled_tools", [])
	disabled_tools.clear()
	if typeof(dt) == TYPE_ARRAY:
		var darr: Array = dt
		for v in darr:
			var s := str(v)
			if s != "":
				disabled_tools.append(s)

func save_settings() -> bool:
	var cfg := ConfigFile.new()
	cfg.set_value("llm", "api_key", api_key)
	cfg.set_value("llm", "endpoint", endpoint)
	cfg.set_value("llm", "model", model)
	cfg.set_value("llm", "provider_index", provider_index)
	cfg.set_value("llm", "request_timeout", llm_request_timeout)
	cfg.set_value("llm", "model_tier", model_tier)
	cfg.set_value("project", "godot_executable", godot_executable)
	cfg.set_value("project", "last_project", last_project)
	cfg.set_value("project", "recent_projects", recent_projects)
	cfg.set_value("ui", "auto_scroll_chat", auto_scroll_chat)
	cfg.set_value("ui", "theme_mode", theme_mode)
	cfg.set_value("ui", "font_scale", ui_font_scale)
	cfg.set_value("agent", "auto_verify_writes", auto_verify_writes)
	cfg.set_value("agent", "disabled_tools", disabled_tools)
	var err := cfg.save(CONFIG_PATH)
	if err != OK:
		var reason := "ConfigFile.save failed with error code %d at %s" % [err, CONFIG_PATH]
		push_error(reason)
		save_failed.emit(reason)
		return false
	return true

func has_saved_credentials() -> bool:
	return api_key.strip_edges() != "" and endpoint.strip_edges() != ""

func add_recent_project(path: String) -> void:
	var normalized := path.strip_edges().replace("\\", "/").simplify_path().rstrip("/")
	if normalized == "":
		return
	recent_projects.erase(normalized)
	recent_projects.push_front(normalized)
	if recent_projects.size() > MAX_RECENT:
		recent_projects.resize(MAX_RECENT)
	save_settings()
	settings_changed.emit()

func remove_recent_project(path: String) -> void:
	recent_projects.erase(path)
	save_settings()
	settings_changed.emit()

# Resolves the current `model_tier` setting into a concrete ModelProfile —
# "auto" guesses from `model`'s name, anything else is taken literally.
func resolved_profile() -> ModelProfile:
	var tier: ModelProfile.Tier
	if model_tier.strip_edges() == "" or model_tier.strip_edges().to_lower() == "auto":
		tier = ModelProfile.resolve_tier_from_model_name(model)
	else:
		tier = ModelProfile.tier_from_string(model_tier)
	return ModelProfile.for_tier(tier)
