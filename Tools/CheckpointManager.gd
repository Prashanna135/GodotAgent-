class_name CheckpointManager
extends RefCounted

# Snapshots are stashed under the agent's own user:// data, never inside the
# target project, so they can't be mistaken for project files or committed.
const CHECKPOINT_ROOT := "user://checkpoints"
const MAX_ENTRIES := 50

class Entry:
	extends RefCounted
	var tool_name: String = ""
	var raw_path: String = ""       # path as given to the tool (res:// form)
	var absolute_path: String = ""  # resolved absolute path on disk
	var snapshot_path: String = ""  # where the "before" content is stashed, "" if none
	var after_snapshot_path: String = ""  # where the "after" content is stashed, "" if none
	var existed_before: bool = false
	var existed_after: bool = true
	var before_content: String = "" # cached in memory for the diff viewer
	var after_content: String = ""  # cached in memory for the diff viewer
	var timestamp: int = 0

var _stack: Array = []   # Array[Entry]
var _counter: int = 0

# --- called by ToolManager around a write-ish tool call --------------------

# Snapshots the file's current state. Returns an Entry that must be passed to
# commit() (call succeeded) or discard() (call failed / no-op) — nothing is
# added to the undo stack until commit() runs.
func snapshot(tool_name: String, project_root: String, raw_path: String) -> Entry:
	if project_root == "" or raw_path == "":
		return null
	var abs_path := _resolve(project_root, raw_path)
	if abs_path == "":
		return null
	var e := Entry.new()
	e.tool_name = tool_name
	e.raw_path = raw_path
	e.absolute_path = abs_path
	e.timestamp = Time.get_unix_time_from_system()
	e.existed_before = FileAccess.file_exists(abs_path)
	if e.existed_before:
		e.before_content = _read_file(abs_path)
		e.snapshot_path = _stash_from_text(e.before_content)
	return e

# Captures the after-content now, while we know the file is in its
# post-edit state, and stashes it to disk symmetrically with the before-
# content stashed by snapshot() above. This used to be memory-only, which
# meant a crash or restart silently lost half of every diff (History would
# still show the entry, but the "after" side would come back empty) — now
# it survives a restart the same way "before" already did.
func commit(entry: Entry) -> void:
	if entry == null:
		return
	entry.existed_after = FileAccess.file_exists(entry.absolute_path)
	if entry.existed_after:
		entry.after_content = _read_file(entry.absolute_path)
		entry.after_snapshot_path = _stash_from_text(entry.after_content)
	else:
		entry.after_content = ""
		entry.after_snapshot_path = ""
	_stack.append(entry)
	if _stack.size() > MAX_ENTRIES:
		var old: Entry = _stack.pop_front()
		_cleanup(old)

func discard(entry: Entry) -> void:
	if entry != null:
		_cleanup(entry)

# --- inspection API for the diff viewer --------------------------------

func has_checkpoints() -> bool:
	return not _stack.is_empty()

func entry_count() -> int:
	return _stack.size()

# Index 0 = most recent change. Returned as references into the internal
# stack (callers must not mutate them) so the diff viewer doesn't have to
# copy potentially-large before/after strings.
func entries_newest_first() -> Array:
	var out: Array = []
	for i in range(_stack.size() - 1, -1, -1):
		out.append(_stack[i])
	return out

func describe_last() -> String:
	if _stack.is_empty():
		return ""
	var e: Entry = _stack[_stack.size() - 1]
	return "%s on %s" % [e.tool_name, e.raw_path]

# --- undo --------------------------------------------------------------

# Pops and undoes the most recent recorded change. Returns
# {success: bool, message: String, path: String}.
func revert_last() -> Dictionary:
	if _stack.is_empty():
		return {"success": false, "message": "No checkpoints recorded yet — nothing to revert."}
	var e: Entry = _stack[_stack.size() - 1]
	var res := _apply_revert(e)
	if not bool(res.get("success", false)):
		return res
	_stack.pop_back()
	_cleanup(e)
	return res

# Revert the entry at `newest_index` (0 = most recent) AND every entry newer
# than it, in LIFO order. So index 0 reverts just the most recent change;
# index 2 reverts the three most recent changes, landing the project at the
# state just before the 3rd-newest change was applied.
#
# Returns {success: bool, reverted: int, message: String}.
func revert_to_newest_index(newest_index: int) -> Dictionary:
	if newest_index < 0:
		return {"success": false, "reverted": 0, "message": "Invalid index."}
	var target_size := _stack.size() - newest_index - 1
	if target_size < 0:
		return {"success": false, "reverted": 0, "message": "Index out of range."}
	var count := 0
	var last_message := ""
	while _stack.size() > target_size:
		var r := revert_last()
		if not bool(r.get("success", false)):
			return {
				"success": false,
				"reverted": count,
				"message": "Reverted %d change(s) before failure: %s" % [count, str(r.get("message", "unknown"))],
			}
		count += 1
		last_message = str(r.get("message", ""))
	var summary: String
	if count == 1:
		summary = last_message
	else:
		summary = "Reverted %d changes. Last: %s" % [count, last_message]
	return {"success": true, "reverted": count, "message": summary}

func _apply_revert(e: Entry) -> Dictionary:
	if e.existed_before:
		var f := FileAccess.open(e.absolute_path, FileAccess.WRITE)
		if f == null:
			return {
				"success": false,
				"message": "Could not write %s while reverting (error %d)."
					% [e.raw_path, FileAccess.get_open_error()],
			}
		f.store_string(e.before_content)
		f.close()
		return {
			"success": true,
			"message": "Reverted %s (undid %s) — restored its previous content." % [e.raw_path, e.tool_name],
			"path": e.raw_path,
		}
	else:
		# File did not exist before this call (e.g. create_file) — undo = delete it.
		if FileAccess.file_exists(e.absolute_path):
			var err := DirAccess.remove_absolute(e.absolute_path)
			if err != OK:
				return {
					"success": false,
					"message": "Could not delete %s while reverting (error %d)." % [e.raw_path, err],
				}
		return {
			"success": true,
			"message": "Reverted %s (undid %s) — file did not exist before that call, so it was removed."
				% [e.raw_path, e.tool_name],
			"path": e.raw_path,
		}

# --- session persistence -------------------------------------------------
#
# Only metadata and the on-disk stash paths are serialized — never the
# before/after text itself, which already lives in its own stash file under
# CHECKPOINT_ROOT. Keeps session.json small regardless of how large the
# edited files were. See SessionManager.

func to_session_data() -> Array:
	var out: Array = []
	for e in _stack:
		var entry := e as Entry
		if entry == null:
			continue
		out.append({
			"tool_name": entry.tool_name,
			"raw_path": entry.raw_path,
			"absolute_path": entry.absolute_path,
			"snapshot_path": entry.snapshot_path,
			"after_snapshot_path": entry.after_snapshot_path,
			"existed_before": entry.existed_before,
			"existed_after": entry.existed_after,
			"timestamp": entry.timestamp,
		})
	return out

# Rebuilds _stack from previously-saved session data, reading before/after
# content back from their stash files. A missing or since-deleted stash
# file degrades to empty content for that side rather than failing the
# whole restore — the entry still shows up in History with whatever it can
# recover.
func restore_from_session_data(data: Array) -> void:
	_stack.clear()
	for item_v in data:
		if typeof(item_v) != TYPE_DICTIONARY:
			continue
		var d: Dictionary = item_v
		var e := Entry.new()
		e.tool_name = str(d.get("tool_name", ""))
		e.raw_path = str(d.get("raw_path", ""))
		e.absolute_path = str(d.get("absolute_path", ""))
		e.snapshot_path = str(d.get("snapshot_path", ""))
		e.after_snapshot_path = str(d.get("after_snapshot_path", ""))
		e.existed_before = bool(d.get("existed_before", false))
		e.existed_after = bool(d.get("existed_after", true))
		e.timestamp = int(d.get("timestamp", 0))
		if e.snapshot_path != "":
			e.before_content = _read_file(e.snapshot_path)
		if e.after_snapshot_path != "":
			e.after_content = _read_file(e.after_snapshot_path)
		_stack.append(e)

# Drops every recorded checkpoint AND cleans up their stash files — used
# when switching away from a project (see MainWindow._reset_session_state)
# so stash files don't accumulate on disk for a project that's no longer
# open. Unlike clearing _stack directly, this actually frees the files.
func clear_all() -> void:
	for e in _stack:
		_cleanup(e as Entry)
	_stack.clear()

# --- internals ---------------------------------------------------------------

func _resolve(project_root: String, raw_path: String) -> String:
	var root := project_root.replace("\\", "/").simplify_path().rstrip("/")
	var normalized := raw_path.strip_edges()
	if normalized.begins_with("res://"):
		normalized = normalized.substr(6)
	elif normalized.begins_with("user://"):
		return ""
	while normalized.begins_with("/") or normalized.begins_with("\\"):
		normalized = normalized.substr(1)
	var combined := root.path_join(normalized).replace("\\", "/").simplify_path()
	if combined != root and not combined.begins_with(root + "/"):
		return ""
	return combined

func _read_file(abs_path: String) -> String:
	var f := FileAccess.open(abs_path, FileAccess.READ)
	if f == null:
		return ""
	var c := f.get_as_text()
	f.close()
	return c

func _stash_from_text(content: String) -> String:
	_counter += 1
	var dir := "%s/%d_%d" % [CHECKPOINT_ROOT, Time.get_unix_time_from_system(), _counter]
	DirAccess.make_dir_recursive_absolute(dir)
	# Each call gets its own directory, so "content.txt" (not "before.txt")
	# is accurate whether this stash holds before- or after-edit content —
	# see snapshot() and commit() above, the two callers.
	var dest := dir.path_join("content.txt")
	var out := FileAccess.open(dest, FileAccess.WRITE)
	if out == null:
		return ""
	out.store_string(content)
	out.close()
	return dest

func _cleanup(e: Entry) -> void:
	if e == null:
		return
	_remove_stash(e.snapshot_path)
	_remove_stash(e.after_snapshot_path)

func _remove_stash(path: String) -> void:
	if path == "":
		return
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)
	# Best-effort: remove the now-empty stash directory.
	var dir := path.get_base_dir()
	var d := DirAccess.open(dir)
	if d != null:
		d.list_dir_begin()
		var has_any := d.get_next() != ""
		d.list_dir_end()
		if not has_any:
			DirAccess.remove_absolute(dir)
