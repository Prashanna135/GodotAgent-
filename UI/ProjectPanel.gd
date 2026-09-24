class_name ProjectPanel
extends VBoxContainer

signal project_open_requested(path: String)
signal file_activated(path: String)

# Godot writes .uid / .import sidecar files and a .godot/ cache next to real
# source. None of them contain anything a user edits, and listing them turns
# the tree into visual noise — so we never show them.
const SKIP_DIR_NAMES := [".godot", ".git", ".import", "__pycache__"]
const SKIP_FILE_EXTENSIONS := [".uid", ".import", ".tmp", ".log", ".lock"]

var _recents: ItemList
var _tree: Tree
var _root_path: String = ""
var _busy: bool = false
var _header: PanelContainer

func _ready() -> void:
	add_theme_constant_override("separation", 0)

	if not ThemeManager.theme_changed.is_connected(apply_theme):
		ThemeManager.theme_changed.connect(apply_theme)

	# --- header -------------------------------------------------------------
	_header = PanelContainer.new()
	_header.custom_minimum_size.y = 36
	var hl := HBoxContainer.new()
	hl.add_theme_constant_override("separation", 8)
	_header.add_child(hl)
	var title := Label.new()
	title.text = "Project"
	ThemeManager.set_font(title, 13)
	hl.add_child(title)
	var sp0 := Control.new()
	sp0.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hl.add_child(sp0)
	add_child(_header)

	# --- open row -----------------------------------------------------------
	var open_row := MarginContainer.new()
	open_row.add_theme_constant_override("margin_left", 10)
	open_row.add_theme_constant_override("margin_right", 10)
	open_row.add_theme_constant_override("margin_top", 10)
	open_row.add_theme_constant_override("margin_bottom", 4)
	var open_btn := Button.new()
	open_btn.text = "Open Project…"
	open_btn.pressed.connect(func(): project_open_requested.emit(""))
	open_row.add_child(open_btn)
	add_child(open_row)

	# --- recents ------------------------------------------------------------
	add_child(_section("Recent"))
	_recents = ItemList.new()
	_recents.custom_minimum_size.y = 120
	_recents.item_activated.connect(_on_recent_activated)
	_recents.add_theme_constant_override("v_separation", 6)
	add_child(_recents)

	# --- files --------------------------------------------------------------
	add_child(_section("Files"))
	_tree = Tree.new()
	_tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_tree.hide_root = true
	_tree.allow_reselect = true
	_tree.select_mode = Tree.SELECT_ROW
	_tree.item_collapsed.connect(_on_item_collapsed)
	_tree.item_activated.connect(_on_item_activated)
	_tree.item_selected.connect(_on_item_selected)
	add_child(_tree)

	AppSettings.settings_changed.connect(_refresh_recents)
	_refresh_recents()
	apply_theme()

func _section(text: String) -> MarginContainer:
	var m := MarginContainer.new()
	m.add_theme_constant_override("margin_left", 12)
	m.add_theme_constant_override("margin_right", 10)
	m.add_theme_constant_override("margin_top", 12)
	m.add_theme_constant_override("margin_bottom", 4)
	var l := Label.new()
	l.text = text.to_upper()
	ThemeManager.set_font(l, 10)
	l.add_theme_color_override("font_color", ThemeManager.c("text_mute"))
	m.add_child(l)
	return m

func _refresh_recents() -> void:
	if _recents == null:
		return
	_recents.clear()
	for p in AppSettings.recent_projects:
		var idx := _recents.add_item(p.get_file() + "  —  " + p)
		_recents.set_item_metadata(idx, p)

func _on_recent_activated(index: int) -> void:
	var p: Variant = _recents.get_item_metadata(index)
	if p != null:
		project_open_requested.emit(str(p))

func load_project(path: String) -> void:
	_root_path = path
	_busy = true
	_tree.clear()
	var root := _tree.create_item()
	if root == null:
		push_error("ProjectPanel: failed to create root tree item")
		_busy = false
		return
	root.set_text(0, path.get_file())
	_populate_children(root, path)
	root.set_metadata(0, {"path": path, "is_dir": true, "loaded": true})
	_busy = false

static func _is_generated_file(filename: String) -> bool:
	var lower := filename.to_lower()
	for ext in SKIP_FILE_EXTENSIONS:
		if lower.ends_with(ext):
			return true
	return false

func _populate_children(parent: TreeItem, path: String) -> void:
	if parent == null:
		return
	var d := DirAccess.open(path)
	if d == null:
		return
	var dirs: Array[String] = []
	var files: Array[String] = []
	d.list_dir_begin()
	var n := d.get_next()
	while n != "":
		if not n.begins_with("."):
			if d.current_is_dir():
				if not (n in SKIP_DIR_NAMES):
					dirs.append(n)
			else:
				if not _is_generated_file(n):
					files.append(n)
		n = d.get_next()
	d.list_dir_end()
	dirs.sort()
	files.sort()

	for dir_name in dirs:
		var child := _tree.create_item(parent)
		if child == null:
			continue
		child.set_text(0, dir_name)
		child.set_metadata(0, {
			"path": path.path_join(dir_name),
			"is_dir": true,
			"loaded": false,
		})
		child.collapsed = true
		var ph := _tree.create_item(child)
		if ph != null:
			ph.set_text(0, "…")
			ph.set_metadata(0, {"placeholder": true})

	for file_name in files:
		var child := _tree.create_item(parent)
		if child == null:
			continue
		child.set_text(0, file_name)
		child.set_metadata(0, {
			"path": path.path_join(file_name),
			"is_dir": false,
			"loaded": true,
		})

func _on_item_collapsed(item: TreeItem) -> void:
	if item == null or not is_instance_valid(item):
		return
	if _busy:
		return
	var meta: Variant = item.get_metadata(0)
	if typeof(meta) != TYPE_DICTIONARY:
		return
	var md: Dictionary = meta
	if not bool(md.get("is_dir", false)):
		return
	if bool(md.get("loaded", false)):
		return
	_busy = true
	call_deferred("_expand_folder", item)

func _expand_folder(item: TreeItem) -> void:
	if item == null or not is_instance_valid(item):
		_busy = false
		return
	var meta: Variant = item.get_metadata(0)
	if typeof(meta) != TYPE_DICTIONARY:
		_busy = false
		return
	var md: Dictionary = meta
	_remove_placeholders(item)
	_populate_children(item, str(md["path"]))
	md["loaded"] = true
	item.set_metadata(0, md)
	_busy = false

func _remove_placeholders(item: TreeItem) -> void:
	var count := item.get_child_count()
	for i in range(count - 1, -1, -1):
		var c := item.get_child(i)
		if c == null:
			continue
		var cm: Variant = c.get_metadata(0)
		if typeof(cm) != TYPE_DICTIONARY:
			continue
		var cd: Dictionary = cm
		if bool(cd.get("placeholder", false)):
			c.free()

func _on_item_selected() -> void:
	var item := _tree.get_selected()
	if item == null:
		return
	var meta: Variant = item.get_metadata(0)
	if typeof(meta) != TYPE_DICTIONARY:
		return
	var md: Dictionary = meta
	if bool(md.get("is_dir", false)):
		return
	file_activated.emit(str(md.get("path", "")))

func _on_item_activated() -> void:
	var item := _tree.get_selected()
	if item == null:
		return
	var meta: Variant = item.get_metadata(0)
	if typeof(meta) != TYPE_DICTIONARY:
		return
	var md: Dictionary = meta
	if not bool(md.get("is_dir", false)):
		return
	item.collapsed = not item.collapsed

func apply_theme() -> void:
	if _tree == null:
		return
	var panel_style := StyleBoxFlat.new()
	panel_style.bg_color = ThemeManager.c("bg_panel")
	panel_style.border_width_right = 1
	panel_style.border_color = ThemeManager.c("border")
	add_theme_stylebox_override("panel", panel_style)

	if _header != null:
		var hs := StyleBoxFlat.new()
		hs.bg_color = ThemeManager.c("bg_panel")
		hs.border_width_bottom = 1
		hs.border_color = ThemeManager.c("border")
		hs.content_margin_left = 14
		hs.content_margin_right = 10
		hs.content_margin_top = 5
		hs.content_margin_bottom = 5
		_header.add_theme_stylebox_override("panel", hs)
