class_name Conversation
extends RefCounted

enum Role { SYSTEM, USER, ASSISTANT, TOOL }

class Message:
	extends RefCounted
	var role: Role
	var content: String
	var tool_calls: Array = []
	var tool_call_id: String = ""
	var name: String = ""

	func _init(p_role: Role, p_content: String) -> void:
		role = p_role
		content = p_content

	func to_dict() -> Dictionary:
		var role_name: String = str(Conversation.Role.keys()[role]).to_lower()
		var d := {}
		if role == Role.ASSISTANT and content.strip_edges() == "" and not tool_calls.is_empty():
			d["content"] = null
		else:
			d["content"] = content
		d["role"] = role_name
		if not tool_calls.is_empty():
			d["tool_calls"] = tool_calls
		if tool_call_id != "":
			d["tool_call_id"] = tool_call_id
		if name != "":
			d["name"] = name
		return d

var messages: Array[Message] = []

func add_system(content: String) -> void:
	messages.append(Message.new(Role.SYSTEM, content))

func add_user(content: String) -> void:
	messages.append(Message.new(Role.USER, content))

func add_assistant(content: String, tool_calls: Array = []) -> void:
	var m: Message = Message.new(Role.ASSISTANT, content)
	m.tool_calls = tool_calls
	messages.append(m)

func add_tool(content: String, tool_call_id: String, tool_name: String) -> void:
	var m: Message = Message.new(Role.TOOL, content)
	m.tool_call_id = tool_call_id
	m.name = tool_name
	messages.append(m)

func to_array() -> Array:
	var out: Array = []
	for m in messages:
		out.append(m.to_dict())
	return out

# Reverse of to_array() — rebuilds `messages` from a previously-saved array
# of dicts in that same shape (see SessionManager / MainWindow._resume_session).
# Replaces the current message list entirely; callers that want to preserve
# in-flight state should not call this mid-turn.
func load_from_array(arr: Array) -> void:
	messages.clear()
	var role_keys := Role.keys()
	for item_v in arr:
		if typeof(item_v) != TYPE_DICTIONARY:
			continue
		var d: Dictionary = item_v
		var role_name := str(d.get("role", "user")).to_upper()
		var role := Role.USER
		for i in role_keys.size():
			if role_keys[i] == role_name:
				role = i
				break
		var content_v: Variant = d.get("content", "")
		var content := "" if content_v == null else str(content_v)
		var m := Message.new(role, content)
		var tc_v: Variant = d.get("tool_calls", [])
		if typeof(tc_v) == TYPE_ARRAY:
			m.tool_calls = tc_v
		m.tool_call_id = str(d.get("tool_call_id", ""))
		m.name = str(d.get("name", ""))
		messages.append(m)
