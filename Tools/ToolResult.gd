class_name ToolResult
extends RefCounted

enum ErrorKind {
	NONE,                # success
	NOT_FOUND,           # file / symbol / dir missing
	INVALID_ARGUMENT,    # bad or missing argument
	PERMISSION_DENIED,   # user refused, or blocked by policy
	SANDBOX_VIOLATION,   # path escaped project root
	IO_ERROR,            # file open/read/write failed
	TIMEOUT,             # subprocess or network timeout
	CANCELLED,           # user aborted
	REPEATED_CALL,       # identical tool call already made recently
	INTERNAL,            # bug / unexpected state
}

var success: bool = true
var output: String = ""
var error: String = ""
var error_kind: ErrorKind = ErrorKind.NONE
var metadata: Dictionary = {}

static func ok(output_text: String, meta: Dictionary = {}) -> ToolResult:
	var r := ToolResult.new()
	r.success = true
	r.output = output_text
	r.metadata = meta
	return r

static func failure(
		error_text: String,
		kind: ErrorKind = ErrorKind.INTERNAL,
		meta: Dictionary = {}
) -> ToolResult:
	var r := ToolResult.new()
	r.success = false
	r.error = error_text
	r.error_kind = kind
	r.metadata = meta
	return r

# Convenience constructors used by the new tools.
static func not_found(msg: String, meta: Dictionary = {}) -> ToolResult:
	return failure(msg, ErrorKind.NOT_FOUND, meta)

static func invalid_argument(msg: String, meta: Dictionary = {}) -> ToolResult:
	return failure(msg, ErrorKind.INVALID_ARGUMENT, meta)

static func permission_denied(msg: String, meta: Dictionary = {}) -> ToolResult:
	return failure(msg, ErrorKind.PERMISSION_DENIED, meta)

static func sandbox_violation(msg: String, meta: Dictionary = {}) -> ToolResult:
	return failure(msg, ErrorKind.SANDBOX_VIOLATION, meta)

static func io_error(msg: String, meta: Dictionary = {}) -> ToolResult:
	return failure(msg, ErrorKind.IO_ERROR, meta)

static func timeout(msg: String, meta: Dictionary = {}) -> ToolResult:
	return failure(msg, ErrorKind.TIMEOUT, meta)

static func cancelled(msg: String, meta: Dictionary = {}) -> ToolResult:
	return failure(msg, ErrorKind.CANCELLED, meta)

static func repeated_call(msg: String, meta: Dictionary = {}) -> ToolResult:
	return failure(msg, ErrorKind.REPEATED_CALL, meta)

func kind_name() -> String:
	return ErrorKind.keys()[error_kind]

func describe() -> String:
	if success:
		return output
	return "ERROR[%s]: %s" % [kind_name(), error]
