class_name ChatMessage
extends PanelContainer

enum Role { USER, ASSISTANT, SYSTEM, ERROR, TOOL }

const ROLE_LABEL := {
	Role.USER: "You",
	Role.ASSISTANT: "Agent",
	Role.SYSTEM: "System",
	Role.ERROR: "Error",
	Role.TOOL: "Tool",
}

var role: Role = Role.SYSTEM
var _body: VBoxContainer
var _content: RichTextLabel
var _copy_btn: Button

static func create_text(p_role: Role, text: String) -> ChatMessage:
	var m := ChatMessage.new()
	m.role = p_role
	m._build()
	m.append_text(text)
	return m

static func create_tool(tool_name: String, args: Dictionary) -> ChatMessage:
	var m := ChatMessage.new()
	m.role = Role.TOOL
	m._build()
	var args_text := JSON.stringify(args)
	if args_text.length() > 400:
		args_text = args_text.substr(0, 400) + "..."
	m.append_text("[b]→ %s[/b]\n[color=#9aa4b2]%s[/color]" % [
		_escape(tool_name), _escape(args_text)
	])
	return m

func append_text(text: String) -> void:
	_content.append_text(text)

func append_tool_result(result: ToolResult) -> void:
	_append_result_text(result.describe(), result.success)

# Used when rebuilding the chat log from a saved session (ChatPanel.
# load_conversation) — only the plain result string survives there, no
# live ToolResult to ask. Success is inferred from ToolResult.describe()'s
# own "ERROR[...]" prefix on failure, which is reliable since that prefix
# is the only place describe() ever adds it.
func append_replayed_result(text: String) -> void:
	_append_result_text(text, not text.begins_with("ERROR["))

func _append_result_text(text: String, success: bool) -> void:
	var color := "#7fd18c" if success else "#ef7a7a"
	var body := text
	if body.length() > 3000:
		body = body.substr(0, 3000) + "\n… (truncated)"
	_content.append_text("\n[color=%s]← result[/color]\n[color=#c8c8c8]%s[/color]" % [
		color, _escape(body)
	])

static func _escape(s: String) -> String:
	return s.replace("[", "[lb]")

func _role_bg() -> Color:
	match role:
		Role.USER:
			return ThemeManager.c("user_bubble")
		Role.ASSISTANT:
			return ThemeManager.c("assistant_bubble")
		Role.TOOL:
			return ThemeManager.c("tool_bubble")
		Role.SYSTEM:
			return ThemeManager.c("system_bubble")
		Role.ERROR:
			var e := ThemeManager.c("error")
			return Color(e.r, e.g, e.b, 0.14) if ThemeManager.is_dark() else Color(e.r, e.g, e.b, 0.10)
		_:
			return ThemeManager.c("bg_panel_alt")

func _header_color() -> Color:
	match role:
		Role.USER:
			return ThemeManager.c("accent")
		Role.ERROR:
			return ThemeManager.c("error")
		Role.SYSTEM:
			return ThemeManager.c("text_mute")
		_:
			return ThemeManager.c("text_dim")

func _build() -> void:
	var style := StyleBoxFlat.new()
	style.bg_color = _role_bg()
	style.set_corner_radius_all(12)
	style.content_margin_left = 14
	style.content_margin_right = 14
	style.content_margin_top = 10
	style.content_margin_bottom = 10
	style.shadow_color = Color(0, 0, 0, 0.18 if ThemeManager.is_dark() else 0.05)
	style.shadow_size = 2
	style.shadow_offset = Vector2(0, 1)
	if role == Role.ERROR:
		style.border_width_left = 3
		style.border_color = ThemeManager.c("error")
	add_theme_stylebox_override("panel", style)

	_body = VBoxContainer.new()
	_body.add_theme_constant_override("separation", 4)
	add_child(_body)

	var header_row := HBoxContainer.new()
	header_row.add_theme_constant_override("separation", 6)
	_body.add_child(header_row)

	var header := Label.new()
	header.text = str(ROLE_LABEL.get(role, "?"))
	ThemeManager.set_font(header, 11)
	header.add_theme_color_override("font_color", _header_color())
	header_row.add_child(header)

	var sp := Control.new()
	sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header_row.add_child(sp)

	_copy_btn = Button.new()
	_copy_btn.text = "Copy"
	_copy_btn.tooltip_text = "Copy this message to the clipboard"
	ThemeManager.set_font(_copy_btn, 10)
	_copy_btn.add_theme_color_override("font_color", ThemeManager.c("text_mute"))
	_copy_btn.add_theme_color_override("font_hover_color", ThemeManager.c("accent"))
	_copy_btn.add_theme_color_override("font_pressed_color", ThemeManager.c("accent"))
	var empty := StyleBoxEmpty.new()
	_copy_btn.add_theme_stylebox_override("normal", empty)
	_copy_btn.add_theme_stylebox_override("hover", empty)
	_copy_btn.add_theme_stylebox_override("pressed", empty)
	_copy_btn.add_theme_stylebox_override("focus", empty)
	_copy_btn.pressed.connect(_on_copy)
	header_row.add_child(_copy_btn)

	_content = RichTextLabel.new()
	_content.bbcode_enabled = true
	_content.fit_content = true
	_content.scroll_active = false
	_content.selection_enabled = true
	_content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_content.add_theme_color_override("default_color", ThemeManager.c("text"))
	_body.add_child(_content)

func _on_copy() -> void:
	if _content == null:
		return
	var body := _content.get_parsed_text()
	var label := str(ROLE_LABEL.get(role, "?"))
	DisplayServer.clipboard_set("[%s]\n%s" % [label, body])
	if _copy_btn != null:
		_copy_btn.text = "Copied ✓"
		await get_tree().create_timer(1.2).timeout
		if is_instance_valid(_copy_btn):
			_copy_btn.text = "Copy"
