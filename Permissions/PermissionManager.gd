class_name PermissionManager
extends RefCounted

enum Decision { ALLOW, ASK, BLOCK }

# Defaults per spec §13.
var _rules: Dictionary = {
	"READ_PROJECT": Decision.ALLOW,
	"WRITE_PROJECT": Decision.ALLOW,
	"DELETE_PROJECT_FILE": Decision.ASK,
	"RUN_GODOT": Decision.ALLOW,
	"RUN_TERMINAL": Decision.ASK,
	"NETWORK_ACCESS": Decision.ASK,
	"READ_OUTSIDE_PROJECT": Decision.BLOCK,
	"WRITE_OUTSIDE_PROJECT": Decision.BLOCK,
}

func decide(permission: String) -> Decision:
	return _rules.get(permission, Decision.ASK)

func set_decision(permission: String, decision: Decision) -> void:
	_rules[permission] = decision
