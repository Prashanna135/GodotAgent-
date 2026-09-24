class_name UpdatePlanTool
extends Tool

# Injected by the harness (see MainWindow._setup_agent).
var plan_store: PlanStore = null

func _init() -> void:
	name = "update_plan"
	description = (
		"Mark a single plan step's status. Use for routine progress updates; "
		+ "call write_plan only when the plan itself changes."
	)
	required_permission = ""
	input_schema = {
		"type": "object",
		"properties": {
			"id": {"type": "string", "description": "The step id, as shown by write_plan's result."},
			"status": {
				"type": "string",
				"enum": ["pending", "in_progress", "done", "blocked"],
			},
		},
		"required": ["id", "status"],
	}

func execute(arguments: Dictionary) -> ToolResult:
	if plan_store == null:
		return ToolResult.failure("Plan store is not available", ToolResult.ErrorKind.INTERNAL)
	if plan_store.is_empty():
		return ToolResult.not_found("No plan has been set yet — call write_plan first.")

	var id := str(arguments.get("id", "")).strip_edges()
	if id == "":
		return ToolResult.invalid_argument("Missing required argument: id")
	var status := str(arguments.get("status", "")).strip_edges()
	if status == "":
		return ToolResult.invalid_argument("Missing required argument: status")

	var ok := plan_store.update_status(id, status)
	if not ok:
		return ToolResult.not_found(
			"No plan step with id '%s', or '%s' is not a valid status." % [id, status]
		)
	return ToolResult.ok("Updated %s -> %s\n%s" % [id, status, plan_store.describe()])
