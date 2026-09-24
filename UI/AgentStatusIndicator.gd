class_name AgentStatusIndicator
extends PanelContainer

# A "thinking…" style bubble that lives inline in the chat log while the
# agent is working. Updates every frame so the elapsed time and dot
# animation are always current — the point is to make it visually obvious
# the agent is alive and progressing, not stalled.

var _label: Label
var _dot: Label
var _start_msec: int = 0
var _phase_text: String = "Thinking"

func _ready() -> void:
	var style := StyleBoxFlat.new()
	style.bg_color = ThemeManager.c("assistant_bubble")
	style.set_corner_radius_all(10)
	style.content_margin_left = 12
	style.content_margin_right = 12
	style.content_margin_top = 7
	style.content_margin_bottom = 7
	add_theme_stylebox_override("panel", style)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 7)
	add_child(row)

	_dot = Label.new()
	_dot.text = "●"
	ThemeManager.set_font(_dot, 10)
	_dot.add_theme_color_override("font_color", ThemeManager.c("accent"))
	row.add_child(_dot)
	_pulse_dot()

	_label = Label.new()
	ThemeManager.set_font(_label, 12)
	_label.add_theme_color_override("font_color", ThemeManager.c("text_dim"))
	row.add_child(_label)

	_start_msec = Time.get_ticks_msec()
	set_process(true)
	_refresh()

func set_phase(text: String) -> void:
	_phase_text = text
	_refresh()

func _process(_delta: float) -> void:
	_refresh()

func _refresh() -> void:
	if _label == null:
		return
	var elapsed_ms := Time.get_ticks_msec() - _start_msec
	var dot_count := int(elapsed_ms / 400) % 4
	var dots := ".".repeat(dot_count)
	_label.text = "%s%s   %s" % [_phase_text, dots, _format_elapsed(elapsed_ms / 1000.0)]

func _pulse_dot() -> void:
	var tween := create_tween()
	tween.set_loops()
	tween.tween_property(_dot, "modulate:a", 0.25, 0.6).set_trans(Tween.TRANS_SINE)
	tween.tween_property(_dot, "modulate:a", 1.0, 0.6).set_trans(Tween.TRANS_SINE)

static func _format_elapsed(secs: float) -> String:
	if secs < 60.0:
		return "%.0fs" % secs
	var total := int(secs)
	var m := total / 60
	var s := total % 60
	return "%dm %02ds" % [m, s]
