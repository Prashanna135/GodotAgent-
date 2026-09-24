class_name RevertLastChangeTool
extends Tool

# Injected by the harness (see MainWindow._setup_agent).
var checkpoint_manager: CheckpointManager = null

func _init() -> void:
	name = "revert_last_change"
	description = (
		"Undo the most recent file-modifying call (write/create/edit/delete_file), "
		+ "restoring the file to its prior state. Call again to step back further. "
		+ "Prefer this over manually reconstructing previous content."
	)
	required_permission = "WRITE_PROJECT"
	input_schema = {
		"type": "object",
		"properties": {},
	}

func execute(_arguments: Dictionary) -> ToolResult:
	if checkpoint_manager == null:
		return ToolResult.failure("Checkpoint manager is not available", ToolResult.ErrorKind.INTERNAL)
	if not checkpoint_manager.has_checkpoints():
		return ToolResult.not_found("No checkpoints recorded yet — nothing to revert.")

	var res: Dictionary = checkpoint_manager.revert_last()
	if bool(res.get("success", false)):
		return ToolResult.ok(str(res.get("message", "Reverted.")), {"path": res.get("path", "")})
	return ToolResult.failure(str(res.get("message", "Revert failed.")), ToolResult.ErrorKind.IO_ERROR)
