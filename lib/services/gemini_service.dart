import 'package:dio/dio.dart';
import 'agent.dart';
import 'model_service.dart';

/// Google Gemini (Generative Language API) client. Mirrors [CloudModelService]
/// in shape so the agent loop works the same; differences are all hidden
/// inside request/response translation:
/// - role `assistant` ↔ Gemini `model`
/// - system messages ↔ top-level `systemInstruction`
/// - tools ↔ `functionDeclarations`
/// - tool result ↔ `functionResponse` part (no IDs — matched by name/order)
class GeminiService extends ModelService {
  final String apiKey;
  late final Dio _dio;

  static const _defaultBaseUrl = 'https://generativelanguage.googleapis.com';
  static const _apiVersion = 'v1beta';
  static const _defaultMaxTokens = 4096;

  static const fallbackModels = <String>[
    'gemini-2.5-pro',
    'gemini-2.5-flash',
    'gemini-2.5-flash-lite',
  ];

  GeminiService({required this.apiKey, String host = _defaultBaseUrl})
      : super(host) {
    _dio = Dio(BaseOptions(
      baseUrl: host,
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 120),
      headers: {
        'x-goog-api-key': apiKey,
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
      final response = await _dio.get('/$_apiVersion/models');
      final models = response.data['models'] as List?;
      if (models == null || models.isEmpty) return fallbackModels;
      final ids = <String>[];
      for (final m in models) {
        if (m is! Map) continue;
        final name = m['name'] as String? ?? '';
        final methods =
            (m['supportedGenerationMethods'] as List?)?.cast<String>() ??
                const [];
        if (!methods.contains('generateContent')) continue;
        // API returns "models/gemini-2.5-pro" — strip the namespace.
        final id = name.startsWith('models/') ? name.substring(7) : name;
        if (!id.startsWith('gemini-')) continue;
        ids.add(id);
      }
      return ids.isEmpty ? fallbackModels : ids;
    } catch (_) {
      return fallbackModels;
    }
  }

  @override
  Future<String> chat(List<Map<String, String>> messages, String model) async {
    final systemParts = <String>[];
    final contents = <Map<String, dynamic>>[];
    for (final m in messages) {
      final role = m['role'] ?? 'user';
      final content = m['content'] ?? '';
      if (role == 'system') {
        systemParts.add(content);
      } else {
        contents.add({
          'role': role == 'assistant' ? 'model' : 'user',
          'parts': [
            {'text': content}
          ],
        });
      }
    }
    if (contents.isEmpty) return '';

    final payload = <String, dynamic>{
      'contents': contents,
      'generationConfig': {'maxOutputTokens': _defaultMaxTokens},
    };
    if (systemParts.isNotEmpty) {
      payload['systemInstruction'] = {
        'parts': [
          {'text': systemParts.join('\n\n')}
        ],
      };
    }

    final response = await _dio.post(
      '/$_apiVersion/models/$model:generateContent',
      data: payload,
    );
    return _extractText(response.data);
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
    final contents = messages.map(_messageToGemini).toList();

    final payload = <String, dynamic>{
      'contents': contents,
      'generationConfig': {'maxOutputTokens': _defaultMaxTokens},
      if (system.isNotEmpty)
        'systemInstruction': {
          'parts': [
            {'text': system}
          ],
        },
      if (tools.isNotEmpty)
        'tools': [
          {
            'functionDeclarations': tools
                .map((t) => {
                      'name': t.name,
                      'description': t.description,
                      'parameters': t.inputSchema,
                    })
                .toList(),
          }
        ],
    };

    final response = await _dio.post(
      '/$_apiVersion/models/$model:generateContent',
      data: payload,
    );

    final candidates = response.data['candidates'] as List? ?? const [];
    if (candidates.isEmpty) return const AgentDone('');
    final firstCandidate = candidates.first as Map;
    final content = firstCandidate['content'] as Map? ?? const {};
    final parts = (content['parts'] as List?) ?? const [];

    // Pull function calls (if any) and concurrent preamble text.
    final calls = <ToolUseRequest>[];
    final textBuf = StringBuffer();
    for (var i = 0; i < parts.length; i++) {
      final p = parts[i];
      if (p is! Map) continue;
      if (p.containsKey('functionCall')) {
        final fc = p['functionCall'] as Map;
        calls.add(ToolUseRequest(
          // Gemini has no native call IDs; synthesize one stable within the
          // turn so the orchestrator can pair results back later.
          id: 'gemini-call-$i-${fc['name']}',
          name: fc['name'] as String,
          input: (fc['args'] as Map?)?.cast<String, dynamic>() ?? const {},
        ));
      } else if (p.containsKey('text')) {
        textBuf.write(p['text'] as String? ?? '');
      }
    }

    if (calls.isNotEmpty) {
      return AgentToolRequest(
        text: textBuf.toString(),
        calls: calls,
        // Echo the model turn back verbatim — Gemini matches functionResponse
        // entries to the prior functionCall parts by name + position.
        assistantMessage: {
          'role': 'model',
          'parts': parts.cast<dynamic>(),
        },
      );
    }

    return AgentDone(textBuf.toString());
  }

  @override
  List<Map<String, dynamic>> buildToolResultMessages(List<ToolResult> results) {
    // Gemini 同样所有 functionResponse 塞在一条 user 消息的 parts 里。
    return [
      {
        'role': 'user',
        'parts': results
            .map((r) => {
                  'functionResponse': {
                    'name': _nameFromSyntheticId(r.toolUseId),
                    // `response` 必须是 struct；包一层 content/error。
                    'response': r.isError
                        ? {'error': r.content}
                        : {'content': r.content},
                  },
                })
            .toList(),
      }
    ];
  }

  /// Translate one orchestrator-side message into a Gemini `contents` entry.
  /// User text messages come in shape `{role:'user', content: '...'}`.
  /// Assistant tool-call turns are already in Gemini shape (we built them in
  /// [_agentRequest]) and pass through unchanged.
  Map<String, dynamic> _messageToGemini(Map<String, dynamic> m) {
    // Already in Gemini shape (assistantMessage or tool result we just built).
    if (m.containsKey('parts')) {
      return {
        'role': m['role'] ?? 'user',
        'parts': m['parts'],
      };
    }
    final role = m['role'] as String? ?? 'user';
    final content = m['content'] ?? '';
    return {
      'role': role == 'assistant' ? 'model' : 'user',
      'parts': [
        {'text': content is String ? content : content.toString()}
      ],
    };
  }

  static String _nameFromSyntheticId(String id) {
    // `gemini-call-{index}-{name}` → name.
    final marker = RegExp(r'^gemini-call-\d+-');
    final m = marker.firstMatch(id);
    return m == null ? id : id.substring(m.end);
  }

  static String _extractText(Map<String, dynamic> body) {
    final candidates = body['candidates'] as List? ?? const [];
    if (candidates.isEmpty) return '';
    final content = (candidates.first as Map)['content'] as Map? ?? const {};
    final parts = (content['parts'] as List?) ?? const [];
    final buf = StringBuffer();
    for (final p in parts) {
      if (p is Map && p['text'] is String) {
        buf.write(p['text'] as String);
      }
    }
    return buf.toString();
  }
}
