class_name ContextManager
extends RefCounted

const DEFAULT_MAX_TOKENS := 100_000
# Never drop the last N non-system messages, even if the estimate lies.
const KEEP_TAIL := 6

var system_prompt: String = ""
var project_instructions: String = ""
# Populated by MainWindow at project-open time from ProjectScanner.scan().
# Fixed leading system message — survives compaction untouched.
var project_files_summary: String = ""

var last_compaction_dropped: int = 0

func build(conversation: Conversation, max_tokens: int = DEFAULT_MAX_TOKENS) -> Array:
	var out: Array = []
	if system_prompt != "":
		out.append({"role": "system", "content": system_prompt})
	if project_instructions != "":
		out.append({"role": "system", "content": project_instructions})
	if project_files_summary != "":
		out.append({"role": "system", "content": project_files_summary})
	for m in conversation.messages:
		out.append(m.to_dict())

	last_compaction_dropped = 0
	if TokenEstimator.estimate_messages(out) > max_tokens:
		out = _compact(out, max_tokens)
	return out

func _compact(messages: Array, max_tokens: int) -> Array:
	# Split leading system messages from the rest.
	var systems: Array = []
	var rest: Array = []
	var still_system := true
	for m in messages:
		var role := str((m as Dictionary).get("role", ""))
		if still_system and role == "system":
			systems.append(m)
		else:
			still_system = false
			rest.append(m)

	var sys_tokens := TokenEstimator.estimate_messages(systems)
	var budget := maxi(500, max_tokens - sys_tokens)

	var n := rest.size()
	var start := n
	# Walk backwards; only stop at turn boundaries (user, or assistant
	# without tool_calls) so we never orphan a tool_call / tool_result pair.
	for i in range(n - 1, -1, -1):
		var m: Dictionary = rest[i]
		var role := str(m.get("role", ""))
		var has_calls := _has_tool_calls(m)
		var is_boundary := role == "user" or (role == "assistant" and not has_calls)
		if not is_boundary:
			continue
		var candidate: Array = rest.slice(i)
		if TokenEstimator.estimate_messages(candidate) <= budget:
			start = i
		else:
			break

	# Always keep at least the tail.
	if n - start < KEEP_TAIL:
		start = maxi(0, n - KEEP_TAIL)

	var out: Array = []
	out.append_array(systems)
	if start > 0:
		last_compaction_dropped = start
		out.append({
			"role": "system",
			"content": ("[compacted: %d earlier message(s) dropped to stay under the "
				+ "context budget. Re-read files with tools if you need details.]") % start,
		})
	out.append_array(rest.slice(start))
	return out

static func _has_tool_calls(m: Dictionary) -> bool:
	var tc: Variant = m.get("tool_calls", null)
	return typeof(tc) == TYPE_ARRAY and not (tc as Array).is_empty()
