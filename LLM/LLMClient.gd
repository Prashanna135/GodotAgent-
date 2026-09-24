class_name LLMClient
extends Node

signal response_received(response: LLMResponse)
signal request_failed(error: String)
# Emitted while backing off from a 429. `attempt` is 1-based, `delay` in seconds.
signal request_retrying(attempt: int, delay: float)

@export var endpoint: String = "https://api.openai.com/v1/chat/completions"
@export var api_key: String = ""
@export var model: String = "gpt-4o-mini"
# 0.0 disables the timeout entirely (waits indefinitely) — see cancel_pending()
# for how to bail out of a hung request when using that.
@export var request_timeout: float = 120.0:
	set(value):
		request_timeout = value
		if _http != null:
			_http.timeout = value

# When false, a 429 is surfaced to the caller immediately instead of going
# through the MAX_RETRIES/RETRY_DELAYS backoff below. Set false for the
# DeepSeek Web Bridge tier (see ModelProfile.retry_429_locally): the
# bridge already runs its own internal rate-limit cooldown-and-retry loop
# (30s → 60s → 120s, up to 3 attempts) before it ever returns a 429 to
# Godot, so a second independent backoff schedule here only stacks more
# duplicate sends into the same DeepSeek chat thread on top of the
# bridge's own, much longer one.
@export var retry_on_429: bool = true

const MAX_RETRIES := 3
const RETRY_DELAYS := [5.0, 15.0, 45.0]

var _http: HTTPRequest
var _pending: bool = false

var _retry_count: int = 0
var _last_messages: Array = []
var _last_tools: Array = []

func _ready() -> void:
	_http = HTTPRequest.new()
	_http.timeout = request_timeout
	add_child(_http)
	_http.request_completed.connect(_on_request_completed)

func send(messages: Array, tools: Array) -> void:
	if _pending:
		request_failed.emit("A request is already in flight")
		return
	_last_messages = messages
	_last_tools = tools
	_retry_count = 0
	_dispatch(messages, tools)

# Aborts an in-flight request. HTTPRequest.cancel_request() does NOT emit
# request_completed, so we emit request_failed ourselves — AgentLoop already
# guards against acting on this if stop() ran first (the normal path).
func cancel_pending() -> void:
	if not _pending:
		return
	_http.cancel_request()
	_pending = false
	request_failed.emit("Request cancelled by user")

func is_pending() -> bool:
	return _pending

func _dispatch(messages: Array, tools: Array) -> void:
	var body := _build_body(messages, tools)
	var headers := PackedStringArray([
		"Content-Type: application/json",
		"Authorization: Bearer " + api_key,
	])
	var err := _http.request(endpoint, headers, HTTPClient.METHOD_POST, JSON.stringify(body))
	if err != OK:
		request_failed.emit("HTTPRequest failed to start: %d" % err)
		return
	_pending = true

func _build_body(messages: Array, tools: Array) -> Dictionary:
	var body := {"model": model, "messages": messages}
	if not tools.is_empty():
		body["tools"] = tools
	return body

func _on_request_completed(result: int, code: int, headers: PackedStringArray, body: PackedByteArray) -> void:
	_pending = false
	if result != HTTPRequest.RESULT_SUCCESS:
		if result == HTTPRequest.RESULT_TIMEOUT:
			var timeout_desc := "disabled" if request_timeout <= 0.0 else "%.0fs" % request_timeout
			request_failed.emit(
				"Request timed out (limit: %s, result=TIMEOUT). The connection was fine but no response arrived in time." % timeout_desc
			)
		else:
			request_failed.emit("HTTP transport error: %d" % result)
		return
	var text := body.get_string_from_utf8()

	if code == 429:
		_handle_rate_limit(headers, text)
		return

	if code < 200 or code >= 300:
		request_failed.emit("HTTP %d: %s" % [code, text])
		return
	var parsed = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		request_failed.emit("Invalid JSON response from provider")
		return
	var resp := _parse_openai_response(parsed)
	resp.raw = parsed
	response_received.emit(resp)

func _handle_rate_limit(headers: PackedStringArray, body_text: String) -> void:
	# Daily quota exhaustion is not a transient rate limit. Retrying after
	# 5/15/45 seconds does nothing when the bucket resets tomorrow. Fail
	# immediately with a message that names the real problem, so the user
	# (or the agent, if it's mid-task) doesn't waste time waiting for a
	# retry that can't succeed.
	if _is_daily_quota_exhausted(body_text):
		request_failed.emit(
			"HTTP 429: Daily quota exhausted for this model (not a transient "
			+ "rate limit — retrying will not help until the quota resets). "
			+ "Provider response:\n" + body_text
		)
		return

	if not retry_on_429:
		request_failed.emit(
			"HTTP 429: Rate limited. Local retry is disabled for this "
			+ "provider — the endpoint already retries internally, so "
			+ "retrying again here would only double up. Provider response:\n"
			+ body_text
		)
		return

	if _retry_count >= MAX_RETRIES:
		request_failed.emit(
			"HTTP 429: Rate limit exceeded after %d retries: %s" % [MAX_RETRIES, body_text]
		)
		return
	var delay := _resolve_retry_delay(headers)
	_retry_count += 1
	request_retrying.emit(_retry_count, delay)

	var tree := get_tree()
	if tree == null:
		request_failed.emit("HTTP 429: cannot schedule retry — node not in tree")
		return
	await tree.create_timer(delay).timeout
	_dispatch(_last_messages, _last_tools)

# Google returns distinct fields for per-minute and per-day quota limits.
# The daily-exhaustion message always contains one of these markers; the
# per-minute rate limit message doesn't. Cheap substring matching is
# enough — the goal is to distinguish "wait 30 seconds" from "wait until
# tomorrow," not to parse the full JSON error shape.
static func _is_daily_quota_exhausted(body_text: String) -> bool:
	var lower := body_text.to_lower()
	return lower.find("perday") != -1 \
		or lower.find("per_day") != -1 \
		or lower.find("per day") != -1 \
		or lower.find("generate_content_free_tier_requests") != -1 \
		or lower.find("quotaid") != -1

# Prefer a server-provided hint (`Retry-After`, seconds) over our own
# backoff schedule. Falls back to RETRY_DELAYS with a little jitter so
# concurrent clients don't all retry on the same tick.
func _resolve_retry_delay(headers: PackedStringArray) -> float:
	for h in headers:
		var lower := h.to_lower()
		if lower.begins_with("retry-after:"):
			var v := h.substr(h.find(":") + 1).strip_edges()
			var f := v.to_float()
			if f > 0.0:
				return f
	var idx := clampi(_retry_count, 0, RETRY_DELAYS.size() - 1)
	var base_delay: float = RETRY_DELAYS[idx]
	var jitter := randf_range(0.0, base_delay * 0.2)
	return base_delay + jitter

func _parse_openai_response(parsed: Dictionary) -> LLMResponse:
	var resp := LLMResponse.new()
	var choices_v: Variant = parsed.get("choices", [])
	if typeof(choices_v) != TYPE_ARRAY:
		return resp
	var choices: Array = choices_v
	if choices.is_empty():
		return resp
	var choice_v: Variant = choices[0]
	if typeof(choice_v) != TYPE_DICTIONARY:
		return resp
	var choice: Dictionary = choice_v
	var msg_v: Variant = choice.get("message", {})
	if typeof(msg_v) != TYPE_DICTIONARY:
		return resp
	var msg: Dictionary = msg_v
	var content_v: Variant = msg.get("content", "")
	resp.text = "" if content_v == null else str(content_v)
	var fr_v: Variant = choice.get("finish_reason", "")
	resp.stop_reason = "" if fr_v == null else str(fr_v)
	var tcs_v: Variant = msg.get("tool_calls", [])
	if typeof(tcs_v) == TYPE_ARRAY:
		var tcs: Array = tcs_v
		for tc_v in tcs:
			if typeof(tc_v) != TYPE_DICTIONARY:
				continue
			var tc: Dictionary = tc_v
			var fn_v: Variant = tc.get("function", {})
			if typeof(fn_v) != TYPE_DICTIONARY:
				continue
			var fn: Dictionary = fn_v
			var args_str: String = str(fn.get("arguments", "{}"))
			var entry := {
				"id": str(tc.get("id", "")),
				"type": "function",
				"function": {
					"name": str(fn.get("name", "")),
					"arguments": args_str,
				},
			}
			# Gemini 3.x: preserve thought_signature round-trip
			var extra_v: Variant = tc.get("extra_content", null)
			if typeof(extra_v) == TYPE_DICTIONARY:
				entry["extra_content"] = extra_v
			resp.tool_calls.append(entry)
	var usage_v: Variant = parsed.get("usage", {})
	if typeof(usage_v) == TYPE_DICTIONARY:
		resp.usage = usage_v
	return resp
