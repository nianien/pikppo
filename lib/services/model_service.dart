import 'agent.dart';

abstract class ModelService {
  final String host;

  ModelService(this.host);

  Future<List<String>> fetchModels();

  /// Plain (non-agentic) chat. Used when no tools are wired up.
  Future<String> chat(List<Map<String, String>> messages, String model);

  /// Whether this provider supports the agentic tool_use loop. Defaults to
  /// `false`; override in subclasses that implement [agentStart].
  bool get supportsTools => false;

  /// Begin an agentic conversation. The provider returns either a final text
  /// reply ([AgentDone]) or a tool-use request ([AgentToolRequest]) which the
  /// caller resolves via [agentContinue].
  Future<AgentStep> agentStart({
    required String system,
    required List<Map<String, dynamic>> messages,
    required String model,
    required List<ToolDefinition> tools,
  }) {
    throw UnsupportedError('agentic tool use not supported by this provider');
  }

  /// Continue an agentic conversation after executing tool calls.
  ///
  /// [history] is the running message list including the assistant turn
  /// returned in the previous [AgentToolRequest.assistantMessage] *and* a
  /// follow-up user turn carrying the [ToolResult]s. The caller assembles this.
  Future<AgentStep> agentContinue({
    required String system,
    required List<Map<String, dynamic>> messages,
    required String model,
    required List<ToolDefinition> tools,
  }) {
    throw UnsupportedError('agentic tool use not supported by this provider');
  }

  /// Build the user-message payload that carries [results] back to the model.
  /// Format is provider-specific; default delegates to subclasses.
  Map<String, dynamic> buildToolResultMessage(List<ToolResult> results) {
    throw UnsupportedError('agentic tool use not supported by this provider');
  }
}
