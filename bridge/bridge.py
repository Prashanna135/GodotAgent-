"""
DeepSeek Web Chat Bridge
========================

Drives a real, logged-in browser session against chat.deepseek.com via
Playwright, and exposes an OpenAI-compatible `/v1/chat/completions`
endpoint on localhost. This lets GodotAgent's existing LLMClient.gd talk
to it with ZERO Godot-side code changes — LLMClient already builds an
OpenAI-shaped request body and parses an OpenAI-shaped response; this
bridge just needs to speak that same shape back.

Architecture (see handoff doc, Section 4 "Strategy A"):
    Godot LLMClient.gd  --HTTP-->  this bridge (FastAPI)
                                        |
                                        v
                                   Playwright (real Chromium,
                                   persistent logged-in profile)
                                        |
                                        v
                                 chat.deepseek.com
                                 (page's own JS solves the
                                 PoW challenge, handles auth,
                                 threads the conversation)

We do NOT reconstruct DeepSeek's internal request shape or solve its
proof-of-work challenge ourselves — we type into the real chat input and
press Enter, exactly like a human, and just listen to the network
response that the page's own JS triggers. This is the only strategy the
handoff doc did not reject.

No tool-calling protocol is implemented on the Python side. DeepSeek's
plain-text reply is returned verbatim as `choices[0].message.content`;
AgentLoop.gd's synthetic-recovery path (`_extract_recovered_calls`)
parses the tagged format defined below out of that text and executes the
calls as real tool calls. Set the Godot Settings dialog's "Model tier"
to *Web Chat* (or leave it on Auto and name the model anything containing
"deepseek-web") so that recovery path is enabled with a high cap and the
bridge-specific protocol section is injected into the system prompt.

    TOOL: read_file
    ARGS: {"path": "res://Player.gd"}

That is the ONLY format this bridge asks for. It is deliberately not
bare-JSON: a `TOOL:` line is not a token DeepSeek's web chat would ever
emit as incidental prose, so the protocol survives the model's strong
prose instinct in a way that "please output one bare JSON object and
nothing else" does not. AgentLoop also keeps a legacy bare-JSON parser
as a fallback, so a model that reverts gets recovered anyway — but the
instruction here is tagged-only.

RATE LIMITING
-------------
DeepSeek's free web chat throttles rapid message sends ("Messages too
frequent. Try again later."). A coding turn does 5-15 tool-call round
trips, each of which is one DeepSeek message, so the limit is hit almost
immediately without mitigation. This bridge:

  1. Enforces a minimum gap between consecutive sends (MIN_SEND_GAP_SECS).
  2. Detects the rate-limit response (HTTP 429, or the error text in the
     body), waits a cooldown, and retries the SAME prompt internally
     without telling Godot — up to RATE_LIMIT_MAX_RETRIES times, with
     exponential backoff.
  3. If internal retries are exhausted, returns a real HTTP 429 to Godot.

On the WEB_CHAT tier Godot's own 429 backoff is disabled
(ModelProfile.retry_429_locally = false -> LLMClient.retry_on_429 =
false), so step 3 is terminal: the bridge is the single retry authority,
and stacking Godot's shorter schedule on top would only re-type the same
prompt into the same DeepSeek thread at an interval DeepSeek has just
rejected. On every other tier LLMClient's own backoff still applies, for
endpoints without a bridge in front of them.

MESSAGE-SIZE BUDGET
-------------------
Playwright types one CDP event per character, so a 200KB prompt takes
100+ seconds to type before DeepSeek even starts responding. And the
model's useful context is far smaller than its nominal window. This
bridge therefore:

  1. Caps any single TOOL result's rendered length (TOOL_RESULT_BRIDGE_CAP).
  2. Caps the total prompt length (MAX_PROMPT_CHARS). When a full resend
     exceeds that, `build_prompt_under_budget` drops middle messages and
     keeps the first user message (the original task) plus the most
     recent N messages.

Neither cap is a cure — they're safety nets. If you see the drops fire
often, investigate *why* the conversation is that big (see the request
log described below).

CONTROL CHARACTERS / MALFORMED JSON
-----------------------------------
Godot's `JSON.stringify` does not escape every C0 control character inside
string values. When a tool result contains raw subprocess output — most
notably `launch_headless --editor --quit`, whose output is full of ANSI
color escapes (ESC = 0x1B) — a raw 0x1B byte lands inside the request body.
Python's `json.loads` runs in strict mode by default and rejects raw
control characters with `JSONDecodeError: Invalid control character at:`.
That used to crash the entire request with an unhandled 500, and because
the offending tool result is already in the conversation, every subsequent
request carried the same byte and crashed the same way — the session died
permanently.

The fix has two halves:

  1. `chat_completions` parses the body via `_parse_request_body`, which
     retries with `json.loads(..., strict=False)` when the strict parse
     fails, and returns a clean HTTP 400 if even that fails. No more
     unhandled 500s.
  2. `_sanitize_messages` strips ANSI escapes and any remaining C0 control
     characters (except tab/newline/CR) from every incoming message's
     content before it's rendered into a prompt. So the model sees clean
     text, and the same bytes can't poison future requests via
     `_known_messages`.

Both are belt-and-braces. The Godot side should also strip ANSI in
AgentLoop._truncate_tool_result (see the Godot-side handoff), but the
bridge defends itself independently so a stale session resumed from
before that fix doesn't re-crash on load.

REQUEST LOGGING
---------------
Every DeepSeek send is logged:

  bridge_logs/index.jsonl      one line per send attempt, keyed by time
  bridge_logs/sse/<id>.sse     full prompt + raw SSE + parsed reply

index.jsonl is the greppable summary; the sse/ files are for when you
need to see exactly what DeepSeek sent back. Both are written by default
— set SAVE_RAW_SSE = False if you don't want the full-body files.

>>> SELECTORS BELOW ARE BEST-EFFORT PLACEHOLDERS. <<<
I (the assistant that wrote this file) cannot load chat.deepseek.com to
confirm its current DOM. Before first real use, run:

    playwright codegen https://chat.deepseek.com

and update SEL_CHAT_INPUT / SEL_NEW_CHAT_BUTTON below to match what
codegen records when you click the message box and the "New chat"
button. See README.md for the full walkthrough.
"""

from __future__ import annotations

import asyncio
import json
import os
import re
import time
import uuid
from contextlib import asynccontextmanager
from typing import Any

import uvicorn
from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse
from playwright.async_api import async_playwright, Page, BrowserContext, TimeoutError as PWTimeout

# --------------------------------------------------------------------------
# Config — edit these to taste.
# --------------------------------------------------------------------------

DEEPSEEK_URL = "https://chat.deepseek.com/"
USER_DATA_DIR = r"C:\Users\magar\deepseek_chrome_profile"       # persistent login lives here
HOST = "127.0.0.1"
PORT = 5000

# Milliseconds to wait for a chat/completion network response. DeepThink /
# web-search modes can take a long time — keep this generous. This should
# be <= the timeout you set in Godot's Settings dialog (or set Godot's to
# 0 / unlimited and let this be the real ceiling).
RESPONSE_TIMEOUT_MS = 180_000

HEADLESS = False   # keep a real visible window so you can log in by hand

# Google's OAuth blocks sign-in from CDP-driven (automation-controlled)
# browsers outright — "This browser or app may not be secure" — regardless
# of which Chromium build runs it. If your DeepSeek account only has
# "Log in with Google" and no email/password option, the workaround is to
# reuse a real Chrome profile that's ALREADY logged into DeepSeek from
# normal, non-automated browsing, instead of authenticating inside this
# automated one at all.
#
# To do that:
#   1. Fully quit Chrome (it locks its profile directory while running).
#   2. Set BROWSER_CHANNEL = "chrome" below.
#   3. Set USER_DATA_DIR to your real Chrome "User Data" folder, e.g.:
#        Windows: C:/Users/<you>/AppData/Local/Google/Chrome/User Data
#        macOS:   ~/Library/Application Support/Google/Chrome
#        Linux:   ~/.config/google-chrome
#      (this loads whichever profile Chrome treats as default — usually
#      the one named "Default" inside that folder — bringing its cookies
#      and localStorage with it, so DeepSeek just sees an already-logged-in
#      session and never runs the Google flow at all)
#   4. Leave your normal Chrome closed while the bridge is running.
#
# Leave BROWSER_CHANNEL = None (and USER_DATA_DIR pointing at the small
# dedicated ./deepseek_profile folder) for email/password logins, or once
# you've logged in successfully at least once in the automated window.
BROWSER_CHANNEL: str | None = "chrome"   # set to "chrome" for the workaround above

# --- rate limiting -------------------------------------------------------
# Minimum wall-clock seconds between consecutive sends to DeepSeek. Counted
# from the moment the previous send's SSE stream CLOSED. DeepSeek's free
# tier tolerates a sustained rate around one message per ~10s before
# throttling; a coding turn of N tool calls wants to burst well above
# that, so this floor is set to keep us just under the trip point without
# being painful. Raise it if you still see "Messages too frequent"; 0
# disables the floor entirely.
MIN_SEND_GAP_SECS = 4.0

# When a rate-limit response is detected, wait this long before retrying
# the same prompt. Doubles on each consecutive retry, capped at
# RATE_LIMIT_MAX_COOLDOWN_SECS.
RATE_LIMIT_INITIAL_COOLDOWN_SECS = 30.0
RATE_LIMIT_MAX_COOLDOWN_SECS = 240.0

# How many times to retry a rate-limited send INSIDE the bridge before
# giving up and returning HTTP 429 to Godot. On the WEB_CHAT tier that
# 429 is terminal (LLMClient.retry_on_429 is false — see the module
# docstring), so this is the only retry schedule that runs. Each retry
# adds delay to the request's total wall-clock time — keep Godot's
# timeout high enough to absorb this.
RATE_LIMIT_MAX_RETRIES = 3

# Substrings that identify a rate-limit response when it arrives as HTTP
# 200 with an error message in the body (which is how DeepSeek's web
# frontend actually signals it — it's a normal SSE response, not a 429).
# Matched case-insensitively. Any of these in the response text triggers
# the cooldown-and-retry path.
RATE_LIMIT_MARKERS = [
	"messages too frequent",
	"try again later",
	"rate limit",
	"too many requests",
	"too many messages",
	"please slow down",
	"frequently",
]

# --- message-size budget -------------------------------------------------
# Hard ceiling on the prompt string the bridge will type into DeepSeek's
# input box. Above this, `build_prompt_under_budget` drops middle messages
# and keeps the first user message + the most recent N. 80_000 chars is
# ~20K tokens — fast to type (~10s), comfortably inside the model's useful
# context, and well under DeepSeek's 2.6M client-side cap.
MAX_PROMPT_CHARS = 80_000

# Hard ceiling on any single rendered TOOL result before it enters the
# prompt. Godot already truncates tool results (AgentLoop._truncate_tool_
# result), but session resumption loads old conversations where the cap
# wasn't applied. 20_000 chars is a generous read_file output; anything
# larger is almost certainly being truncated by the tool itself anyway.
TOOL_RESULT_BRIDGE_CAP = 20_000

# --- request logging -----------------------------------------------------
# Every send is logged. index.jsonl is one JSON line per attempt; the
# per-request SSE bodies go to sse/. Set SAVE_RAW_SSE = False to log
# only metrics (saves disk, loses the ability to debug a bad reply).
BRIDGE_LOG_DIR = "bridge_logs"
SAVE_RAW_SSE = True

# --- selectors (VERIFY THESE — see module docstring) ----------------------
SEL_CHAT_INPUT = "textarea, div[contenteditable='true']"
SEL_NEW_CHAT_BUTTON = "text=/new chat/i"

# --------------------------------------------------------------------------
# Control-character / malformed-JSON defence
# --------------------------------------------------------------------------
#
# Godot's JSON.stringify leaves raw C0 control characters (0x00–0x1F) inside
# string values unescaped. A tool result that captured subprocess output —
# most notably `launch_headless --editor --quit`, whose progress-bar output
# is full of ANSI escapes prefixed by raw ESC (0x1B) — therefore puts a raw
# control byte into the request body. Python's json.loads, strict by
# default, rejects those with JSONDecodeError; the bridge used to 500 on
# every subsequent request because the offending tool result was already in
# the conversation.
#
# Two layers of defence below:
#   1. _parse_request_body: tolerate the control characters rather than
#      crashing (strict=False fallback), and return a clean 400 if even
#      that fails.
#   2. _sanitize_messages: strip ANSI and any remaining C0 control
#      characters from every incoming message's content, so the model sees
#      clean text and the same bytes can't poison future requests via
#      _known_messages.

# ANSI/VT100 CSI sequence: ESC '[' followed by parameter bytes (digits and
# ';') then a final byte (letter). Matches the color and progress-bar
# escapes Godot emits.
ANSI_ESCAPE_RE = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")

def _sanitize_content(s: str) -> str:
	"""Strips ANSI escapes and stray C0 control characters from a string.

	ANSI escapes (ESC '[' ...) are removed whole. Any remaining control
	characters except tab (0x09), newline (0x0A) and carriage return (0x0D)
	are replaced with a space, preserving visual structure. Both steps are
	idempotent and cheap; called on every message's content on ingress so
	the model never sees raw subprocess noise and a stale session loaded
	from before this fix can't re-crash the request.
	"""
	if not s:
		return s
	s = ANSI_ESCAPE_RE.sub("", s)
	# Anything below 0x20 that isn't tab/newline/CR, plus DEL (0x7F).
	out_chars: list[str] = []
	for ch in s:
		code = ord(ch)
		if code == 0x09 or code == 0x0A or code == 0x0D:
			out_chars.append(ch)
		elif code < 0x20 or code == 0x7F:
			out_chars.append(" ")
		else:
			out_chars.append(ch)
	return "".join(out_chars)

def _sanitize_messages(messages: list) -> list:
	"""Applies _sanitize_content to every message's `content` field.

	Does not touch tool_calls arguments, tool_call_id, name — those are
	structured fields Godot already escapes correctly. Only free-text
	content, which is where subprocess output ends up, is sanitized.
	"""
	out: list = []
	for m in messages:
		if not isinstance(m, dict):
			out.append(m)
			continue
		content = m.get("content")
		if isinstance(content, str):
			clean = _sanitize_content(content)
			if clean != content:
				m = dict(m)
				m["content"] = clean
		out.append(m)
	return out

async def _parse_request_body(request: Request) -> tuple[dict[str, Any] | None, JSONResponse | None]:
	"""Reads and parses the request body, tolerating raw control characters.

	Returns (body, None) on success or (None, error_response) on failure.
	The strict-first / strict=False-fallback path means a body that Python
	would normally reject parses anyway, and a body that's genuinely
	unparseable produces a clean 400 instead of an unhandled 500.
	"""
	raw = await request.body()
	try:
		return json.loads(raw), None
	except json.JSONDecodeError as strict_exc:
		# Common case: raw control characters inside a string value that
		# Godot's JSON.stringify didn't escape. strict=False accepts them.
		# The bytes themselves are cleaned up later by _sanitize_messages.
		try:
			body = json.loads(raw, strict=False)
			print(
				f"[bridge] body contained raw control characters "
				f"({strict_exc}); parsed with strict=False"
			)
			return body, None
		except json.JSONDecodeError as fallback_exc:
			print(f"[bridge] body is not parseable JSON at all: {fallback_exc}")
			return None, JSONResponse(
				status_code=400,
				content={
					"error": {
						"message": (
							"Bridge could not parse the request body as JSON. "
							f"Strict parse failed: {strict_exc}. "
							f"Lenient parse also failed: {fallback_exc}."
						),
						"type": "invalid_request_error",
					}
				},
			)

# --------------------------------------------------------------------------
# Exceptions
# --------------------------------------------------------------------------

class RateLimitedError(Exception):
	"""Raised internally when a send could not be completed even after the
	bridge's own cooldowns. Callers translate this into an HTTP 429 so the
	Godot side can see a real OpenAI-shaped error — but on the WEB_CHAT
	tier that 429 is terminal: LLMClient.retry_on_429 is false for this
	provider, so Godot will NOT schedule its own backoff on top of ours."""
	def __init__(self, message: str, retries: int) -> None:
		super().__init__(message)
		self.retries = retries

# --------------------------------------------------------------------------
# SSE parsing — see handoff doc §3.2 for the exact shapes this decodes.
# --------------------------------------------------------------------------

def _parse_sse_blocks(raw: str) -> list[tuple[str | None, str]]:
	"""Split a raw SSE body into (event_name_or_None, joined_data) pairs."""
	out: list[tuple[str | None, str]] = []
	for block in raw.replace("\r\n", "\n").split("\n\n"):
		block = block.strip("\n")
		if block == "":
			continue
		event_name: str | None = None
		data_lines: list[str] = []
		for line in block.split("\n"):
			if line.startswith("event:"):
				event_name = line[len("event:"):].strip()
			elif line.startswith("data:"):
				data_lines.append(line[len("data:"):].strip())
		if data_lines:
			out.append((event_name, "\n".join(data_lines)))
		elif event_name is not None:
			out.append((event_name, ""))
	return out

def extract_reply_text(raw_sse: str) -> str:
	"""
	Reconstruct the assistant's full reply text from a raw SSE response
	body, following the accumulator rules recorded during DevTools
	inspection of chat.deepseek.com:

	  - The response carries an array of fragments. The first is often a
	    THINK fragment (DeepSeek's internal reasoning, streamed even on
	    Instant mode since the "Instant, Expert, Vision" unification).
	    The actual answer lives in a later RESPONSE fragment.
	  - Content-append events target the LAST fragment in the array.
	  - We track the type of that last fragment and only accumulate its
	    text when it's RESPONSE. THINK text is discarded.
	  - Stop at p == "response/status", o == "SET", v == "FINISHED";
	    `event: close` is a fallback terminator.
	"""
	accumulator = ""
	# Type of the last fragment in the response's fragment array. Content
	# appends target this fragment, so this is what decides whether an
	# incoming chunk is answer text or reasoning text. "" until the first
	# fragment is seen; anything that isn't exactly "RESPONSE" is treated
	# as non-answer and skipped, so a fragment type we don't recognize
	# fails safe (no reasoning leaks into the answer).
	current_fragment_type = ""

	for event_name, data in _parse_sse_blocks(raw_sse):
		if event_name == "close":
			break
		if data == "":
			continue
		try:
			obj = json.loads(data)
		except json.JSONDecodeError:
			continue
		if not isinstance(obj, dict):
			continue

		p = obj.get("p")
		o = obj.get("o")
		v = obj.get("v")

		if p == "response/status" and o == "SET" and v == "FINISHED":
			break

		# A new fragment (or batch of fragments) appended to the array.
		# The LAST one becomes current, and if it's a RESPONSE fragment
		# its initial `content` is the start of the answer. This is how
		# the answer begins — the shell's first fragment is the THINK
		# fragment, and the RESPONSE fragment arrives as an append.
		if p == "response/fragments" and o == "APPEND" and isinstance(v, list):
			for frag in v:
				if not isinstance(frag, dict):
					continue
				current_fragment_type = str(frag.get("type", "")).upper()
				if current_fragment_type == "RESPONSE":
					content = str(frag.get("content", ""))
					if content:
						accumulator += content
			continue

		# Content append with an explicit path pointing at the last
		# fragment. `o` is "APPEND" on the first such event, but is
		# sometimes omitted entirely on later ones (observed in the
		# stream: `{"p":"response/fragments/-1/content","v":"!"}` with no
		# `o` field at all). Treat a missing `o` as append.
		if isinstance(p, str) and p.endswith("/content"):
			if current_fragment_type == "RESPONSE":
				accumulator += str(v)
			continue

		# Initial message shell. Seeds the fragment list before any
		# content streams; if the shell happens to already contain a
		# RESPONSE fragment with content, take that as the initial
		# accumulator. The last fragment seen here also sets the current
		# type — the shell normally contains only the THINK fragment.
		if p is None and o is None and isinstance(v, dict) and "response" in v:
			frags = v["response"].get("fragments", [])
			for frag in frags:
				if not isinstance(frag, dict):
					continue
				current_fragment_type = str(frag.get("type", "")).upper()
				if current_fragment_type == "RESPONSE":
					content = str(frag.get("content", ""))
					if content:
						accumulator = content
			continue

		# Bare continuation — appends to the current (last) fragment.
		if p is None and o is None and "v" in obj and not isinstance(v, (dict, list)):
			if current_fragment_type == "RESPONSE":
				accumulator += str(v)
			continue

		# BATCH payloads (accumulated_token_usage, quasi_status, etc.)
		# carry no reply text — ignored.
	return accumulator

def _looks_rate_limited(text: str) -> bool:
	"""Case-insensitive substring scan for known rate-limit phrasings in
	either the raw HTTP body or the reconstructed reply text. Cheap and
	intentionally over-eager on the side of a false positive: a spurious
	cooldown costs a few seconds, a missed one costs the whole task."""
	if not text:
		return False
	lower = text.lower()
	for marker in RATE_LIMIT_MARKERS:
		if marker in lower:
			return True
	return False

# --------------------------------------------------------------------------
# Prompt construction — turns an OpenAI-shaped `messages` (+ `tools`) array
# into plain text DeepSeek's web chat can consume. Sent incrementally: only
# the NEW turns since the last call are typed into the already-open
# conversation, since the DeepSeek server threads history itself. If the
# incoming history no longer has our last-known state as a prefix (e.g.
# ContextManager compacted it), we start a fresh chat and resend everything
# we still have — subject to MAX_PROMPT_CHARS, see build_prompt_under_budget.
# --------------------------------------------------------------------------

# Tagged protocol — see AgentLoop._extract_tagged_calls and
# MainWindow.SYSTEM_PROMPT_WEB_CHAT_PROTOCOL. Kept in sync with the latter
# on purpose: on a full resend both this header and the system prompt are
# in the conversation at once, so they must describe the same format. The
# bridge's copy is slightly longer because it also has to introduce the
# tool list it renders below, and it names the exact failure modes
# (markdown fences, angle-bracket pseudo-tags) that the parser would
# otherwise silently fail to recover from.
TOOL_PROTOCOL_HEADER = (
	"You are a Godot 4 coding agent operating behind a web-chat bridge. "
	"This chat has NO native function-calling — you write tool calls "
	"yourself, as plain text, in the format below.\n\n"
	"TOOL-CALL FORMAT — to call a tool, write these two lines:\n"
	"    TOOL: <tool_name>\n"
	'    ARGS: {"key": "value", ...}\n\n'
	"Example — to read a file:\n"
	"TOOL: read_file\n"
	'ARGS: {"path": "res://Player.gd"}\n\n'
	"The parser looks for a `TOOL:` line followed by an `ARGS:` line "
	"carrying one JSON object. A short lead-in sentence before the pair "
	"is harmless; what matters is that both lines are present, each on "
	"its own line, whenever you intend to call a tool.\n\n"
	"- You MAY call several tools in one reply: write another TOOL:/ARGS: "
	"pair after the previous one's closing `}`. They run in the order "
	"written and you get every result back together in your next turn.\n"
	"- Write the pairs as plain text, not wrapped in code fences or "
	"XML-style tags (no ```, no <invoke>, no <parameter>) — those are "
	"easy for the parser to misread.\n"
	"- If you do NOT need a tool right now — you're done, or you need to "
	"ask the user something — reply in plain prose with NO TOOL:/ARGS: "
	"pair anywhere in that reply.\n"
	"- Never describe a tool call in prose and stop. If you say you're "
	"going to read a file, include the TOOL:/ARGS: pair for read_file in "
	"the same reply.\n\n"
	"Available tools:\n"
)

def _describe_tools(tools: list[dict]) -> str:
	lines = []
	for t in tools:
		fn = t.get("function", {}) if isinstance(t, dict) else {}
		name = fn.get("name", "?")
		desc = fn.get("description", "")
		params = fn.get("parameters", {})
		required = params.get("required", []) if isinstance(params, dict) else []
		props = params.get("properties", {}) if isinstance(params, dict) else {}
		arg_bits = []
		for k in props:
			mark = "*" if k in required else ""
			arg_bits.append(f"{k}{mark}")
		lines.append(f"- {name}({', '.join(arg_bits)}): {desc}")
	return "\n".join(lines)

def _cap_tool_result(content: str) -> str:
	"""Head+tail truncation for any single tool result that exceeds
	TOOL_RESULT_BRIDGE_CAP. Godot's AgentLoop already caps these before
	they enter the conversation, but session resumption loads old data
	that was saved before the cap existed, and it's cheap insurance."""
	if len(content) <= TOOL_RESULT_BRIDGE_CAP:
		return content
	half = TOOL_RESULT_BRIDGE_CAP // 2
	head = content[:half]
	tail = content[-half:]
	dropped = len(content) - TOOL_RESULT_BRIDGE_CAP
	return (
		head
		+ f"\n\n…[bridge truncated {dropped} chars from the middle of this "
		+ "tool result to fit the per-message budget]\n\n"
		+ tail
	)

def _render_message(m: dict) -> str:
	role = str(m.get("role", "user")).upper()
	content = m.get("content") or ""
	if role == "TOOL":
		name = m.get("name", "tool")
		content = _cap_tool_result(content)
		return f"[TOOL RESULT: {name}]\n{content}"
	if role == "ASSISTANT":
		calls = m.get("tool_calls") or []
		if calls:
			# Tagged protocol: a tool-calling assistant turn is *only* the
			# TOOL:/ARGS: pairs — no prose. If the stored message also
			# carries `content` (a legacy bare-JSON turn, or a synthetic
			# recovery where the model prefixed prose before the call),
			# drop that prose here rather than replaying it. Rendering it
			# would teach the model, from its own history, the exact
			# "prose before the call" pattern. The tool call survives; the
			# prose that accompanied it does not need to.
			lines = []
			for call in calls:
				fn = call.get("function", {})
				lines.append(
					"TOOL: %s\nARGS: %s"
					% (fn.get("name", ""), fn.get("arguments", "{}"))
				)
			return "[ASSISTANT]\n" + "\n".join(lines)
		return f"[ASSISTANT]\n{content.strip()}"
	return f"[{role}]\n{content}"

def build_full_prompt(messages: list[dict], tools: list[dict]) -> str:
	parts = [TOOL_PROTOCOL_HEADER + _describe_tools(tools), ""]
	for m in messages:
		parts.append(_render_message(m))
	return "\n\n".join(parts)

def build_incremental_prompt(new_messages: list[dict]) -> str:
	return "\n\n".join(_render_message(m) for m in new_messages)

def build_prompt_under_budget(
	messages: list[dict],
	tools: list[dict],
	budget: int = MAX_PROMPT_CHARS,
) -> str:
	"""Build a full-conversation prompt that fits under `budget` chars.

	Tries the full conversation first. If it fits, uses it verbatim — the
	common case for a fresh session. When it doesn't, drops messages from
	the MIDDLE (never the ends): keeps the first user message (the
	original task) and the most recent N messages. A short system note
	marks where the drop happened.

	Why middle: the first user message carries the task, the tail carries
	whatever the agent is currently working on. The middle is mostly tool
	results the model has already acted on.

	Why never truncate mid-message: a half-rendered JSON object or a
	partial tool result confuses the model more than a missing chunk of
	history. So this drops whole messages, not characters, once the
	header is accounted for.
	"""
	header = TOOL_PROTOCOL_HEADER + _describe_tools(tools)
	body_budget = budget - len(header) - 4   # -4 for the two "\n\n" joins

	full_body = "\n\n".join(_render_message(m) for m in messages)
	if len(full_body) <= body_budget:
		return header + "\n\n" + full_body

	n = len(messages)
	if n <= 2:
		# Nothing to drop. Return what we have; it's over budget, but
		# dropping either of the only two messages would gut the context.
		return header + "\n\n" + full_body

	# Anchor = the first user message (the original task). Falling back
	# to messages[0] if no user message exists (resumed session that
	# starts with a system message, or a malformed payload).
	anchor = None
	for m in messages:
		if m.get("role") == "user":
			anchor = m
			break
	if anchor is None:
		anchor = messages[0]

	# Find the largest tail that still fits alongside the anchor.
	for tail_n in range(n - 1, 0, -1):
		tail = messages[-tail_n:]
		# Skip the anchor if it's already inside the tail.
		anchor_in_tail = any(m is anchor for m in tail)
		kept = tail if anchor_in_tail else ([anchor] + tail)
		dropped = n - len(kept)
		if dropped <= 0:
			continue

		marker = {
			"role": "system",
			"content": (
				f"[{dropped} message(s) omitted from the middle of this "
				+ "conversation to fit the per-message size budget. The "
				+ "original task appears at the top; the most recent "
				+ "activity is below.]"
			),
		}
		rendered = []
		if not anchor_in_tail:
			rendered.append(_render_message(anchor))
		rendered.append(_render_message(marker))
		for m in tail:
			rendered.append(_render_message(m))
		body = "\n\n".join(rendered)
		if len(body) <= body_budget:
			return header + "\n\n" + body

	# Even the absolute minimum (anchor + last message) is over budget.
	# Return it anyway — this is a safety net, not a guarantee.
	marker = {
		"role": "system",
		"content": "[Conversation truncated to fit the per-message size budget.]",
	}
	rendered = [
		_render_message(anchor),
		_render_message(marker),
		_render_message(messages[-1]),
	]
	return header + "\n\n" + "\n\n".join(rendered)

# --------------------------------------------------------------------------
# The DeepSeek session — owns the one browser tab we drive.
# --------------------------------------------------------------------------

class DeepSeekSession:
	def __init__(self) -> None:
		self._pw = None
		self.context: BrowserContext | None = None
		self.page: Page | None = None
		self._lock = asyncio.Lock()
		# Bridge-side memory of what DeepSeek has already "seen" in the
		# currently-open chat, so we only type the delta each turn.
		self._known_messages: list[dict] = []
		self._chat_open = False
		# Monotonic timestamp of the end of the last send. Used to enforce
		# MIN_SEND_GAP_SECS between consecutive sends.
		self._last_send_end: float = 0.0
		# Where the per-request metrics go. Set in start().
		self._index_path: str = ""

	async def start(self) -> None:
		os.makedirs(os.path.join(BRIDGE_LOG_DIR, "sse"), exist_ok=True)
		self._index_path = os.path.join(BRIDGE_LOG_DIR, "index.jsonl")
		print(f"[bridge] logs → {BRIDGE_LOG_DIR}/")

		self._pw = await async_playwright().start()
		launch_kwargs: dict[str, Any] = {
			"headless": HEADLESS,
			"viewport": {"width": 1280, "height": 900},
		}
		if BROWSER_CHANNEL:
			launch_kwargs["channel"] = BROWSER_CHANNEL
		self.context = await self._pw.chromium.launch_persistent_context(
			USER_DATA_DIR, **launch_kwargs
		)
		self.page = self.context.pages[0] if self.context.pages else await self.context.new_page()
		await self.page.goto(DEEPSEEK_URL, wait_until="domcontentloaded")

	async def stop(self) -> None:
		if self.context is not None:
			await self.context.close()
		if self._pw is not None:
			await self._pw.stop()

	async def is_logged_in(self) -> bool:
		if self.page is None:
			return False
		try:
			await self.page.locator(SEL_CHAT_INPUT).first.wait_for(state="visible", timeout=3000)
			return True
		except PWTimeout:
			return False

	async def new_chat(self) -> None:
		"""Best-effort: click a 'New chat' control, else just reload."""
		if self.page is None:
			return
		try:
			await self.page.locator(SEL_NEW_CHAT_BUTTON).first.click(timeout=3000)
		except PWTimeout:
			await self.page.goto(DEEPSEEK_URL, wait_until="domcontentloaded")
		self._known_messages = []
		self._chat_open = False

	async def _wait_for_send_gap(self) -> None:
		"""Enforce MIN_SEND_GAP_SECS since the end of the previous send.
		No-op on the first send, or when the gap is 0. Called under the
		session lock, so this is the only place sends can be paced."""
		if MIN_SEND_GAP_SECS <= 0.0:
			return
		if self._last_send_end <= 0.0:
			return
		elapsed = time.monotonic() - self._last_send_end
		remaining = MIN_SEND_GAP_SECS - elapsed
		if remaining > 0:
			print(f"[bridge] pacing: sleeping {remaining:.1f}s before next send")
			await asyncio.sleep(remaining)

	def _log_request(
		self,
		request_meta: dict,
		attempt: int,
		status: int,
		body: str,
		reply: str,
		rate_limited: bool,
		elapsed_ms: float,
	) -> None:
		"""Append one metrics line to index.jsonl, and (when SAVE_RAW_SSE)
		write the full prompt + raw SSE + parsed reply to a per-attempt
		file under sse/. Failures here never break the request — logging
		is diagnostic, not load-bearing."""
		try:
			entry = {
				"ts": time.time(),
				"attempt": attempt,
				"prompt_chars": request_meta.get("prompt_chars", 0),
				"prompt_tokens_est": request_meta.get("prompt_chars", 0) // 4,
				"messages_in": request_meta.get("messages_in", 0),
				"new_chat_fired": request_meta.get("new_chat_fired", False),
				"was_full_resend": request_meta.get("was_full_resend", False),
				"prompt_capped": request_meta.get("prompt_capped", False),
				"status": status,
				"reply_chars": len(reply),
				"rate_limited": rate_limited,
				"elapsed_ms": round(elapsed_ms, 1),
			}
			with open(self._index_path, "a", encoding="utf-8") as f:
				f.write(json.dumps(entry) + "\n")

			if SAVE_RAW_SSE:
				stem = f"{int(entry['ts'] * 1000)}_{uuid.uuid4().hex[:8]}_a{attempt}"
				path = os.path.join(BRIDGE_LOG_DIR, "sse", f"{stem}.sse")
				with open(path, "w", encoding="utf-8") as f:
					f.write(f"=== PROMPT ({entry['prompt_chars']} chars) ===\n")
					f.write(request_meta.get("prompt", "") + "\n\n")
					f.write(f"=== STATUS {status} ===\n")
					f.write("=== RAW SSE ===\n")
					f.write(body + "\n\n")
					f.write(f"=== PARSED REPLY ({len(reply)} chars) ===\n")
					f.write(reply + "\n")
		except Exception as exc:  # noqa: BLE001 — logging must never crash a request
			print(f"[bridge] log write failed: {exc}")

	async def _type_and_submit(self, text: str) -> tuple[str, int, str]:
		"""Sends `text` and returns (raw_body, http_status, reply_text).

		Callers inspect http_status and raw_body for rate-limit signals —
		DeepSeek's web frontend signals throttling as a NORMAL 200 SSE
		response containing a short error message, not as a 429. Checking
		only the parsed reply text is not enough, because the SSE shape
		for an error message differs from a normal completion.
		"""
		box = self.page.locator(SEL_CHAT_INPUT).first
		await box.click()
		try:
			await box.fill(text)
		except Exception:
			# contenteditable divs sometimes reject fill(); fall back to
			# select-all + type.
			await self.page.keyboard.press("Control+A")
			await self.page.keyboard.type(text, delay=0)

		async with self.page.expect_response(
			lambda r: "chat/completion" in r.url,
			timeout=RESPONSE_TIMEOUT_MS,
		) as resp_info:
			await self.page.keyboard.press("Enter")

		response = await resp_info.value
		status = response.status
		body = await response.text()
		# Record the moment this send finished, regardless of outcome — the
		# pacing floor applies to retries too, otherwise a rapid sequence
		# of rate-limited attempts would pile up on top of each other.
		self._last_send_end = time.monotonic()
		reply = extract_reply_text(body)
		return body, status, reply

	async def _send_with_rate_limit_recovery(
		self,
		text: str,
		request_meta: dict,
	) -> str:
		"""Send `text`, retrying internally on any detected rate-limit
		signal. Returns the parsed reply text on success; raises
		RateLimitedError if retries are exhausted.

		On the WEB_CHAT tier this is the single retry authority — Godot's
		own 429 backoff is disabled there (see module docstring), so a
		RateLimitedError raised here becomes the user-visible outcome, not
		the trigger for another layer of retries.

		Every attempt — success or rate-limited — is written to the request
		log via _log_request."""
		cooldown = RATE_LIMIT_INITIAL_COOLDOWN_SECS
		last_body_snippet = ""
		last_status = 0

		for attempt in range(RATE_LIMIT_MAX_RETRIES + 1):
			await self._wait_for_send_gap()

			t_start = time.monotonic()
			body, status, reply = await self._type_and_submit(text)
			elapsed_ms = (time.monotonic() - t_start) * 1000.0
			last_status = status
			last_body_snippet = body[:500] if body else ""

			# A rate-limit signal can arrive three ways:
			#   1. Non-2xx HTTP (probably 429 or 503).
			#   2. 2xx with the marker text in the raw body.
			#   3. 2xx with the marker text only in the reconstructed reply.
			# Any of the three triggers the same retry path.
			is_rl = (
				status == 429
				or (500 <= status < 600)
				or _looks_rate_limited(body)
				or _looks_rate_limited(reply)
			)

			self._log_request(
				request_meta=request_meta,
				attempt=attempt,
				status=status,
				body=body,
				reply=reply,
				rate_limited=is_rl,
				elapsed_ms=elapsed_ms,
			)

			if not is_rl:
				return reply

			# Rate-limited. Log it and back off, unless this was the last
			# attempt — in which case fall through to the raise below.
			print(
				f"[bridge] rate-limited (status={status}, attempt "
				f"{attempt + 1}/{RATE_LIMIT_MAX_RETRIES + 1}); body starts: "
				f"{last_body_snippet!r}"
			)
			if attempt >= RATE_LIMIT_MAX_RETRIES:
				break

			wait = cooldown
			print(f"[bridge] cooling down {wait:.0f}s before retry")
			await asyncio.sleep(wait)
			cooldown = min(cooldown * 2.0, RATE_LIMIT_MAX_COOLDOWN_SECS)

		raise RateLimitedError(
			"DeepSeek rate-limited the request ('Messages too frequent. "
			f"Try again later.'). Retried {RATE_LIMIT_MAX_RETRIES} time(s) "
			f"inside the bridge with exponential backoff; last HTTP status "
			f"{last_status}, last body started: {last_body_snippet!r}. "
			"Raise MIN_SEND_GAP_SECS in bridge.py, or reduce the agent's "
			"tool-call rate, then retry.",
			RATE_LIMIT_MAX_RETRIES,
		)

	async def ask(self, messages: list[dict], tools: list[dict]) -> str:
		async with self._lock:
			if not await self.is_logged_in():
				raise RuntimeError(
					"Not logged in to DeepSeek — switch to the bridge's browser "
					"window, log in, then retry the request."
				)

			# Compare only role+content, not the full dict — Godot's own
			# conversation attaches tool_calls/tool_call_id/name to messages
			# that this bridge never sees when it guesses the shape of what
			# it just said, so an exact dict `==` here would mismatch on
			# EVERY turn and force a needless new_chat() each time.
			is_prefix = (
				self._chat_open
				and len(messages) >= len(self._known_messages)
				and all(
					messages[i].get("role") == self._known_messages[i].get("role")
					and (messages[i].get("content") or "") == (self._known_messages[i].get("content") or "")
					for i in range(len(self._known_messages))
				)
			)

			new_chat_fired = False
			was_full_resend = False
			prompt_capped = False

			if is_prefix and len(messages) > len(self._known_messages):
				new_part = messages[len(self._known_messages):]
				prompt = build_incremental_prompt(new_part)
			else:
				# Fresh conversation, or history diverged (e.g. context
				# compaction dropped early messages) — start over so the
				# model isn't missing context it thinks it has. Bounded by
				# MAX_PROMPT_CHARS via build_prompt_under_budget.
				await self.new_chat()
				new_chat_fired = True
				was_full_resend = True
				prompt = build_prompt_under_budget(messages, tools, MAX_PROMPT_CHARS)
				# Detect whether the budget drop actually fired: if the
				# rendered full prompt exceeds the cap but the budgeted
				# prompt is under it, something was dropped.
				uncapped = build_full_prompt(messages, tools)
				if len(uncapped) > MAX_PROMPT_CHARS and len(prompt) <= MAX_PROMPT_CHARS:
					prompt_capped = True

			request_meta = {
				"prompt": prompt,
				"prompt_chars": len(prompt),
				"messages_in": len(messages),
				"new_chat_fired": new_chat_fired,
				"was_full_resend": was_full_resend,
				"prompt_capped": prompt_capped,
			}

			if was_full_resend:
				print(
					f"[bridge] full resend: {len(messages)} messages, "
					f"{len(prompt)} chars"
					+ (" (budget-capped)" if prompt_capped else "")
				)
			elif new_chat_fired:
				print(f"[bridge] new chat, {len(prompt)} chars")

			reply = await self._send_with_rate_limit_recovery(prompt, request_meta)
			self._known_messages = list(messages) + [
				{"role": "assistant", "content": reply}
			]
			self._chat_open = True
			return reply

session = DeepSeekSession()

# --------------------------------------------------------------------------
# FastAPI app
# --------------------------------------------------------------------------

@asynccontextmanager
async def lifespan(_app: FastAPI):
	await session.start()
	logged_in = await session.is_logged_in()
	if not logged_in:
		print(
			"\n*** A browser window has opened. Log in to DeepSeek in that "
			"window, then it's ready to receive requests. ***\n"
		)
	yield
	await session.stop()

app = FastAPI(lifespan=lifespan)

@app.get("/health")
async def health() -> dict:
	return {"status": "ok", "logged_in": await session.is_logged_in()}

@app.post("/reset")
async def reset() -> dict:
	await session.new_chat()
	return {"status": "ok"}

@app.post("/v1/chat/completions")
async def chat_completions(request: Request):
	# Parse with tolerance for raw control characters (see module docstring
	# "CONTROL CHARACTERS / MALFORMED JSON"). This is the fix for the
	# `Invalid control character at:` crash — a body that strict json.loads
	# would reject now parses with strict=False instead of 500ing, and a
	# genuinely unparseable body produces a clean 400.
	body, error_response = await _parse_request_body(request)
	if error_response is not None:
		return error_response

	messages = _sanitize_messages(body.get("messages", []) or [])
	tools = body.get("tools", []) or []
	model = body.get("model", "deepseek-web")

	try:
		reply_text = await session.ask(messages, tools)
	except RateLimitedError as exc:
		# The bridge has already retried internally (exponential backoff,
		# RATE_LIMIT_MAX_RETRIES attempts) and is out of options. Return a
		# real 429 with an OpenAI-shaped error body.
		#
		# On the WEB_CHAT tier this 429 is terminal: ModelProfile sets
		# retry_429_locally = false, MainWindow pushes that into
		# LLMClient.retry_on_429, and Godot will NOT run its own
		# 5s/15s/45s backoff on top of ours. That is deliberate — a second,
		# shorter retry schedule from Godot would re-type the same prompt
		# into the same DeepSeek thread at an interval DeepSeek has just
		# told us is too fast, doubling the messages it has to throttle.
		# Every other tier leaves LLMClient.retry_on_429 at its default
		# (true), because those endpoints have no bridge in front of them.
		#
		# X-Bridge-Status is diagnostic-only: it names the layer that gave
		# up, so a proxy, a log analysis pass, or a future client can tell
		# a bridge-exhausted 429 apart from a raw upstream one without
		# string-matching the message body.
		return JSONResponse(
			status_code=429,
			headers={"X-Bridge-Status": "rate-limit-exhausted"},
			content={
				"error": {
					"message": str(exc),
					"type": "rate_limit_error",
					"retries_attempted": exc.retries,
				}
			},
		)
	except PWTimeout:
		return JSONResponse(
			status_code=504,
			content={"error": {"message": "Timed out waiting for DeepSeek's response."}},
		)
	except Exception as exc:  # noqa: BLE001 — surface anything as a clean HTTP error
		return JSONResponse(
			status_code=502,
			content={"error": {"message": str(exc)}},
		)

	return JSONResponse(
		{
			"id": f"deepseek-web-{uuid.uuid4().hex[:12]}",
			"object": "chat.completion",
			"created": int(time.time()),
			"model": model,
			"choices": [
				{
					"index": 0,
					"message": {"role": "assistant", "content": reply_text},
					"finish_reason": "stop",
				}
			],
			"usage": {},
		}
	)

if __name__ == "__main__":
	uvicorn.run(app, host=HOST, port=PORT)