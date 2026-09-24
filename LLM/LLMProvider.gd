class_name LLMProvider
extends RefCounted

# Subclasses override this and normalize provider-specific payloads
# into a unified LLMResponse.
func send_messages(_messages: Array, _tools: Array) -> LLMResponse:
	push_error("LLMProvider.send_messages not implemented")
	return null

func provider_name() -> String:
	return "base"
