class_name ToolManager
extends RefCounted

signal approval_requested(tool_name: String, arguments: Dictionary, permission: String)
signal approval_answered(approved: bool)

var permissions := PermissionManager.new()

# Optional — injected by the harness. When set, a snapshot is taken before
# any tool in CHECKPOINT_TOOL_NAMES runs, committed on success, discarded on
# failure/no-op. See CheckpointManager.gd and RevertLastChangeTool.gd.
var checkpoint_manager: CheckpointManager = null
const CHECKPOINT_TOOL_NAMES := ["write_file", "create_file", "edit_file", "edit_file_lines", "delete_file"]

var _tools: Dictionary = {}   # name -> Tool
var _awaiting_approval: bool = false

func register(tool: Tool) -> void:
	_tools[tool.name] = tool

# Drops a tool from the registry so its schema stops being sent to the model
# and it can no longer be invoked. Used for user-controlled tool pruning
# (see MainWindow._apply_tool_registration) — the tool instance itself is
# untouched, so re-registering it later (register()) picks up right where
# it left off.
func unregister(tool_name: String) -> void:
	_tools.erase(tool_name)

func has(tool_name: String) -> bool:
	return _tools.has(tool_name)

func get_tool(tool_name: String) -> Tool:
	var v: Variant = _tools.get(tool_name, null)
	return v as Tool

func all_schemas() -> Array:
	var out: Array = []
	for v in _tools.values():
		var t := v as Tool
		if t != null:
			out.append(t.schema())
	return out

func each_tool(cb: Callable) -> void:
	for v in _tools.values():
		var t := v as Tool
		if t != null:
			cb.call(t)

# --- approval plumbing ----------------------------------------------------

# Called by the UI once the user clicks Allow/Deny.
func respond_approval(approved: bool) -> void:
	if not _awaiting_approval:
		return
	_awaiting_approval = false
	approval_answered.emit(approved)

func is_awaiting_approval() -> bool:
	return _awaiting_approval

func _request_approval(tool_name: String, arguments: Dictionary, permission: String) -> bool:
	_awaiting_approval = true
	approval_requested.emit(tool_name, arguments, permission)
	var approved: bool = await approval_answered
	return approved

# --- execution ------------------------------------------------------------

func execute(tool_name: String, arguments: Dictionary) -> ToolResult:
	var v: Variant = _tools.get(tool_name, null)
	var tool := v as Tool
	if tool == null:
		return ToolResult.invalid_argument("Unknown tool: %s" % tool_name)

	var perm := tool.required_permission
	if perm != "":
		var decision := permissions.decide(perm)
		if decision == PermissionManager.Decision.BLOCK:
			return ToolResult.permission_denied(
				"Tool '%s' is blocked by policy (permission %s)" % [tool_name, perm]
			)
		if decision == PermissionManager.Decision.ASK:
			var approved: bool = await _request_approval(tool_name, arguments, perm)
			if not approved:
				return ToolResult.cancelled(
					"User denied permission '%s' for tool '%s'" % [perm, tool_name]
				)

	var checkpoint_entry = null
	if checkpoint_manager != null and tool_name in CHECKPOINT_TOOL_NAMES:
		var raw_path := str(arguments.get("path", ""))
		if raw_path != "":
			checkpoint_entry = checkpoint_manager.snapshot(tool_name, tool.project_root, raw_path)

	var result: ToolResult = await tool.execute(arguments)
	if result == null:
		result = ToolResult.failure(
			"Tool '%s' returned null" % tool_name, ToolResult.ErrorKind.INTERNAL
		)

	if checkpoint_entry != null:
		if result.success:
			checkpoint_manager.commit(checkpoint_entry)
		else:
			checkpoint_manager.discard(checkpoint_entry)

	return result
