class_name LLMResponse
extends RefCounted

var text: String = ""
var tool_calls: Array = []   # [{id: String, name: String, arguments: Dictionary}]
var stop_reason: String = ""
var usage: Dictionary = {}
var raw: Dictionary = {}
