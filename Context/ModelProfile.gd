class_name ModelProfile
extends RefCounted

# Bundles every small-model hand-holding knob behind a single tier, so a
# cloud-class model never pays — in tokens or in unwanted nagging — for
# accommodations that exist for 7-8B local models. This consolidates
# constants that used to be scattered, unconditional, across AgentLoop,
# ReadFileTool, GodotTool, and MainWindow's system prompt. See
# projectstructure.txt's "Per-model profile layer" entry for the rationale.
#
# WEB_CHAT is a separate axis from the size tiers: it marks a LARGE model
# reached through a bridge that has no native function-calling (DeepSeek
# Web, any similar "type into the real chat UI" strategy). It gets the
# no-hand-holding defaults of STANDARD, but with synthetic tool-call
# recovery enabled at a high cap and a bridge-specific system-prompt
# section that forces one-bare-JSON-object-per-turn discipline.

enum Tier { TINY, SMALL, STANDARD, POWERFUL, WEB_CHAT }

var tier: Tier = Tier.STANDARD

# --- tool-output / context knobs ---
var max_tool_result_chars: int = 32_000
var large_file_line_threshold: int = 500
# Token budget passed to ContextManager.build() — matches
# ContextManager.DEFAULT_MAX_TOKENS by default. Compaction exists to keep
# API providers from being billed for (and truncated on) an ever-growing
# conversation. WEB_CHAT has no such cost: DeepSeek's own chat thread
# already holds the full, untrimmed history, so Godot-side compaction only
# forces a needless full resend (see AgentLoop._step() / bridge.py's
# new_chat()+build_prompt_under_budget path) — throwing away free
# continuity DeepSeek still has, then retyping the tool-protocol header and
# as much surviving conversation as fits into a brand-new chat. WEB_CHAT
# sets this far above DEFAULT_MAX_TOKENS so that path almost never fires;
# the bridge's own MAX_PROMPT_CHARS remains the real safety net for the
# cases (first turn, genuine divergence) that still need a full resend.
var context_max_tokens: int = 100_000

# --- networking knobs ---
# Whether LLMClient should run its own local 429 backoff-and-retry loop
# (see LLMClient.retry_on_429). True for every tier except WEB_CHAT: the
# DeepSeek Web Bridge already retries internally on a rate limit before
# ever surfacing a 429 to Godot, so a second independent retry schedule
# here only stacks more duplicate sends into the same DeepSeek chat
# thread on top of the bridge's own, much longer one.
var retry_429_locally: bool = true

# --- system-prompt injections ---
var inject_syntax_cheatsheet: bool = false
var inject_act_dont_ask: bool = false
var inject_diagnostic_priming: bool = false
# WEB_CHAT only — injects the "one bare JSON object per turn, no prose,
# no fences, no XML tags" protocol section at the top of the system prompt.
var inject_web_chat_protocol: bool = false
var extra_system_hint: String = ""

# --- verification / recovery knobs ---
var append_syntax_hints: bool = false
var max_synthetic_recoveries: int = 0
var max_auto_verify_per_task: int = 0
# Per-TASK ceiling on LLM round trips (AgentLoop._iterations). Not a tool-
# call count: each _step() is one full request/response cycle, and one
# response can carry several tool calls that all execute within the same
# iteration. 32 is fine for a native-API tier where a round trip is
# sub-second; it's a task-length limit on WEB_CHAT, where a round trip is
# a 30-90s browser cycle and the model batches less aggressively — a
# routine multi-file edit session exhausts it mid-task. Runaway-loop
# protection lives elsewhere (thrash detection, gave-up escalation, the
# recovery-budget guard), so this knob is purely about "is the task
# genuinely big" and can be generous on tiers that need it.
var max_iterations: int = 32
# --- nudge knobs ---
var enable_gave_up_escalation: bool = false
var enable_no_read_nudge: bool = false
var enable_symbol_guess_nudge: bool = false

static func for_tier(t: Tier) -> ModelProfile:
	match t:
		Tier.TINY:
			return _tiny()
		Tier.SMALL:
			return _small()
		Tier.POWERFUL:
			return _powerful()
		Tier.WEB_CHAT:
			return _web_chat()
		_:
			return _standard()

# Cloud-class models (GPT-4/5-class, Claude, Gemini Pro/Flash, 70B+ local).
# No hand-holding — it's wasted tokens on a model that already reads its
# context and calls tools correctly. The field defaults above ARE this
# profile, so there's nothing to override.
static func _standard() -> ModelProfile:
	var p := ModelProfile.new()
	p.tier = Tier.STANDARD
	return p

# Same knobs as STANDARD (no nudging) but with more headroom — these models
# pay little penalty for extra context and benefit from fewer forced re-reads.
static func _powerful() -> ModelProfile:
	var p := _standard()
	p.tier = Tier.POWERFUL
	p.max_tool_result_chars = 64_000
	p.large_file_line_threshold = 1000
	return p

# 7-14B local models: struggle with multi-step tool use, guess file paths,
# occasionally write tool calls as text instead of issuing them. Every
# nudge on; smaller caps force more, narrower reads.
static func _small() -> ModelProfile:
	var p := ModelProfile.new()
	p.tier = Tier.SMALL
	p.max_tool_result_chars = 8_000
	p.large_file_line_threshold = 200
	p.inject_syntax_cheatsheet = true
	p.inject_act_dont_ask = true
	p.inject_diagnostic_priming = true
	p.append_syntax_hints = true
	p.max_synthetic_recoveries = 4
	p.max_auto_verify_per_task = 8
	# Small local models loop more than they progress, so a tighter
	# round-trip ceiling than STANDARD is deliberate — the gave-up
	# escalation will surface a stuck task well before this anyway.
	p.max_iterations = 24
	p.enable_gave_up_escalation = true
	p.enable_no_read_nudge = true
	p.enable_symbol_guess_nudge = true
	return p

# Sub-4B local models: same accommodations as SMALL, pushed further.
static func _tiny() -> ModelProfile:
	var p := _small()
	p.tier = Tier.TINY
	p.max_tool_result_chars = 4_000
	p.large_file_line_threshold = 150
	return p

# Large cloud models reached through a web-chat bridge with no native
# function-calling (DeepSeek Web, any equivalent). Inherits STANDARD's
# no-hand-holding defaults, but:
#   - enables synthetic tool-call recovery at a high cap, since EVERY
#     tool call arrives as plain text and has to be recovered;
#   - injects the web-chat protocol section into the system prompt;
#   - leaves the small-model nudges OFF, because this model is smart
#     enough to read a spec and follow it;
#   - uses a moderate tool-result cap: every tool result is typed into a
#     real browser input box, and each character costs a CDP round trip
#     on the way in. 12_000 chars is enough for a substantial read_file
#     with room to spare, and it keeps a 15-call task from silently
#     pushing the conversation past the per-message budget (see
#     bridge.py's MAX_PROMPT_CHARS).
#
# NOTE: max_synthetic_recoveries is per TASK, not per turn — 64 is a
# safety ceiling, not an expected count. A well-behaved run won't get
# anywhere near it.
static func _web_chat() -> ModelProfile:
	var p := _standard()
	p.tier = Tier.WEB_CHAT
	p.inject_web_chat_protocol = true
	p.max_synthetic_recoveries = 500
	p.max_tool_result_chars = 12_000
	p.large_file_line_threshold = 600
	# Every round trip here is a real browser cycle (30-90s), so a long
	# task legitimately needs many of them. 200 covers a substantial
	# multi-file refactor; the recovery-budget guard and thrash detection
	# catch genuine loops long before this fires.
	p.max_iterations = 200
	# Effectively disable Godot-side compaction — see context_max_tokens'
	# doc comment above. Not literally infinite: TokenEstimator.estimate()
	# is a rough len/4 pass over plain GDScript Dictionaries/Arrays sitting
	# in RAM, so a very high ceiling costs nothing but a few extra bytes of
	# local memory, not typing time or DeepSeek context.
	p.context_max_tokens = 2_000_000
	p.retry_429_locally = false
	return p

# --- tier <-> string, for AppSettings persistence and the Settings dropdown ---

static func tier_from_string(s: String) -> Tier:
	var upper := s.strip_edges().to_upper()
	var keys := Tier.keys()
	for i in keys.size():
		if keys[i] == upper:
			return i
	return Tier.STANDARD

static func tier_name(t: Tier) -> String:
	return Tier.keys()[t].to_lower()

# Human-readable label for the status bar and Settings dropdown. Kept
# separate from tier_name() (which must round-trip through ConfigFile),
# so a nicer display string doesn't affect persistence.
static func tier_display_name(t: Tier) -> String:
	match t:
		Tier.TINY:
			return "Tiny"
		Tier.SMALL:
			return "Small"
		Tier.STANDARD:
			return "Standard"
		Tier.POWERFUL:
			return "Powerful"
		Tier.WEB_CHAT:
			return "Web Chat"
		_:
			return tier_name(t).capitalize()

# --- "Auto" heuristic: guess a tier from the model name string alone ---
#
# Best-effort, not authoritative — a user who knows better can always pick a
# tier explicitly in Settings. Looks for an explicit parameter count first
# (the strongest signal when present, e.g. "qwen2.5-coder:7b",
# "llama-3.3-70b-versatile"), then falls back to name fragments for
# providers that don't expose one (Gemini, GPT, Claude).
#
# "deepseek-web" is checked BEFORE the parameter-count regex, because the
# bridge's model name is user-typed and may contain arbitrary text — the
# explicit "deepseek-web" marker is stronger evidence than any number in
# the same string.
static var _param_count_re: RegEx = null

static func resolve_tier_from_model_name(model_name: String) -> Tier:
	var lower := model_name.strip_edges().to_lower()
	if lower == "":
		return Tier.STANDARD

	# Bridge markers — see bridge.py and the DeepSeek Web Chat Bridge README.
	# Any of these in the model name means the endpoint is the local bridge,
	# not a native tool-calling API.
	for marker in ["deepseek-web", "deepseek_web", "web-chat", "web_chat"]:
		if lower.find(marker) != -1:
			return Tier.WEB_CHAT

	if _param_count_re == null:
		_param_count_re = RegEx.new()
		_param_count_re.compile("(\\d+(?:\\.\\d+)?)\\s*b\\b")
	var m := _param_count_re.search(lower)
	if m != null:
		var billions := m.get_string(1).to_float()
		if billions < 4.0:
			return Tier.TINY
		if billions < 20.0:
			return Tier.SMALL
		if billions < 70.0:
			return Tier.STANDARD
		return Tier.POWERFUL

	for needle in ["mini", "nano", "tiny"]:
		if lower.find(needle) != -1:
			return Tier.TINY

	# Known cloud model families that don't put a parameter count in the
	# name — treat as cloud-safe by default.
	for needle in ["gpt-", "gemini", "claude", "command-r", "sonnet", "opus", "haiku", "o1", "o3"]:
		if lower.find(needle) != -1:
			return Tier.STANDARD

	return Tier.STANDARD
