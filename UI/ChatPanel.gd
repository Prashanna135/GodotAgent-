class_name ChatPanel
extends VBoxContainer

signal message_submitted(text: String)

var _header: PanelContainer
var _scroll: ScrollContainer
var _messages: VBoxContainer
var _input: TextEdit
var _input_bar: PanelContainer
var _send_btn: Button
var _copy_btn: Button
var _last_tool: ChatMessage = null
var _status_indicator: AgentStatusIndicator = null

# Plain-text mirror of the chat log. Kept in sync as messages are added so
# "Copy All" can hand the user the entire conversation in one paste instead
# of forcing a per-bubble mouse-select copy.
var _transcript: PackedStringArray = PackedStringArray()

func _ready() -> void:
	add_theme_constant_override("separation", 0)

	# --- header -------------------------------------------------------------
	_header = PanelContainer.new()
	_header.custom_minimum_size.y = 36
	var hl := HBoxContainer.new()
	hl.add_theme_constant_override("separation", 8)
	_header.add_child(hl)

	var title := Label.new()
	title.text = "Chat"
	ThemeManager.set_font(title, 13)
	hl.add_child(title)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hl.add_child(spacer)

	_copy_btn = Button.new()
	_copy_btn.text = "Copy All"
	_copy_btn.tooltip_text = "Copy the entire conversation to the clipboard as plain text"
	ThemeManager.set_font(_copy_btn, 11)
	_copy_btn.pressed.connect(_on_copy_all)
	hl.add_child(_copy_btn)

	var clear_btn := Button.new()
	clear_btn.text = "Clear"
	ThemeManager.set_font(clear_btn, 11)
	clear_btn.pressed.connect(clear)
	hl.add_child(clear_btn)
	add_child(_header)

	# --- message list -------------------------------------------------------
	_scroll = ScrollContainer.new()
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(_scroll)

	_messages = VBoxContainer.new()
	_messages.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_messages.add_theme_constant_override("separation", 10)
	_scroll.add_child(_messages)

	# --- input bar ----------------------------------------------------------
	_input_bar = PanelContainer.new()
	_input_bar.custom_minimum_size.y = 104
	add_child(_input_bar)
	var iv := VBoxContainer.new()
	iv.add_theme_constant_override("separation", 8)
	_input_bar.add_child(iv)

	_input = TextEdit.new()
	_input.placeholder_text = "Describe the coding task…  (Enter to send, Shift+Enter for newline)"
	_input.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	_input.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_input.custom_minimum_size.y = 60
	_input.gui_input.connect(_on_input_gui_input)
	iv.add_child(_input)

	var bottom := HBoxContainer.new()
	bottom.add_theme_constant_override("separation", 8)
	var hint := Label.new()
	hint.text = "Enter = send  •  Shift+Enter = newline"
	ThemeManager.set_font(hint, 10)
	hint.add_theme_color_override("font_color", ThemeManager.c("text_mute"))
	bottom.add_child(hint)
	var sp := Control.new()
	sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bottom.add_child(sp)
	_send_btn = Button.new()
	_send_btn.text = "Send"
	_send_btn.pressed.connect(_on_send)
	bottom.add_child(_send_btn)
	iv.add_child(bottom)

	apply_theme()

func _on_input_gui_input(event: InputEvent) -> void:
	if event is InputEventKey:
		var k := event as InputEventKey
		if k.pressed and not k.echo and k.keycode == KEY_ENTER and not k.shift_pressed:
			_input.accept_event()
			_on_send()

func _on_send() -> void:
	var text := _input.text.strip_edges()
	if text == "":
		return
	_input.text = ""
	message_submitted.emit(text)

# --- transcript --------------------------------------------------------

# Strips real BBCode tags ([b], [/b], [color=red], [lb]) while leaving
# bracket content that isn't a tag intact — most importantly JSON arrays
# like ["a","b"] and index expressions like [i] or [get_rid()], which the
# old catch-all \[[^\]]*\] regex was silently eating out of the transcript.
# A tag here means: `[`, optional `/`, a lowercase identifier, optional
# `=value`, then `]`. Anything starting with a quote, digit, or uppercase,
# or containing punctuation the identifier set doesn't cover, is left
# alone — so [i] is stripped but ["a"] and [0] and [TOOL] are not.
static func _strip_bbcode(s: String) -> String:
	var re := RegEx.new()
	re.compile("\\[/?[a-z][a-z0-9_]*(?:=[^\\]]*)?\\]")
	return re.sub(s, "", true)

func _append_transcript(role: String, text: String) -> void:
	_transcript.append("[%s]  %s" % [role, _strip_bbcode(text)])

func _on_copy_all() -> void:
	if _transcript.is_empty():
		_flash_copy("Nothing to copy")
		return
	DisplayServer.clipboard_set("\n\n".join(_transcript))
	_flash_copy("Copied ✓")

func _flash_copy(msg: String) -> void:
	if _copy_btn == null:
		return
	_copy_btn.text = msg
	await get_tree().create_timer(1.4).timeout
	if is_instance_valid(_copy_btn):
		_copy_btn.text = "Copy All"

# --- message API -------------------------------------------------------

func add_user(text: String) -> void:
	_add(ChatMessage.create_text(ChatMessage.Role.USER, text))
	_append_transcript("You", text)

func add_assistant(text: String) -> void:
	if text.strip_edges() == "":
		return
	_add(ChatMessage.create_text(ChatMessage.Role.ASSISTANT, text))
	_append_transcript("Agent", text)

func add_system(text: String) -> void:
	_add(ChatMessage.create_text(ChatMessage.Role.SYSTEM, text))
	_append_transcript("System", text)

func add_error(text: String) -> void:
	_add(ChatMessage.create_text(ChatMessage.Role.ERROR, text))
	_append_transcript("Error", text)

func add_tool_started(tool_name: String, args: Dictionary) -> void:
	_last_tool = ChatMessage.create_tool(tool_name, args)
	_add(_last_tool)
	_transcript.append("[Tool]  → %s  %s" % [tool_name, JSON.stringify(args)])

func add_tool_finished(result: ToolResult) -> void:
	if _last_tool != null:
		_last_tool.append_tool_result(result)
		_last_tool = null
	var body := result.describe()
	if body.length() > 2000:
		body = body.substr(0, 2000) + "…"
	_transcript.append("[Tool result]  %s" % body)
	_scroll_to_bottom()

# Rebuilds the visual log from a restored Conversation (see SessionManager
# and MainWindow._resume_session). Walks messages in order, pairing each
# assistant tool_call with the TOOL-role message that follows it — same
# shape a live run produces via add_tool_started/add_tool_finished, just
# built from saved text instead of a live ToolResult.
func load_conversation(conversation: Conversation) -> void:
	clear()
	var pending: Dictionary = {}   # tool_call_id -> ChatMessage
	for m in conversation.messages:
		match m.role:
			Conversation.Role.USER:
				add_user(m.content)
			Conversation.Role.ASSISTANT:
				if m.content.strip_edges() != "":
					add_assistant(m.content)
				for call_v in m.tool_calls:
					if typeof(call_v) != TYPE_DICTIONARY:
						continue
					var call: Dictionary = call_v
					var fn_v: Variant = call.get("function", {})
					var fn: Dictionary = fn_v if typeof(fn_v) == TYPE_DICTIONARY else {}
					var tool_name := str(fn.get("name", ""))
					var args_v: Variant = JSON.parse_string(str(fn.get("arguments", "{}")))
					var args: Dictionary = args_v if typeof(args_v) == TYPE_DICTIONARY else {}
					var bubble := ChatMessage.create_tool(tool_name, args)
					_add(bubble)
					_transcript.append("[Tool]  → %s  %s" % [tool_name, JSON.stringify(args)])
					pending[str(call.get("id", ""))] = bubble
			Conversation.Role.TOOL:
				var bubble: ChatMessage = pending.get(m.tool_call_id, null)
				if bubble != null:
					pending.erase(m.tool_call_id)
				else:
					# Orphaned result (shouldn't normally happen) — still
					# show it rather than silently dropping history.
					bubble = ChatMessage.create_tool(m.name, {})
					_add(bubble)
				bubble.append_replayed_result(m.content)
				var body := m.content
				if body.length() > 2000:
					body = body.substr(0, 2000) + "…"
				_transcript.append("[Tool result]  %s" % body)
			Conversation.Role.SYSTEM:
				add_system(m.content)
	_scroll_to_bottom()

# --- live "thinking…" indicator ---------------------------------------

func show_status_indicator() -> void:
	hide_status_indicator()
	_status_indicator = AgentStatusIndicator.new()
	_messages.add_child(_status_indicator)
	_scroll_to_bottom()

func set_status_phase(text: String) -> void:
	if _status_indicator != null:
		_status_indicator.set_phase(text)

func hide_status_indicator() -> void:
	if _status_indicator != null:
		_status_indicator.queue_free()
		_status_indicator = null

func clear() -> void:
	for child in _messages.get_children():
		child.queue_free()
	_last_tool = null
	_status_indicator = null
	_transcript.clear()

func _add(msg: ChatMessage) -> void:
	_messages.add_child(msg)
	if _status_indicator != null and is_instance_valid(_status_indicator):
		# Keep the indicator pinned to the bottom of the log.
		_messages.move_child(msg, _status_indicator.get_index())
	_scroll_to_bottom()

func _scroll_to_bottom() -> void:
	if not AppSettings.auto_scroll_chat:
		return
	await get_tree().process_frame
	var vs := _scroll.get_v_scroll_bar()
	_scroll.scroll_vertical = int(vs.max_value)

func apply_theme() -> void:
	var header_style := StyleBoxFlat.new()
	header_style.bg_color = ThemeManager.c("bg_panel")
	header_style.border_width_bottom = 1
	header_style.border_color = ThemeManager.c("border")
	header_style.content_margin_left = 14
	header_style.content_margin_right = 10
	header_style.content_margin_top = 5
	header_style.content_margin_bottom = 5
	_header.add_theme_stylebox_override("panel", header_style)

	var input_style := StyleBoxFlat.new()
	input_style.bg_color = ThemeManager.c("bg_panel")
	input_style.border_width_top = 1
	input_style.border_color = ThemeManager.c("border")
	input_style.content_margin_left = 14
	input_style.content_margin_right = 14
	input_style.content_margin_top = 10
	input_style.content_margin_bottom = 10
	_input_bar.add_theme_stylebox_override("panel", input_style)

	var scroll_bg := StyleBoxFlat.new()
	scroll_bg.bg_color = ThemeManager.c("bg")
	_scroll.add_theme_stylebox_override("panel", scroll_bg)

	if _input != null:
		var input_box := StyleBoxFlat.new()
		input_box.bg_color = ThemeManager.c("bg_input")
		input_box.border_color = ThemeManager.c("border")
		input_box.set_border_width_all(1)
		input_box.set_corner_radius_all(10)
		input_box.content_margin_left = 12
		input_box.content_margin_right = 12
		input_box.content_margin_top = 8
		input_box.content_margin_bottom = 8
		var input_focus := input_box.duplicate() as StyleBoxFlat
		input_focus.border_color = ThemeManager.c("accent")
		_input.add_theme_stylebox_override("normal", input_box)
		_input.add_theme_stylebox_override("focus", input_focus)
		_input.add_theme_color_override("font_placeholder_color", ThemeManager.c("text_mute"))
