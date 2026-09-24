class_name ListAutoloadsTool
extends ProjectPathTool

# Cheap-win roadmap tool (handoff_file §5.1). GodotTool._load_autoload_names()
# already reads project.godot's [autoload] section for the check-only
# false-positive filter — this exposes the same ground truth directly to the
# model as a callable tool, instead of it having to find_files + read_file
# project.godot and parse the section by eye every time it needs to know
# what singletons exist.
#
# Does not extend GodotTool: it never spawns a Godot process, so it doesn't
# need process_manager/godot_executable/model_profile.

func _init() -> void:
	name = "list_autoloads"
	description = (
		"List every autoload singleton declared in project.godot's [autoload] section — "
		+ "name and script path, in one call. Autoloads are NOT .gd declarations, so "
		+ "find_symbol won't find them; use this instead of guessing which singletons exist "
		+ "or manually reading project.godot."
	)
	required_permission = "READ_PROJECT"
	input_schema = {
		"type": "object",
		"properties": {},
	}

func execute(_arguments: Dictionary) -> ToolResult:
	if project_root == "":
		return ToolResult.invalid_argument("No project is open")
	var pg := project_root.path_join("project.godot")
	if not FileAccess.file_exists(pg):
		return ToolResult.not_found("project.godot not found at %s" % pg)
	var cfg := ConfigFile.new()
	if cfg.load(pg) != OK:
		return ToolResult.io_error("Could not parse project.godot")
	if not cfg.has_section("autoload"):
		return ToolResult.ok("No autoload singletons declared in project.godot.", {"count": 0})

	# A leading "*" in the stored value marks the entry as enabled/global —
	# it's how Godot's own [autoload] section flags a singleton that's
	# actually active, as opposed to a disabled/legacy entry. Stripped from
	# the reported path and surfaced as a readable note instead.
	var lines := PackedStringArray()
	var count := 0
	for key in cfg.get_section_keys("autoload"):
		var raw := str(cfg.get_value("autoload", key, ""))
		var is_global := raw.begins_with("*")
		var path := raw.substr(1) if is_global else raw
		lines.append("%s -> %s%s" % [str(key), path, "  (global singleton)" if is_global else "  (disabled)"])
		count += 1
	lines.sort()
	return ToolResult.ok(
		"%d autoload(s) declared in project.godot:\n%s" % [count, "\n".join(lines)],
		{"count": count}
	)
