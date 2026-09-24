class_name AgentState
extends RefCounted

enum State {
	IDLE,
	THINKING,
	WAITING_FOR_TOOL,
	EXECUTING_TOOL,
	WAITING_FOR_APPROVAL,
	VERIFYING,
	COMPACTING,
	COMPLETED,
	# Terminal alternatives to COMPLETED — see AgentLoop._classify_completion().
	# Before these existed, a task the model quietly abandoned, or one where
	# it stopped to ask the user something, both reported as COMPLETED,
	# which is exactly the "no fake success" rule everything else in this
	# harness (check_script/check_project/launch_headless output scanning)
	# exists to avoid.
	BLOCKED,   # model stopped because it needs information only the user can give
	GAVE_UP,   # model could not complete an actionable task and stopped anyway
	FAILED,
	CANCELLED,
}

signal state_changed(previous: State, current: State)

var current: State = State.IDLE:
	set(value):
		if value == current:
			return
		var previous := current
		current = value
		state_changed.emit(previous, current)

static func name_of(state: State) -> String:
	return State.keys()[state]
