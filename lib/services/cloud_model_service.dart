import 'package:dio/dio.dart';
import 'agent.dart';
import 'model_service.dart';

/// Anthropic Claude API client (Messages API). Supports the agentic tool_use
/// loop by exposing [agentStart] / [agentContinue].
class CloudModelService extends ModelService {
  final String apiKey;
  late final Dio _dio;

  static const _defaultBaseUrl = 'https://api.anthropic.com';
  static const _apiVersion = '2023-06-01';
  static const _defaultMaxTokens = 4096;

  /// Static fallback list when network /v1/models is unavailable.
  static const fallbackModels = <String>[
    'claude-opus-4-7',
    'claude-sonnet-4-6',
    'claude-haiku-4-5',
  ];

  CloudModelService({required this.apiKey, String host = _defaultBaseUrl})
      : super(host) {
    _dio = Dio(BaseOptions(
      baseUrl: host,
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 120),
      headers: {
        'x-api-key': apiKey,
        'anthropic-version': _apiVersion,
        'content-type': 'application/json',
      },
    ));
  }

  @override
  bool get supportsTools => true;

  @override
  Future<List<String>> fetchModels() async {
    if (apiKey.isEmpty) return fallbackModels;
    try {
      final response = await _dio.get('/v1/models');
      final data = response.data['data'] as List?;
      if (data == null || data.isEmpty) return fallbackModels;
      return data
          .map((m) => (m as Map)['id'] as String)
          .where((id) => id.startsWith('claude'))
          .toList();
    } catch (_) {
      return fallbackModels;
    }
  }

  @override
  Future<String> chat(List<Map<String, String>> messages, String model) async {
    final systemParts = <String>[];
    final body = <Map<String, String>>[];
    for (final m in messages) {
      final role = m['role'] ?? 'user';
      final content = m['content'] ?? '';
      if (role == 'system') {
        systemParts.add(content);
      } else {
        body.add({'role': role, 'content': content});
      }
    }
    if (body.isEmpty) return '';

    final payload = <String, dynamic>{
      'model': model,
      'max_tokens': _defaultMaxTokens,
      'messages': body,
    };
    if (systemParts.isNotEmpty) {
      payload['system'] = systemParts.join('\n\n');
    }

    final response = await _dio.post('/v1/messages', data: payload);
    return _extractText(response.data['content'] as List?);
  }

  // ---- Agent loop ----

  @override
  Future<AgentStep> agentStart({
    required String system,
    required List<Map<String, dynamic>> messages,
    required String model,
    required List<ToolDefinition> tools,
  }) =>
      _agentRequest(
        system: system,
        messages: messages,
        model: model,
        tools: tools,
      );

  @override
  Future<AgentStep> agentContinue({
    required String system,
    required List<Map<String, dynamic>> messages,
    required String model,
    required List<ToolDefinition> tools,
  }) =>
      _agentRequest(
        system: system,
        messages: messages,
        model: model,
        tools: tools,
      );

  Future<AgentStep> _agentRequest({
    required String system,
    required List<Map<String, dynamic>> messages,
    required String model,
    required List<ToolDefinition> tools,
  }) async {
    final payload = <String, dynamic>{
      'model': model,
      'max_tokens': _defaultMaxTokens,
      'messages': messages,
      if (system.isNotEmpty) 'system': system,
      if (tools.isNotEmpty)
        'tools': tools
            .map((t) => {
                  'name': t.name,
                  'description': t.description,
                  'input_schema': t.inputSchema,
                })
            .toList(),
    };

    final response = await _dio.post('/v1/messages', data: payload);
    final stopReason = response.data['stop_reason'] as String?;
    final content = response.data['content'] as List? ?? const [];

    if (stopReason == 'tool_use') {
      final calls = <ToolUseRequest>[];
      for (final block in content) {
        if (block is! Map) continue;
        if (block['type'] != 'tool_use') continue;
        calls.add(ToolUseRequest(
          id: block['id'] as String,
          name: block['name'] as String,
          input: (block['input'] as Map?)?.cast<String, dynamic>() ?? const {},
        ));
      }
      return AgentToolRequest(
        text: _extractText(content),
        calls: calls,
        // Echo the assistant turn back verbatim so we keep tool_use ids.
        assistantMessage: {
          'role': 'assistant',
          'content': content.cast<dynamic>(),
        },
      );
    }

    return AgentDone(_extractText(content));
  }

  @override
  List<Map<String, dynamic>> buildToolResultMessages(List<ToolResult> results) {
    // Anthropic 把所有 tool_result 块塞在同一条 user 消息里。
    return [
      {
        'role': 'user',
        'content': results
            .map((r) => {
                  'type': 'tool_result',
                  'tool_use_id': r.toolUseId,
                  'content': r.content,
                  if (r.isError) 'is_error': true,
                })
            .toList(),
      }
    ];
  }

  static String _extractText(List? content) {
    if (content == null || content.isEmpty) return '';
    final buf = StringBuffer();
    for (final block in content) {
      if (block is Map && block['type'] == 'text') {
        buf.write(block['text'] as String? ?? '');
      }
    }
    return buf.toString();
  }
}
