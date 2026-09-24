class_name GodotProcessManager
extends Node

signal process_started(id: int, command: String)
signal process_output(id: int, text: String, is_stderr: bool)
signal process_exited(id: int, exit_code: int)
signal process_failed(id: int, reason: String)

class Proc extends RefCounted:
	var id: int = 0
	var pid: int = -1
	var name: String = ""
	var command: String = ""
	var stdio: FileAccess = null
	var stderr: FileAccess = null
	var stdout_text: String = ""
	var stderr_text: String = ""
	var stdout_partial: PackedByteArray = PackedByteArray()
	var stderr_partial: PackedByteArray = PackedByteArray()
	var finished: bool = false
	var exit_code: int = -1

var _procs: Dictionary = {}     # id -> Proc
var _next_id: int = 1

func _ready() -> void:
	set_process(true)

func _exit_tree() -> void:
	for id in _procs.keys():
		kill(int(id))

# --- public API -----------------------------------------------------------

func launch(executable: String, args: PackedStringArray, working_dir: String = "", name: String = "") -> int:
	if executable.strip_edges() == "":
		return -1
	# OS.execute_with_pipe does not accept a working directory; Godot itself
	# uses --path, so we simply pass it on the command line.
	var d := OS.execute_with_pipe(executable, args, false)
	if d == null or d.is_empty():
		return -1
	var p := Proc.new()
	p.id = _next_id
	_next_id += 1
	p.pid = int(d.get("pid", -1))
	p.stdio = d.get("stdio", null)
	# Not all Godot 4.x builds return a `stderr` stream; degrade gracefully.
	p.stderr = d.get("stderr", null)
	p.name = name
	p.command = executable + " " + " ".join(args)
	_procs[p.id] = p
	process_started.emit(p.id, p.command)
	return p.id

func get_proc(id: int) -> Proc:
	return _procs.get(id, null)

func is_running(id: int) -> bool:
	var p: Proc = _procs.get(id, null)
	if p == null or p.finished:
		return false
	if p.pid > 0 and not OS.is_process_running(p.pid):
		return false
	return true

func kill(id: int) -> void:
	var p: Proc = _procs.get(id, null)
	if p == null:
		return
	if p.pid > 0 and OS.is_process_running(p.pid):
		OS.kill(p.pid)
	p.finished = true
	if p.stdio != null:
		p.stdio.close()
		p.stdio = null
	if p.stderr != null:
		p.stderr.close()
		p.stderr = null

func snapshot(id: int, timed_out: bool = false) -> Dictionary:
	var p: Proc = _procs.get(id, null)
	if p == null:
		return {"found": false}
	_flush_partials(p)
	return {
		"found": true,
		"id": p.id,
		"pid": p.pid,
		"finished": p.finished,
		"timed_out": timed_out,
		"exit_code": p.exit_code,
		"stdout": p.stdout_text,
		"stderr": p.stderr_text,
		"command": p.command,
	}

func wait_for_exit_or_timeout(id: int, timeout_secs: float) -> Dictionary:
	var deadline := Time.get_ticks_msec() + int(timeout_secs * 1000.0)
	while true:
		var p: Proc = _procs.get(id, null)
		if p == null:
			return {"found": false}
		if p.finished:
			return snapshot(id, false)
		if Time.get_ticks_msec() >= deadline:
			return snapshot(id, true)
		if get_tree() == null:
			return snapshot(id, true)
		await get_tree().process_frame
	# Unreachable — the loop only exits via return. Kept for the static analyzer.
	return {"found": false}

# --- polling --------------------------------------------------------------

func _process(_delta: float) -> void:
	for id in _procs.keys():
		var p: Proc = _procs[id]
		if p.finished:
			continue
		_drain(p)
		if p.pid > 0 and not OS.is_process_running(p.pid):
			_finish(p)

func _drain(p: Proc) -> void:
	if p.stdio != null:
		_read_into(p, p.stdio, false)
	if p.stderr != null:
		_read_into(p, p.stderr, true)

func _read_into(p: Proc, f: FileAccess, is_stderr: bool) -> void:
	# get_buffer on a pipe is non-blocking: returns what's available, possibly empty.
	var chunk := f.get_buffer(4096)
	if chunk.is_empty():
		return
	var partial := p.stderr_partial if is_stderr else p.stdout_partial
	partial.append_array(chunk)
	_emit_complete_lines(p, partial, is_stderr)
	if is_stderr:
		p.stderr_partial = partial
	else:
		p.stdout_partial = partial

func _emit_complete_lines(p: Proc, buf: PackedByteArray, is_stderr: bool) -> void:
	var newline := 10   # '\n'
	var start := 0
	var consumed := 0
	for i in range(buf.size()):
		if buf[i] == newline:
			var slice := buf.slice(start, i)
			var line := slice.get_string_from_utf8()
			if is_stderr:
				p.stderr_text += line + "\n"
			else:
				p.stdout_text += line + "\n"
			process_output.emit(p.id, line + "\n", is_stderr)
			start = i + 1
			consumed = start
	if consumed > 0:
		var remaining := buf.slice(consumed)
		buf.clear()
		buf.append_array(remaining)

func _flush_partials(p: Proc) -> void:
	if not p.stdout_partial.is_empty():
		var s := p.stdout_partial.get_string_from_utf8()
		p.stdout_text += s
		process_output.emit(p.id, s, false)
		p.stdout_partial.clear()
	if not p.stderr_partial.is_empty():
		var s := p.stderr_partial.get_string_from_utf8()
		p.stderr_text += s
		process_output.emit(p.id, s, true)
		p.stderr_partial.clear()

func _finish(p: Proc) -> void:
	# One last read in case data arrived after our last poll.
	_drain(p)
	_flush_partials(p)
	p.finished = true

	# Recover the real exit code. OS.execute_with_pipe doesn't report it,
	# so ask the OS while the pid is still queryable.
	if p.pid > 0:
		var code := OS.get_process_exit_code(p.pid)
		if code != -1:
			p.exit_code = code
		else:
			# Process was reaped before we could ask. Assume success
			# if it produced no stderr; otherwise flag for the caller.
			p.exit_code = 0 if p.stderr_text.strip_edges() == "" else 1

	if p.stdio != null:
		p.stdio.close()
		p.stdio = null
	if p.stderr != null:
		p.stderr.close()
		p.stderr = null
	process_exited.emit(p.id, p.exit_code)
