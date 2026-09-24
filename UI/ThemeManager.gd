class_name ThemeManagerScript
extends Node

signal theme_changed()

enum Mode { DARK, LIGHT }

var mode: Mode = Mode.DARK
var theme: Theme = Theme.new()
var colors: Dictionary = {}

# --- global text scaling --------------------------------------------------
# One multiplier applied to every font size in the UI. Base theme sizes in
# _rebuild_theme() are scaled directly; per-node overrides are routed through
# set_font(), which remembers each node's *base* size in metadata so
# reapply_fonts() can rescale the live UI without rebuilding any node.
const FONT_SCALE_MIN := 0.75
const FONT_SCALE_MAX := 2.0
# Every font-size theme key a Control might carry, so reapply_fonts() catches
# RichTextLabel's normal_font_size (and friends) as well as plain font_size.
const FONT_SIZE_KEYS := ["font_size", "normal_font_size", "bold_font_size", "italics_font_size", "mono_font_size"]

var font_scale: float = 1.0

# Scaled size for a base point size.
func fs(base: int) -> int:
	return maxi(1, int(round(float(base) * font_scale)))

# Apply a scaled font size to one Control and remember the unscaled base so a
# later scale change can re-derive it. Drop-in replacement for
# node.add_theme_font_size_override(key, size).
func set_font(node: Control, base: int, key: String = "font_size") -> void:
	if node == null:
		return
	node.set_meta("_base_font_" + key, base)
	node.add_theme_font_size_override(key, fs(base))

# Walks the tree and re-applies every font size previously set through
# set_font(), using the current font_scale. Called after a scale change.
func reapply_fonts(root: Node) -> void:
	if root == null:
		return
	if root is Control:
		var ctrl := root as Control
		for key_v in FONT_SIZE_KEYS:
			var key: String = key_v
			var mk: String = "_base_font_" + key
			if ctrl.has_meta(mk):
				ctrl.add_theme_font_size_override(key, fs(int(ctrl.get_meta(mk))))
	for child in root.get_children():
		reapply_fonts(child)

# Change the global text scale, rebuild the theme, and (optionally) persist.
func set_font_scale(s: float, persist: bool = true) -> void:
	font_scale = clampf(s, FONT_SCALE_MIN, FONT_SCALE_MAX)
	_rebuild_theme()
	if persist:
		AppSettings.ui_font_scale = font_scale
		AppSettings.save_settings()
	theme_changed.emit()

const DARK_COLORS := {
	"bg": "141416",
	"bg_panel": "1c1c1f",
	"bg_panel_alt": "171719",
	"bg_elevated": "24242a",
	"bg_input": "26262b",
	"bg_hover": "32323a",
	"border": "2b2b31",
	"border_strong": "3a3a42",
	"text": "ecebe7",
	"text_dim": "9a9aa3",
	"text_mute": "6c6c76",
	"accent": "e08a5f",
	"accent_hover": "ee9c72",
	"accent_soft": "3a2820",
	"accent_text": "1a1a1c",
	"success": "7fd18c",
	"error": "ef7a7a",
	"warning": "e8c96c",
	"user_bubble": "2b2521",
	"assistant_bubble": "202024",
	"tool_bubble": "1a1c20",
	"system_bubble": "1a1a1d",
}

const LIGHT_COLORS := {
	"bg": "f4f2ee",
	"bg_panel": "ffffff",
	"bg_panel_alt": "efede8",
	"bg_elevated": "ffffff",
	"bg_input": "f2f0eb",
	"bg_hover": "e8e5df",
	"border": "e1ded7",
	"border_strong": "ccc7bd",
	"text": "222120",
	"text_dim": "6d6b66",
	"text_mute": "96938d",
	"accent": "c96442",
	"accent_hover": "b5573a",
	"accent_soft": "fbe9e0",
	"accent_text": "ffffff",
	"success": "3d8b4d",
	"error": "c9463a",
	"warning": "a5791f",
	"user_bubble": "fbe9e0",
	"assistant_bubble": "f4f3ef",
	"tool_bubble": "edece7",
	"system_bubble": "f0eee9",
}

func _ready() -> void:
	font_scale = clampf(AppSettings.ui_font_scale, FONT_SCALE_MIN, FONT_SCALE_MAX)
	var start_mode := Mode.LIGHT if AppSettings.theme_mode == "light" else Mode.DARK
	set_mode(start_mode, false)

func c(key: String) -> Color:
	return Color(String(colors.get(key, "ff00ff")))

func is_dark() -> bool:
	return mode == Mode.DARK

func toggle() -> void:
	set_mode(Mode.LIGHT if mode == Mode.DARK else Mode.DARK)

func set_mode(p_mode: Mode, persist: bool = true) -> void:
	mode = p_mode
	colors = DARK_COLORS if mode == Mode.DARK else LIGHT_COLORS
	_rebuild_theme()
	if persist:
		AppSettings.theme_mode = "dark" if mode == Mode.DARK else "light"
		AppSettings.save_settings()
	theme_changed.emit()

func _rebuild_theme() -> void:
	theme = Theme.new()
	theme.default_font_size = fs(13)

	# --- base text ----------------------------------------------------------
	theme.set_color("font_color", "Label", c("text"))
	theme.set_color("font_color", "RichTextLabel", c("text"))
	theme.set_color("default_color", "RichTextLabel", c("text"))
	theme.set_font_size("normal_font_size", "RichTextLabel", fs(13))

	# --- buttons ------------------------------------------------------------
	var btn_pad_x := 14
	var btn_pad_y := 7
	theme.set_stylebox("normal", "Button", box(c("bg_input"), c("border"), 8, 1, btn_pad_x, btn_pad_y))
	theme.set_stylebox("hover", "Button", box(c("bg_hover"), c("border_strong"), 8, 1, btn_pad_x, btn_pad_y))
	theme.set_stylebox("pressed", "Button", box(c("accent_soft"), c("accent"), 8, 1, btn_pad_x, btn_pad_y))
	theme.set_stylebox("focus", "Button", box(Color(0, 0, 0, 0), c("accent"), 8, 1, btn_pad_x, btn_pad_y))
	theme.set_stylebox("disabled", "Button", box(c("bg_panel_alt"), c("border"), 8, 1, btn_pad_x, btn_pad_y))
	theme.set_color("font_color", "Button", c("text"))
	theme.set_color("font_hover_color", "Button", c("text"))
	theme.set_color("font_pressed_color", "Button", c("accent"))
	theme.set_color("font_disabled_color", "Button", c("text_mute"))

	# --- text inputs --------------------------------------------------------
	var input_box := box(c("bg_input"), c("border"), 8, 1, 12, 8)
	var input_focus := box(c("bg_input"), c("accent"), 8, 1, 12, 8)
	theme.set_stylebox("normal", "LineEdit", input_box)
	theme.set_stylebox("focus", "LineEdit", input_focus)
	theme.set_stylebox("read_only", "LineEdit", box(c("bg_panel_alt"), c("border"), 8, 1, 12, 8))
	theme.set_color("font_color", "LineEdit", c("text"))
	theme.set_color("font_placeholder_color", "LineEdit", c("text_mute"))
	theme.set_color("caret_color", "LineEdit", c("accent"))
	theme.set_color("selection_color", "LineEdit", Color(c("accent").r, c("accent").g, c("accent").b, 0.3))

	theme.set_stylebox("normal", "TextEdit", input_box)
	theme.set_stylebox("focus", "TextEdit", input_focus)
	theme.set_color("font_color", "TextEdit", c("text"))
	theme.set_color("font_placeholder_color", "TextEdit", c("text_mute"))
	theme.set_color("caret_color", "TextEdit", c("accent"))
	theme.set_color("selection_color", "TextEdit", Color(c("accent").r, c("accent").g, c("accent").b, 0.3))

	# --- dropdown -----------------------------------------------------------
	theme.set_stylebox("normal", "OptionButton", box(c("bg_input"), c("border"), 8, 1, 12, 7))
	theme.set_stylebox("hover", "OptionButton", box(c("bg_hover"), c("border_strong"), 8, 1, 12, 7))
	theme.set_stylebox("pressed", "OptionButton", box(c("bg_hover"), c("accent"), 8, 1, 12, 7))
	theme.set_stylebox("focus", "OptionButton", box(Color(0, 0, 0, 0), c("accent"), 8, 1, 12, 7))
	theme.set_color("font_color", "OptionButton", c("text"))

	theme.set_color("font_color", "CheckBox", c("text"))
	theme.set_color("font_hover_color", "CheckBox", c("text"))
	theme.set_color("font_pressed_color", "CheckBox", c("accent"))

	# --- containers ---------------------------------------------------------
	var panel_box := box(c("bg_panel"), c("border"), 0, 1, 0, 0)
	theme.set_stylebox("panel", "PanelContainer", panel_box)

	# --- trees / lists ------------------------------------------------------
	theme.set_color("font_color", "Tree", c("text"))
	theme.set_color("font_selected_color", "Tree", c("accent"))
	theme.set_color("guide_color", "Tree", Color(1, 1, 1, 0.03))
	theme.set_stylebox("panel", "Tree", box(c("bg_panel"), c("border"), 8, 1, 6, 6))
	theme.set_stylebox("selected", "Tree", box(Color(c("accent").r, c("accent").g, c("accent").b, 0.14), Color(0, 0, 0, 0), 6))
	theme.set_stylebox("selected_focus", "Tree", box(Color(c("accent").r, c("accent").g, c("accent").b, 0.18), Color(0, 0, 0, 0), 6))
	theme.set_stylebox("hover", "Tree", box(c("bg_hover"), Color(0, 0, 0, 0), 6))
	theme.set_stylebox("cursor", "Tree", StyleBoxEmpty.new())
	theme.set_stylebox("cursor_unfocused", "Tree", StyleBoxEmpty.new())
	theme.set_constant("v_separation", "Tree", 5)
	theme.set_constant("h_separation", "Tree", 6)

	theme.set_color("font_color", "ItemList", c("text"))
	theme.set_color("font_selected_color", "ItemList", c("accent"))
	theme.set_stylebox("panel", "ItemList", box(c("bg_panel"), c("border"), 8, 1, 6, 6))
	theme.set_stylebox("selected", "ItemList", box(Color(c("accent").r, c("accent").g, c("accent").b, 0.14), Color(0, 0, 0, 0), 6))
	theme.set_stylebox("selected_focus", "ItemList", box(Color(c("accent").r, c("accent").g, c("accent").b, 0.18), Color(0, 0, 0, 0), 6))
	theme.set_stylebox("hovered", "ItemList", box(c("bg_hover"), Color(0, 0, 0, 0), 6))
	theme.set_stylebox("focus", "ItemList", StyleBoxEmpty.new())
	theme.set_constant("v_separation", "ItemList", 6)

	# --- menus --------------------------------------------------------------
	theme.set_stylebox("panel", "PopupMenu", box(c("bg_elevated"), c("border_strong"), 10, 1, 6, 6))
	theme.set_stylebox("hover", "PopupMenu", box(c("bg_hover"), Color(0, 0, 0, 0), 6, 0, 8, 5))
	theme.set_color("font_color", "PopupMenu", c("text"))
	theme.set_color("font_hover_color", "PopupMenu", c("text"))
	theme.set_color("font_disabled_color", "PopupMenu", c("text_mute"))
	theme.set_color("font_separator_color", "PopupMenu", c("text_mute"))
	theme.set_constant("v_separation", "PopupMenu", 6)

	theme.set_color("font_color", "MenuButton", c("text"))
	theme.set_color("font_hover_color", "MenuButton", c("accent"))
	theme.set_stylebox("normal", "MenuButton", box(Color(0, 0, 0, 0), Color(0, 0, 0, 0), 8, 0, 12, 6))
	theme.set_stylebox("hover", "MenuButton", box(c("bg_hover"), Color(0, 0, 0, 0), 8, 0, 12, 6))
	theme.set_stylebox("pressed", "MenuButton", box(c("bg_hover"), Color(0, 0, 0, 0), 8, 0, 12, 6))
	theme.set_stylebox("focus", "MenuButton", StyleBoxEmpty.new())

	# --- scrollbars ---------------------------------------------------------
	var sb_bg := StyleBoxFlat.new()
	sb_bg.bg_color = Color(0, 0, 0, 0)
	sb_bg.set_corner_radius_all(6)
	var sb_grabber := StyleBoxFlat.new()
	sb_grabber.bg_color = c("border_strong")
	sb_grabber.set_corner_radius_all(6)
	var sb_grabber_hot := StyleBoxFlat.new()
	sb_grabber_hot.bg_color = c("accent")
	sb_grabber_hot.set_corner_radius_all(6)

	for t in ["VScrollBar", "HScrollBar"]:
		theme.set_stylebox("scroll", t, sb_bg)
		theme.set_stylebox("grabber", t, sb_grabber)
		theme.set_stylebox("grabber_highlight", t, sb_grabber_hot)
		theme.set_stylebox("grabber_pressed", t, sb_grabber_hot)

	# --- separators ---------------------------------------------------------
	var vline := StyleBoxLine.new()
	vline.color = c("border")
	vline.thickness = 1
	vline.vertical = true
	theme.set_stylebox("separator", "VSeparator", vline)
	var hline := StyleBoxLine.new()
	hline.color = c("border")
	hline.thickness = 1
	hline.vertical = false
	theme.set_stylebox("separator", "HSeparator", hline)

	# --- windows (embedded subwindows, dialogs) -----------------------------
	var win_border := StyleBoxFlat.new()
	win_border.bg_color = c("bg_panel")
	win_border.border_color = c("border_strong")
	win_border.set_border_width_all(1)
	win_border.set_corner_radius_all(12)
	win_border.expand_margin_top = 28
	win_border.content_margin_top = 28
	win_border.content_margin_left = 0
	win_border.content_margin_right = 0
	win_border.content_margin_bottom = 0
	theme.set_stylebox("embedded_border", "Window", win_border)
	theme.set_stylebox("embedded_unfocused_border", "Window", win_border)
	theme.set_color("title_color", "Window", c("text"))
	theme.set_font_size("title_font_size", "Window", fs(13))

	theme.set_stylebox("panel", "AcceptDialog", box(c("bg_panel"), c("border"), 10, 1, 14, 12))
	theme.set_color("font_color", "AcceptDialog", c("text"))

	theme.set_stylebox("panel", "ScrollContainer", StyleBoxEmpty.new())
	theme.set_stylebox("panel", "TabContainer", box(c("bg_panel"), c("border"), 8))

func box(bg: Color, border: Color, radius: int, border_w: int = 1, pad_x: int = 0, pad_y: int = 0) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	if border_w > 0:
		s.border_color = border
		s.set_border_width_all(border_w)
	s.set_corner_radius_all(radius)
	s.content_margin_left = pad_x
	s.content_margin_right = pad_x
	s.content_margin_top = pad_y
	s.content_margin_bottom = pad_y
	return s

func flat_box(bg: Color, radius: int) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.set_corner_radius_all(radius)
	s.content_margin_left = 12
	s.content_margin_right = 12
	s.content_margin_top = 8
	s.content_margin_bottom = 8
	return s
