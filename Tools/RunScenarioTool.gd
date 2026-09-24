class_name RunScenarioTool
extends GodotTool

# Runtime observation, per handoff_file §5.3. Everything else in the tool
# kit reads or writes text; this is the first tool that lets the agent
# OBSERVE behavior instead of reasoning about it from source alone.
#
# How it runs: the agent supplies a small GDScript Node script (`setup`).
# That script is saved under res://.agent_scenarios/<name>.gd, wrapped in
# a generated .tscn that boots it alongside a real instance of the
# project's own run/main_scene (as a sibling node, $World) — NOT via
# `--script`, which would skip the normal scene/autoload boot entirely.
# The wrapper is then run with `godot --headless --path <project> <wrapper>`,
# a real boot with real autoloads, real collision layers, real navigation.
#
# The scenario script prints a line starting with "PASS:" or "FAIL:" and
# calls get_tree().quit(). This tool scans stdout for the first such line
# and reports it as the verdict — but per project rule #4 ("no fake
# success"), a PASS is never trusted if the same run also logged a real
# Godot ERROR line elsewhere; that overrides to FAIL regardless.
#
# Two modes, both via the same `name` argument:
#   setup non-empty  -> write/overwrite the scenario, then run it.
#   setup empty      -> re-run the existing scenario unchanged. This is
#                       the regression-check mode: after a code fix, the
#                       agent re-runs the same scenario for zero extra
#                       authoring tokens.

const SCENARIO_DIR := "res://.agent_scenarios"
const DEFAULT_DURATION := 30.0
const HARD_CAP_DURATION := 120.0
# Extra wall-clock time given to the process beyond `duration` before the
# harness calls it hung and kills it — the scenario's own script should
# call get_tree().quit() well inside `duration`; this is slack for Godot's
# own startup/shutdown, not extra scenario runtime.
const EXTRA_WAIT_SECS := 8.0

func _init() -> void:
	name = "run_scenario"
	description = (
		"Run a small GDScript test scenario against the REAL project headlessly — actual "
		+ "scene, autoloads, collision layers, navigation — and return its printed PASS/FAIL "
		+ "verdict. Use to verify behavior (movement, damage, signals, save/load, AI "
		+ "decisions) that reading code cannot confirm. Pass `setup` to write a new "
		+ "scenario; omit it to re-run an existing one by `name` after a code change, at no "
		+ "extra authoring cost."
	)
	required_permission = "RUN_GODOT"
	input_schema = {
		"type": "object",
		"properties": {
			"name": {
				"type": "string",
				"description": "Scenario identifier (letters/digits/underscore only), e.g. 'peasant_avoidance'. Reused across calls to re-run the same test.",
			},
			"setup": {
				"type": "string",
				"description": (
					"GDScript source for a Node script, attached to the scenario root. "
					+ "The project's main scene is auto-instanced as a sibling child named "
					+ "'World' — reach it with `@onready var world: Node = $World` or "
					+ "`get_node(\"../World\")`. Print a line starting with 'PASS:' or "
					+ "'FAIL:' to report the verdict, then call get_tree().quit(). Omit "
					+ "this argument to re-run the scenario already saved under `name` "
					+ "unchanged."
				),
			},
			"duration": {
				"type": "number",
				"description": "Max seconds to let the scenario run before it's killed as hung; default 30, max 120.",
			},
		},
		"required": ["name"],
	}

func execute(arguments: Dictionary) -> ToolResult:
	if project_root == "":
		return ToolResult.invalid_argument("No project is open")
	if process_manager == null:
		return ToolResult.failure("GodotProcessManager is not available", ToolResult.ErrorKind.INTERNAL)
	var exe := _resolve_executable()
	if exe.strip_edges() == "":
		return ToolResult.invalid_argument("Godot executable is not configured")

	var scenario_name := str(arguments.get("name", "")).strip_edges()
	if scenario_name == "" or not _is_safe_name(scenario_name):
		return ToolResult.invalid_argument(
			"`name` must be a non-empty identifier using only letters, digits, and underscores."
		)

	var setup := str(arguments.get("setup", ""))
	var script_res_path := "%s/%s.gd" % [SCENARIO_DIR, scenario_name]
	var wrapper_res_path := "%s/%s.tscn" % [SCENARIO_DIR, scenario_name]
	var script_full := resolve_path(script_res_path)
	var wrapper_full := resolve_path(wrapper_res_path)
	if script_full == "" or wrapper_full == "":
		return ToolResult.sandbox_violation("Scenario path resolution failed for '%s'." % scenario_name)

	if setup.strip_edges() != "":
		var dir := script_full.get_base_dir()
		if not DirAccess.dir_exists_absolute(dir):
			var derr := DirAccess.make_dir_recursive_absolute(dir)
			if derr != OK:
				return ToolResult.io_error("Could not create %s (error %d)" % [dir, derr])
		var wf := FileAccess.open(script_full, FileAccess.WRITE)
		if wf == null:
			return ToolResult.io_error(
				"Cannot write scenario script: %s (error %d)" % [script_res_path, FileAccess.get_open_error()]
			)
		wf.store_string(setup)
		wf.close()
	elif not FileAccess.file_exists(script_full):
		return ToolResult.not_found(
			"No scenario named '%s' exists yet (%s not found) — pass `setup` to create it."
			% [scenario_name, script_res_path]
		)

	var main_scene := _read_main_scene()
	if main_scene == "":
		return ToolResult.invalid_argument(
			"This project's project.godot has no run/main_scene set — run_scenario needs a "
			+ "main scene to instance as $World. Set one in Project Settings first."
		)

	var wf2 := FileAccess.open(wrapper_full, FileAccess.WRITE)
	if wf2 == null:
		return ToolResult.io_error(
			"Cannot write scenario wrapper scene: %s (error %d)" % [wrapper_res_path, FileAccess.get_open_error()]
		)
	wf2.store_string(_build_wrapper_tscn(script_res_path, main_scene))
	wf2.close()

	var duration := float(arguments.get("duration", DEFAULT_DURATION))
	if duration <= 0.0 or duration > HARD_CAP_DURATION:
		duration = DEFAULT_DURATION

	var args := PackedStringArray([
		"--path", project_root,
		"--headless",
		wrapper_res_path,
	])
	var id: int = process_manager.launch(exe, args, project_root, "scenario:" + scenario_name)
	if id < 0:
		return ToolResult.io_error("Failed to spawn headless Godot for scenario '%s'." % scenario_name)

	var snap: Dictionary = await process_manager.wait_for_exit_or_timeout(id, duration + EXTRA_WAIT_SECS)
	var timed_out := bool(snap.get("timed_out", false))
	if timed_out:
		process_manager.kill(id)

	var stdout := str(snap.get("stdout", ""))
	var stderr := str(snap.get("stderr", ""))
	var exit_code := int(snap.get("exit_code", -1))
	var combined := stdout
	if stderr != "":
		if combined != "" and not combined.ends_with("\n"):
			combined += "\n"
		combined += "[stderr]\n" + stderr

	var annotated := _annotate_output(combined)
	var events: Array = annotated.get("events", [])
	var error_summary: String = str(annotated.get("text", ""))
	var had_errors := _has_error_markers(combined)
	var verdict := _extract_verdict(combined)

	var meta := {
		"process_id": id,
		"exit_code": exit_code,
		"timed_out": timed_out,
		"scenario": scenario_name,
		"verdict": str(verdict.get("status", "INCONCLUSIVE")),
		"events": events_to_dicts(events),
		"event_count": events.size(),
	}

	if timed_out:
		var body := (
			"Scenario '%s' timed out after %.0fs (process killed) — treat as FAIL "
			+ "(hung or infinite loop; make sure the script always reaches "
			+ "get_tree().quit())." % [scenario_name, duration]
		)
		body += "\n---- output so far ----\n" + combined
		meta["verdict"] = "FAIL"
		return ToolResult.failure(body, ToolResult.ErrorKind.TIMEOUT, meta)

	# No fake success (project rule #4): a PASS line is not trusted if the
	# same run also logged a real engine error — a scenario can print PASS
	# right before something unrelated throws, and that is still a real
	# problem worth surfacing rather than reporting green.
	if had_errors:
		var body := (
			"Scenario '%s' ran but the output contains Godot ERROR lines — treating as "
			+ "FAILED regardless of any PASS/FAIL line it printed." % scenario_name
		)
		if error_summary != "":
			body += "\n" + error_summary
		body += "\n---- raw output ----\n" + combined
		meta["verdict"] = "FAIL"
		return ToolResult.failure(body, ToolResult.ErrorKind.INTERNAL, meta)

	match str(verdict.get("status", "INCONCLUSIVE")):
		"PASS":
			return ToolResult.ok(
				"Scenario '%s' PASSED (exit %d).\n%s" % [scenario_name, exit_code, str(verdict.get("line", ""))],
				meta
			)
		"FAIL":
			var body := "Scenario '%s' FAILED (exit %d).\n%s\n---- raw output ----\n%s" % [
				scenario_name, exit_code, str(verdict.get("line", "")), combined
			]
			return ToolResult.failure(body, ToolResult.ErrorKind.INTERNAL, meta)
		_:
			var body := (
				"Scenario '%s' produced no line starting with PASS: or FAIL: (exit %d) — "
				+ "inconclusive. Raw output:\n%s" % [scenario_name, exit_code, combined]
			)
			return ToolResult.ok(body, meta)

static func _is_safe_name(s: String) -> bool:
	var re := RegEx.new()
	re.compile("^[A-Za-z_][A-Za-z0-9_]*$")
	return re.search(s) != null

func _read_main_scene() -> String:
	var pg := project_root.path_join("project.godot")
	if not FileAccess.file_exists(pg):
		return ""
	var cfg := ConfigFile.new()
	if cfg.load(pg) != OK:
		return ""
	return str(cfg.get_value("application", "run/main_scene", ""))

static func _build_wrapper_tscn(script_res_path: String, main_scene_res_path: String) -> String:
	return (
		"[gd_scene load_steps=3 format=3]\n\n"
		+ "[ext_resource type=\"Script\" path=\"%s\" id=\"1\"]\n" % script_res_path
		+ "[ext_resource type=\"PackedScene\" path=\"%s\" id=\"2\"]\n\n" % main_scene_res_path
		+ "[node name=\"ScenarioRoot\" type=\"Node\"]\n"
		+ "script = ExtResource(\"1\")\n\n"
		+ "[node name=\"World\" parent=\".\" instance=ExtResource(\"2\")]\n"
	)

# Scans for the first line starting with "PASS:" or "FAIL:" (after
# stripping leading whitespace). The first one wins — a scenario printing
# a PASS followed by a contradicting FAIL note is a scenario-writing bug
# for the model to fix, not something this tool should silently reconcile.
static func _extract_verdict(text: String) -> Dictionary:
	for raw_line in text.split("\n"):
		var line := raw_line.strip_edges()
		if line.begins_with("PASS:"):
			return {"status": "PASS", "line": line}
		if line.begins_with("FAIL:"):
			return {"status": "FAIL", "line": line}
	return {"status": "INCONCLUSIVE", "line": ""}

static func _has_error_markers(text: String) -> bool:
	return text.find("SCRIPT ERROR:") != -1 \
		or text.find("ERROR:") != -1 \
		or text.find("Failed to load script") != -1
