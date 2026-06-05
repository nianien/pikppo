/// Provider-agnostic types for the Flutter-side agent loop. The orchestrator
/// (in `app_state_provider.dart`) drives these in a tool_use → tool_result
/// cycle until the model returns plain text.
library;

class ToolDefinition {
  final String name;
  final String description;
  final Map<String, dynamic> inputSchema;
  const ToolDefinition({
    required this.name,
    required this.description,
    required this.inputSchema,
  });
}

class ToolUseRequest {
  /// Provider-assigned id (`toolu_...` for Anthropic) — must round-trip back
  /// in the corresponding tool_result.
  final String id;
  final String name;
  final Map<String, dynamic> input;
  const ToolUseRequest({
    required this.id,
    required this.name,
    required this.input,
  });
}

class ToolResult {
  final String toolUseId;
  final String content;
  final bool isError;
  const ToolResult({
    required this.toolUseId,
    required this.content,
    this.isError = false,
  });
}

sealed class AgentStep {
  const AgentStep();
}

/// Final assistant text — the loop terminates.
class AgentDone extends AgentStep {
  final String text;
  const AgentDone(this.text);
}

/// The model wants to invoke tools. The orchestrator must execute the [calls]
/// and feed [ToolResult]s back via [ModelService.continueWithToolResults].
class AgentToolRequest extends AgentStep {
  /// Optional preamble text the model emitted alongside tool_use blocks.
  final String? text;
  final List<ToolUseRequest> calls;

  /// Provider-specific assistant message to append to the running history.
  /// Opaque to the orchestrator; passed back unchanged on the next step.
  final Map<String, dynamic> assistantMessage;

  const AgentToolRequest({
    this.text,
    required this.calls,
    required this.assistantMessage,
  });
}
