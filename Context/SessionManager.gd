class_name SessionManager
extends RefCounted

# Persists { conversation, plan steps, checkpoint stack summary } per
# project to user://sessions/<id>/session.json, so a crash or restart can
# resume a task in progress. Called by MainWindow after every turn (see
# MainWindow._save_session) and read back when a project with an existing
# session is opened (MainWindow._maybe_offer_resume).
#
# Deliberately never touches credentials: the payload is conversation, plan
# steps, and checkpoint metadata only — never AppSettings.api_key or
# anything else provider-shaped.
#
# Checkpoint *content* (the actual before/after file text) is never
# duplicated into this JSON — it already lives in its own stash files under
# CheckpointManager.CHECKPOINT_ROOT, and only the stash paths + metadata are
# recorded here. Keeps session.json small regardless of file size.

const SESSION_ROOT := "user://sessions"
const SCHEMA_VERSION := 1

# Derives a stable, filesystem-safe session id from a project root path, so
# the same project always resumes the same session file regardless of how
# it was opened (dialog, recent list, last-project restore).
static func session_id_for(project_root: String) -> String:
	var normalized := project_root.strip_edges().replace("\\", "/").simplify_path().rstrip("/")
	if normalized == "":
		return ""
	return normalized.sha256_text().substr(0, 16)

static func session_dir(id: String) -> String:
	return SESSION_ROOT.path_join(id)

static func session_path(id: String) -> String:
	return session_dir(id).path_join("session.json")

# Writes the current session state to disk for `project_root`. Returns
# false (and logs) on any I/O failure; callers treat that as best-effort,
# same as AppSettings.save_settings().
static func save(project_root: String, conversation_data: Array, plan_steps: Array, checkpoint_entries: Array) -> bool:
	var id := session_id_for(project_root)
	if id == "":
		return false
	var dir := session_dir(id)
	if not DirAccess.dir_exists_absolute(dir):
		var err := DirAccess.make_dir_recursive_absolute(dir)
		if err != OK:
			push_error("SessionManager: could not create %s (error %d)" % [dir, err])
			return false

	var payload := {
		"schema_version": SCHEMA_VERSION,
		"last_project": project_root,
		"saved_at": Time.get_unix_time_from_system(),
		"conversation": conversation_data,
		"plan_steps": plan_steps,
		"checkpoints": checkpoint_entries,
	}

	var f := FileAccess.open(session_path(id), FileAccess.WRITE)
	if f == null:
		push_error("SessionManager: could not open %s for write (error %d)" % [session_path(id), FileAccess.get_open_error()])
		return false
	f.store_string(JSON.stringify(payload, "  "))
	f.close()
	return true

# Returns the saved payload for `project_root`, or an empty Dictionary if no
# session exists, the file is unreadable, or it doesn't parse as an object.
static func load(project_root: String) -> Dictionary:
	var id := session_id_for(project_root)
	if id == "":
		return {}
	var path := session_path(id)
	if not FileAccess.file_exists(path):
		return {}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var text := f.get_as_text()
	f.close()
	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		return {}
	return parsed

static func has_session(project_root: String) -> bool:
	var id := session_id_for(project_root)
	if id == "":
		return false
	return FileAccess.file_exists(session_path(id))

# Human-readable one-liner for a resume prompt, without the caller needing
# to know the payload's shape.
static func describe(data: Dictionary) -> String:
	var msg_count := 0
	var conv_v: Variant = data.get("conversation", [])
	if typeof(conv_v) == TYPE_ARRAY:
		msg_count = (conv_v as Array).size()
	var plan_count := 0
	var plan_v: Variant = data.get("plan_steps", [])
	if typeof(plan_v) == TYPE_ARRAY:
		plan_count = (plan_v as Array).size()
	var saved_at := float(data.get("saved_at", 0))
	var ago := ""
	if saved_at > 0.0:
		var secs := int(Time.get_unix_time_from_system() - saved_at)
		ago = " · %s" % _format_ago(secs)
	var plan_part := ", %d plan step(s)" % plan_count if plan_count > 0 else ""
	return "%d message(s)%s%s" % [msg_count, plan_part, ago]

static func _format_ago(secs: int) -> String:
	if secs < 60:
		return "just now"
	if secs < 3600:
		return "%dm ago" % (secs / 60)
	if secs < 86400:
		return "%dh ago" % (secs / 3600)
	return "%dd ago" % (secs / 86400)
