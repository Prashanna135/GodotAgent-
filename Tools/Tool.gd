class_name Tool
extends RefCounted

var name: String = ""
var description: String = ""
var input_schema: Dictionary = {}
var required_permission: String = ""

# Injected by the harness when a project is opened.
var project_root: String = ""

func execute(_arguments: Dictionary) -> ToolResult:
	return ToolResult.failure("Tool.execute not implemented")

func schema() -> Dictionary:
	return {
		"type": "function",
		"function": {
			"name": name,
			"description": description,
			"parameters": input_schema,
		},
	}
