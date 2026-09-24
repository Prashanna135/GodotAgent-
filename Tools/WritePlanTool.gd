class_name WritePlanTool
extends Tool

# Injected by the harness (see MainWindow._setup_agent).
var plan_store: PlanStore = null

func _init() -> void:
	name = "write_plan"
	description = (
		"Set or replace the task plan. Call once you have a concrete multi-step "
		+ "approach, and again only if it changes significantly. Use update_plan "
		+ "for routine status updates instead."
	)
	required_permission = ""
	input_schema = {
		"type": "object",
		"properties": {
			"steps": {
				"type": "array",
				"description": (
					"Plan steps, in order. Each item is either a plain string, or an "
					+ "object {id, text, status} if you want to set an explicit id or "
					+ "initial status (default status is 'pending')."
				),
				"items": {
					"type": ["string", "object"],
					"properties": {
						"id": {"type": "string"},
						"text": {"type": "string"},
						"status": {
							"type": "string",
							"enum": ["pending", "in_progress", "done", "blocked"],
						},
					},
				},
			},
		},
		"required": ["steps"],
	}

func execute(arguments: Dictionary) -> ToolResult:
	if plan_store == null:
		return ToolResult.failure("Plan store is not available", ToolResult.ErrorKind.INTERNAL)
	var steps_v: Variant = arguments.get("steps", [])
	if typeof(steps_v) != TYPE_ARRAY:
		return ToolResult.invalid_argument("`steps` must be an array")
	var steps: Array = steps_v
	if steps.is_empty():
		return ToolResult.invalid_argument("`steps` must not be empty")

	plan_store.set_plan(steps)
	if plan_store.is_empty():
		return ToolResult.invalid_argument("Every step was empty after trimming — nothing was set")

	return ToolResult.ok(
		"Plan set (%d step(s)):\n%s" % [plan_store.steps.size(), plan_store.describe()]
	)
