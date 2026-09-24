class_name ProjectManager
extends RefCounted

var current: ProjectInfo = null

func open(root_path: String) -> ProjectInfo:
	var info := ProjectInfo.new()
	info.root_path = root_path.strip_edges().replace("\\", "/").simplify_path().rstrip("/")
	var pg := info.root_path.path_join("project.godot")
	info.project_godot_path = pg
	if FileAccess.file_exists(pg):
		var cfg := ConfigFile.new()
		if cfg.load(pg) == OK:
			info.name = str(cfg.get_value("application", "config/name", info.root_path.get_file()))
			info.main_scene = str(cfg.get_value("application", "run/main_scene", ""))
	else:
		info.name = info.root_path.get_file()
	current = info
	return info

func set_godot_executable(path: String) -> void:
	if current != null:
		current.godot_executable = path
