class_name ActivityPanel
extends VBoxContainer

var _header: PanelContainer
var _log: RichTextLabel

func _ready() -> void:
	add_theme_constant_override("separation", 0)

	_header = PanelContainer.new()
	_header.custom_minimum_size.y = 34
	var hl := HBoxContainer.new()
	hl.add_theme_constant_override("separation", 8)
	_header.add_child(hl)
	var title := Label.new()
	title.text = "Activity"
	ThemeManager.set_font(title, 12)
	hl.add_child(title)
	var sp := Control.new()
	sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hl.add_child(sp)
	var clear_btn := Button.new()
	clear_btn.text = "Clear"
	ThemeManager.set_font(clear_btn, 11)
	clear_btn.pressed.connect(clear)
	hl.add_child(clear_btn)
	add_child(_header)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(scroll)

	_log = RichTextLabel.new()
	_log.bbcode_enabled = true
	_log.scroll_active = false
	_log.selection_enabled = true
	_log.fit_content = true
	_log.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_log)

	apply_theme()

func log_tool_started(tool_name: String, args: Dictionary) -> void:
	var t := Time.get_time_string_from_system()
	var preview := JSON.stringify(args)
	if preview.length() > 120:
		preview = preview.substr(0, 120) + "…"
	_log.append_text("[color=#6a7684]%s[/color]  [b]→ %s[/b]  [color=#8a94a0]%s[/color]\n" % [
		t, _esc(tool_name), _esc(preview)
	])

func log_tool_finished(tool_name: String, result: ToolResult) -> void:
	var t := Time.get_time_string_from_system()
	var color := "#7fd18c" if result.success else "#ef7a7a"
	var status := "ok" if result.success else "fail"
	_log.append_text("[color=#6a7684]%s[/color]  [color=%s]← %s (%s)[/color]\n" % [
		t, color, _esc(tool_name), status
	])

func log_info(text: String) -> void:
	var t := Time.get_time_string_from_system()
	_log.append_text("[color=#6a7684]%s[/color]  [color=#9aa4b2]%s[/color]\n" % [t, _esc(text)])

func log_error(text: String) -> void:
	var t := Time.get_time_string_from_system()
	_log.append_text("[color=#6a7684]%s[/color]  [color=#ef7a7a]%s[/color]\n" % [t, _esc(text)])

func clear() -> void:
	_log.clear()

func _esc(s: String) -> String:
	return s.replace("[", "[lb]")

func apply_theme() -> void:
	if _header != null:
		var header_style := StyleBoxFlat.new()
		header_style.bg_color = ThemeManager.c("bg_panel_alt")
		header_style.border_width_top = 1
		header_style.border_color = ThemeManager.c("border")
		header_style.content_margin_left = 14
		header_style.content_margin_right = 10
		header_style.content_margin_top = 5
		header_style.content_margin_bottom = 5
		_header.add_theme_stylebox_override("panel", header_style)
	if _log != null:
		_log.add_theme_color_override("default_color", ThemeManager.c("text"))
