class_name DiffDialog
extends Window

# A change-history viewer: newest change at the top of the left column,
# each row carrying its own Revert button. Selecting a row shows a
# unified, colored diff (before → after) on the right.
#
# Reverting a row undoes that change AND every change newer than it, in
# LIFO order — the only correct way to walk the checkpoint stack back.
# So the newest row reverts one change (identical to the top-bar Revert
# button); the 3rd-newest row reverts three.

signal reverted(reverted_count: int, message: String)

const MAX_DIFF_LINES := 3000
const CONTEXT := 3   # unchanged lines kept around each hunk

var _checkpoint_manager: CheckpointManager
var _entries: Array = []       # newest-first
var _row_panels: Array = []    # parallel to _entries, for selection restyle
var _selected_index: int = -1

var _root: HSplitContainer
var _list_scroll: ScrollContainer
var _list_box: VBoxContainer
var _diff_view: RichTextLabel
var _status_label: Label

func _init() -> void:
	title = "Change history"
	size = Vector2i(1000, 660)
	unresizable = false
	# Window.visible defaults to true; the dialog must only appear when the
	# user asks for it.
	visible = false
	close_requested.connect(hide)

func set_checkpoint_manager(cm: CheckpointManager) -> void:
	_checkpoint_manager = cm

func _ready() -> void:
	hide()
	_build_ui()

func _build_ui() -> void:
	_root = HSplitContainer.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.split_offset = 400
	add_child(_root)

	# --- left column: list of changes --------------------------------------
	var left := VBoxContainer.new()
	left.add_theme_constant_override("separation", 0)
	left.custom_minimum_size.x = 340
	_root.add_child(left)

	left.add_child(_make_header("Changes", true))

	_list_scroll = ScrollContainer.new()
	_list_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_list_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	left.add_child(_list_scroll)

	var pad := MarginContainer.new()
	pad.add_theme_constant_override("margin_left", 8)
	pad.add_theme_constant_override("margin_right", 8)
	pad.add_theme_constant_override("margin_top", 8)
	pad.add_theme_constant_override("margin_bottom", 8)
	pad.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list_scroll.add_child(pad)

	_list_box = VBoxContainer.new()
	_list_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list_box.add_theme_constant_override("separation", 6)
	pad.add_child(_list_box)

	# --- right column: diff -------------------------------------------------
	var right := VBoxContainer.new()
	right.add_theme_constant_override("separation", 0)
	_root.add_child(right)

	right.add_child(_make_header("Diff", false))

	_diff_view = RichTextLabel.new()
	_diff_view.bbcode_enabled = true
	_diff_view.scroll_active = true
	_diff_view.selection_enabled = true
	_diff_view.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_diff_view.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ThemeManager.set_font(_diff_view, 12, "normal_font_size")
	_diff_view.add_theme_color_override("default_color", ThemeManager.c("text"))
	right.add_child(_diff_view)

func _make_header(title_text: String, with_refresh: bool) -> PanelContainer:
	var header := PanelContainer.new()
	header.custom_minimum_size.y = 40
	var s := StyleBoxFlat.new()
	s.bg_color = ThemeManager.c("bg_panel")
	s.border_width_bottom = 1
	s.border_color = ThemeManager.c("border")
	s.content_margin_left = 14
	s.content_margin_right = 14
	s.content_margin_top = 8
	s.content_margin_bottom = 8
	header.add_theme_stylebox_override("panel", s)

	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 8)
	header.add_child(h)

	var t := Label.new()
	t.text = title_text
	ThemeManager.set_font(t, 13)
	h.add_child(t)

	var sp := Control.new()
	sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(sp)

	if with_refresh:
		var refresh_btn := Button.new()
		refresh_btn.text = "Refresh"
		ThemeManager.set_font(refresh_btn, 11)
		refresh_btn.pressed.connect(refresh)
		h.add_child(refresh_btn)
	elif _status_label == null:
		# Right-column header holds the status label.
		_status_label = Label.new()
		ThemeManager.set_font(_status_label, 12)
		_status_label.add_theme_color_override("font_color", ThemeManager.c("text_dim"))
		_status_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		_status_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		h.add_child(_status_label)

	return header

# --- public API ---------------------------------------------------------

func open() -> void:
	refresh()
	popup_centered()

func refresh() -> void:
	if _checkpoint_manager == null:
		return
	for c in _list_box.get_children():
		c.queue_free()
	_row_panels.clear()
	_entries = _checkpoint_manager.entries_newest_first()
	_selected_index = -1

	if _entries.is_empty():
		_status_label.text = "No changes recorded yet."
		_diff_view.clear()
		var mute := "#" + ThemeManager.c("text_mute").to_html(false)
		_diff_view.append_text(
			"[color=%s]Nothing to show yet. Every file change the agent makes will appear here.[/color]" % mute
		)
		return

	for i in _entries.size():
		var panel := _build_row(i, _entries[i])
		_list_box.add_child(panel)
		_row_panels.append(panel)

	_status_label.text = "%d change(s)." % _entries.size()
	# Auto-select the newest change so the dialog isn't blank on open.
	_select_index(0)

func apply_theme() -> void:
	theme = ThemeManager.theme
	if visible:
		refresh()

# --- row construction ---------------------------------------------------

func _build_row(index: int, entry: CheckpointManager.Entry) -> PanelContainer:
	var panel := PanelContainer.new()
	panel.mouse_filter = Control.MOUSE_FILTER_PASS
	panel.add_theme_stylebox_override("panel", _row_style(false))

	var margin := MarginContainer.new()
	margin.mouse_filter = Control.MOUSE_FILTER_PASS
	margin.add_theme_constant_override("margin_left", 10)
	margin.add_theme_constant_override("margin_right", 8)
	margin.add_theme_constant_override("margin_top", 8)
	margin.add_theme_constant_override("margin_bottom", 8)
	panel.add_child(margin)

	var hbox := HBoxContainer.new()
	hbox.mouse_filter = Control.MOUSE_FILTER_PASS
	hbox.add_theme_constant_override("separation", 8)
	margin.add_child(hbox)

	var info := VBoxContainer.new()
	info.mouse_filter = Control.MOUSE_FILTER_PASS
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	info.add_theme_constant_override("separation", 2)
	hbox.add_child(info)

	var title := Label.new()
	title.mouse_filter = Control.MOUSE_FILTER_PASS
	title.text = "%s  •  %s" % [entry.tool_name, entry.raw_path]
	ThemeManager.set_font(title, 12)
	title.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	info.add_child(title)

	var sub := Label.new()
	sub.mouse_filter = Control.MOUSE_FILTER_PASS
	sub.text = "%s  •  %s" % [_format_ago(entry.timestamp), _delta_summary(entry)]
	ThemeManager.set_font(sub, 10)
	sub.add_theme_color_override("font_color", ThemeManager.c("text_mute"))
	sub.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	info.add_child(sub)

	var revert_btn := Button.new()
	revert_btn.text = "Revert"
	revert_btn.tooltip_text = "Undo this change and every change made after it"
	ThemeManager.set_font(revert_btn, 11)
	revert_btn.pressed.connect(func(): _on_revert_pressed(index))
	hbox.add_child(revert_btn)

	# Any click on the row (except on the Revert button, which consumes its
	# own events) selects that entry and shows its diff.
	panel.gui_input.connect(func(ev: InputEvent):
		if ev is InputEventMouseButton:
			var mb := ev as InputEventMouseButton
			if mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
				_select_index(index)
	)
	return panel

func _row_style(selected: bool) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.set_corner_radius_all(8)
	s.content_margin_left = 4
	s.content_margin_right = 4
	s.content_margin_top = 2
	s.content_margin_bottom = 2
	if selected:
		var a := ThemeManager.c("accent")
		s.bg_color = Color(a.r, a.g, a.b, 0.14)
		s.border_color = a
		s.set_border_width_all(1)
	else:
		s.bg_color = ThemeManager.c("bg_panel_alt")
		s.border_color = ThemeManager.c("border")
		s.set_border_width_all(1)
	return s

# --- selection / diff rendering -----------------------------------------

func _select_index(index: int) -> void:
	if index < 0 or index >= _entries.size():
		return
	_selected_index = index
	for i in _row_panels.size():
		var p: PanelContainer = _row_panels[i]
		if is_instance_valid(p):
			p.add_theme_stylebox_override("panel", _row_style(i == index))
	_show_diff(_entries[index])

func _show_diff(entry: CheckpointManager.Entry) -> void:
	_diff_view.clear()
	_status_label.text = "%s  •  %s" % [entry.tool_name, entry.raw_path]
	_diff_view.append_text(_render_diff(entry.before_content, entry.after_content))

func _on_revert_pressed(index: int) -> void:
	if _checkpoint_manager == null:
		return
	var res: Dictionary = _checkpoint_manager.revert_to_newest_index(index)
	if bool(res.get("success", false)):
		reverted.emit(int(res.get("reverted", 0)), str(res.get("message", "")))
		refresh()
	else:
		_status_label.text = "Revert failed: " + str(res.get("message", "unknown"))

# --- helpers ------------------------------------------------------------

static func _format_ago(ts: int) -> String:
	var now := int(Time.get_unix_time_from_system())
	var secs := maxi(0, now - ts)
	if secs < 60:
		return "%ds ago" % secs
	if secs < 3600:
		return "%dm ago" % (secs / 60)
	if secs < 86400:
		return "%dh ago" % (secs / 3600)
	return "%dd ago" % (secs / 86400)

static func _delta_summary(entry: CheckpointManager.Entry) -> String:
	if not entry.existed_before:
		return "created"
	if not entry.existed_after:
		return "deleted"
	var a := _split_lines(entry.before_content).size()
	var b := _split_lines(entry.after_content).size()
	var diff := b - a
	if diff == 0:
		return "%d lines" % a
	return "%d → %d lines (%s)" % [a, b, ("+" + str(diff)) if diff > 0 else str(diff)]

# Splitting on "\n" turns a trailing newline into a phantom empty last
# element, which would make "line1\n" and "line1" look like they differ
# by one line. Drop that trailing empty element — but keep genuinely empty
# interiors so the diff still shows the right line count.
static func _split_lines(s: String) -> PackedStringArray:
	if s == "":
		return PackedStringArray()
	var lines := s.split("\n")
	if lines.size() > 0 and lines[lines.size() - 1] == "":
		lines = lines.slice(0, lines.size() - 1)
	return lines

func _render_diff(before: String, after: String) -> String:
	if before == after:
		var mute := "#" + ThemeManager.c("text_mute").to_html(false)
		return "[color=%s](no content change)[/color]" % mute

	var a := _split_lines(before)
	var b := _split_lines(after)
	var err := "#" + ThemeManager.c("error").to_html(false)
	if a.size() > MAX_DIFF_LINES or b.size() > MAX_DIFF_LINES:
		return (
			"[color=%s]File too large for inline diff — %d and %d lines, cap is %d. "
			+ "Use Revert to undo, or open the file to inspect it directly.[/color]"
		) % [err, a.size(), b.size(), MAX_DIFF_LINES]

	var ops := _lcs_diff(a, b)
	var n := ops.size()

	# Mark which op indices fall within CONTEXT lines of a change, so we
	# can collapse long unchanged stretches into "…N unchanged lines…".
	var keep := PackedByteArray()
	keep.resize(n)
	for i in n:
		keep[i] = 0
	for i in n:
		if str((ops[i] as Dictionary).get("type", "")) != "same":
			for k in range(maxi(0, i - CONTEXT), mini(n, i + CONTEXT + 1)):
				keep[k] = 1

	var col_add := "#" + ThemeManager.c("success").to_html(false)
	var col_del := "#" + ThemeManager.c("error").to_html(false)
	var col_ctx := "#" + ThemeManager.c("text_mute").to_html(false)

	var out := PackedStringArray()
	var skipped := 0
	for i in n:
		var op: Dictionary = ops[i]
		if keep[i] == 1:
			if skipped > 0:
				out.append("[color=%s]… %d unchanged line(s) …[/color]" % [col_ctx, skipped])
				skipped = 0
			var raw := str(op.get("text", "")).replace("[", "[lb]")
			match str(op.get("type", "same")):
				"add":
					out.append("[color=%s]+ %s[/color]" % [col_add, raw])
				"del":
					out.append("[color=%s]- %s[/color]" % [col_del, raw])
				_:
					out.append("[color=%s]  %s[/color]" % [col_ctx, raw])
		else:
			skipped += 1
	if skipped > 0:
		out.append("[color=%s]… %d unchanged line(s) …[/color]" % [col_ctx, skipped])

	if out.is_empty():
		return "[color=%s](no visible changes)[/color]" % col_ctx
	return "\n".join(out)

# Flat-buffer LCS: dp[i * stride + j] = LCS length of a[0..i-1] vs b[0..j-1].
# The flat PackedInt32Array avoids the CoW hazard of Array-of-PackedInt32Array
# (which would silently drop writes on some Godot builds) and keeps the
# whole table in one contiguous allocation.
static func _lcs_diff(a: PackedStringArray, b: PackedStringArray) -> Array:
	var n := a.size()
	var m := b.size()
	var stride := m + 1
	var dp := PackedInt32Array()
	dp.resize((n + 1) * stride)

	for i in range(1, n + 1):
		for j in range(1, m + 1):
			var idx := i * stride + j
			if a[i - 1] == b[j - 1]:
				dp[idx] = dp[(i - 1) * stride + (j - 1)] + 1
			else:
				dp[idx] = maxi(dp[(i - 1) * stride + j], dp[i * stride + (j - 1)])

	# Backtrack from (n, m), pushing each resolved op to the front so the
	# resulting array reads top-to-bottom like a normal diff.
	var out: Array = []
	var i := n
	var j := m
	while i > 0 or j > 0:
		if i > 0 and j > 0 and a[i - 1] == b[j - 1]:
			out.push_front({"type": "same", "text": a[i - 1]})
			i -= 1
			j -= 1
		elif j > 0 and (i == 0 or dp[i * stride + (j - 1)] >= dp[(i - 1) * stride + j]):
			out.push_front({"type": "add", "text": b[j - 1]})
			j -= 1
		else:
			out.push_front({"type": "del", "text": a[i - 1]})
			i -= 1
	return out
