class_name PlanStore
extends RefCounted

# Emitted whenever the plan is replaced or a step's status changes, so the UI
# can react without polling.
signal plan_changed()

const VALID_STATUSES := ["pending", "in_progress", "done", "blocked"]

var steps: Array = []   # Array[Dictionary] {id, text, status}

func set_plan(new_steps: Array) -> void:
	steps.clear()
	var auto_id := 1
	for s in new_steps:
		var text := ""
		var id := ""
		var status := "pending"
		if typeof(s) == TYPE_DICTIONARY:
			var d: Dictionary = s
			text = str(d.get("text", "")).strip_edges()
			id = str(d.get("id", "")).strip_edges()
			status = str(d.get("status", "pending")).strip_edges()
		else:
			text = str(s).strip_edges()
		if text == "":
			continue
		if id == "":
			id = "step_%d" % auto_id
		if not (status in VALID_STATUSES):
			status = "pending"
		steps.append({"id": id, "text": text, "status": status})
		auto_id += 1
	plan_changed.emit()

func update_status(id: String, status: String) -> bool:
	if not (status in VALID_STATUSES):
		return false
	for s in steps:
		var d: Dictionary = s
		if str(d.get("id", "")) == id:
			d["status"] = status
			plan_changed.emit()
			return true
	return false

func is_empty() -> bool:
	return steps.is_empty()

func progress() -> Dictionary:
	var done := 0
	for s in steps:
		if str((s as Dictionary).get("status", "")) == "done":
			done += 1
	return {"done": done, "total": steps.size()}

func describe() -> String:
	if steps.is_empty():
		return "No plan set."
	var lines := PackedStringArray()
	for s in steps:
		var d: Dictionary = s
		var mark := "[ ]"
		match str(d.get("status", "pending")):
			"in_progress":
				mark = "[~]"
			"done":
				mark = "[x]"
			"blocked":
				mark = "[!]"
		lines.append("%s %s — %s" % [mark, str(d.get("id", "")), str(d.get("text", ""))])
	return "\n".join(lines)
