class_name StatusBar
extends PanelContainer

var _status: Label
var _elapsed: Label
var _project: Label
var _model: Label
var _tools: Label

var _task_start_msec: int = -1

func _ready() -> void:
	custom_minimum_size.y = 26
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 16)
	add_child(h)

	_status = _mk("Ready")
	h.add_child(_status)

	_elapsed = _mk("")
	h.add_child(_elapsed)

	var sp := Control.new()
	sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(sp)

	_tools = _mk("0 tools")
	h.add_child(_tools)

	_model = _mk("—")
	h.add_child(_model)

	_project = _mk("No project")
	h.add_child(_project)

	set_process(true)
	apply_theme()

func _mk(text: String) -> Label:
	var l := Label.new()
	l.text = text
	ThemeManager.set_font(l, 11)
	return l

func set_status(text: String) -> void:
	_status.text = text

func set_project(name_or_path: String) -> void:
	_project.text = name_or_path if name_or_path != "" else "No project"

func set_model(text: String) -> void:
	_model.text = text

func set_tool_count(n: int) -> void:
	_tools.text = "%d tool%s" % [n, "" if n == 1 else "s"]

# --- elapsed-time chip for the current agent task ---------------------

func start_timer() -> void:
	_task_start_msec = Time.get_ticks_msec()

func stop_timer() -> void:
	_task_start_msec = -1
	_elapsed.text = ""

func _process(_delta: float) -> void:
	if _task_start_msec < 0:
		return
	var secs := (Time.get_ticks_msec() - _task_start_msec) / 1000.0
	_elapsed.text = "⏱ %s" % _format_elapsed(secs)

static func _format_elapsed(secs: float) -> String:
	if secs < 60.0:
		return "%.0fs" % secs
	var total := int(secs)
	var m := total / 60
	var s := total % 60
	return "%dm %02ds" % [m, s]

func apply_theme() -> void:
	var style := StyleBoxFlat.new()
	style.bg_color = ThemeManager.c("bg_panel")
	style.border_width_top = 1
	style.border_color = ThemeManager.c("border")
	style.content_margin_left = 10
	style.content_margin_right = 10
	style.content_margin_top = 3
	style.content_margin_bottom = 3
	add_theme_stylebox_override("panel", style)
	for l in [_status, _elapsed, _project, _model, _tools]:
		l.add_theme_color_override("font_color", ThemeManager.c("text_dim"))
