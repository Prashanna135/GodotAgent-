class_name DebugEvent
extends RefCounted

# A single normalized issue extracted from Godot's raw stdout/stderr.
# Deliberately a plain data holder — parsing lives in ErrorParser, this
# class only knows how to describe itself.

enum Severity { ERROR, WARNING, INFO }
enum Source { PARSE, LOAD, RUNTIME, UNKNOWN }

var severity: Severity = Severity.ERROR
var source: Source = Source.UNKNOWN
var file: String = ""          # res:// path, or "" if unavailable
var line: int = 0              # 0 if unavailable
var column: int = 0            # rarely populated by Godot; kept for future use
var message: String = ""
var raw: String = ""           # original line(s), for debug/fallback

func location() -> String:
	if file == "":
		return "?"
	if line > 0:
		return "%s:%d" % [file, line]
	return file

func to_summary() -> String:
	return "[%s] %s  %s" % [
		Severity.keys()[severity].to_lower(),
		location(),
		message,
	]

func to_dict() -> Dictionary:
	return {
		"severity": Severity.keys()[severity].to_lower(),
		"source": Source.keys()[source].to_lower(),
		"file": file,
		"line": line,
		"column": column,
		"message": message,
	}
