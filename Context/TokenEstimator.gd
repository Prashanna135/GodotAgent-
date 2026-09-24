class_name TokenEstimator
extends RefCounted

# Deliberately rough: ~4 chars/token for English + code.
static func estimate(text: String) -> int:
	return int(ceil(text.length() / 4.0))

static func estimate_messages(messages: Array) -> int:
	var total := 0
	for m in messages:
		total += estimate(str(m.get("content", ""))) + 4
	return total
