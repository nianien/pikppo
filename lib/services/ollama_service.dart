import 'dart:convert';
import 'package:dio/dio.dart';
import 'agent.dart';
import 'model_service.dart';

/// Ollama 客户端。`/api/chat` 在 0.3 以上版本支持 `tools` 字段，但需要底层模型
/// 自身具备 tool 能力（`/api/tags` 返回里 `capabilities` 含 `"tools"`），所以
/// 能力检测是 per-model 的，由 [modelSupportsTools] 给出。
class OllamaService extends ModelService {
  late final Dio _dio;

  /// 跨实例的能力缓存：`<host, <模型名, capabilities 集合>>`。
  ///
  /// Riverpod 在配置变化时会重新构造 Service 实例，若把缓存放实例字段就跟着失
  /// 效。能力对 host 而言稳定，所以挂在 class 级 static 表上按 host 索引——同
  /// 一 host 跨多次 sendMessage、跨多次实例都共享同一份缓存。
  static final Map<String, Map<String, Set<String>>> _capsByHost = {};
  Map<String, Set<String>> get _capabilities =>
      _capsByHost.putIfAbsent(host, () => <String, Set<String>>{});

  OllamaService(super.host) {
    _dio = Dio(BaseOptions(
      baseUrl: host,
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 120),
    ));
  }

  /// 协议级支持。具体某个模型能不能跑 tools 看 [modelSupportsTools]。
  @override
  bool get supportsTools => true;

  @override
  Future<bool> modelSupportsTools(String model) async {
    if (model.isEmpty) return false;
    if (!_capabilities.containsKey(model)) {
      // 缓存缺失（首次启动、用户改了 host 等）——按需补拉一次。
      try {
        await fetchModels();
      } catch (_) {
        // 网络/服务故障：保守返回 false，调用方走非 agent 路径。
      }
    }
    return _capabilities[model]?.contains('tools') ?? false;
  }

  @override
  Future<List<String>> fetchModels() async {
    final response = await _dio.get('/api/tags');
    final models = (response.data['models'] as List?) ?? const [];
    final names = <String>[];
    _capabilities.clear();
    for (final m in models) {
      if (m is! Map) continue;
      final name = m['name'] as String?;
      if (name == null) continue;
      final caps = (m['capabilities'] as List?)?.cast<String>().toSet() ??
          <String>{};
      _capabilities[name] = caps;
      names.add(name);
    }
    return names;
  }

  @override
  Future<String> chat(List<Map<String, String>> messages, String model) async {
    final response = await _dio.post('/api/chat', data: {
      'model': model,
      'messages': ModelService.withNoThink(messages),
      'stream': false,
    });
    final raw = response.data['message']['content'] as String;
    return ModelService.stripThinking(raw);
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
    // Ollama 没有独立的 `system` 字段，需要作为首条消息注入。同时把 no-think
    // 指令并入 system，避免 qwen3/gemma 等带 thinking 的模型把推理写进输出。
    final systemContent = system.isEmpty
        ? ModelService.noThinkDirective
        : '$system\n\n${ModelService.noThinkDirective}';

    final payload = <String, dynamic>{
      'model': model,
      'stream': false,
      'messages': [
        {'role': 'system', 'content': systemContent},
        ...messages,
      ],
      if (tools.isNotEmpty)
        'tools': tools
            .map((t) => {
                  'type': 'function',
                  'function': {
                    'name': t.name,
                    'description': t.description,
                    'parameters': t.inputSchema,
                  },
                })
            .toList(),
    };

    final response = await _dio.post('/api/chat', data: payload);
    final message = response.data['message'] as Map? ?? const {};
    final rawText = (message['content'] as String?) ?? '';
    final toolCalls = (message['tool_calls'] as List?) ?? const [];

    if (toolCalls.isNotEmpty) {
      final calls = <ToolUseRequest>[];
      for (var i = 0; i < toolCalls.length; i++) {
        final tc = toolCalls[i];
        if (tc is! Map) continue;
        final fn = tc['function'] as Map?;
        if (fn == null) continue;
        // Ollama 的 tool_calls 没有原生 id；用合成 id 让 orchestrator 配对。
        calls.add(ToolUseRequest(
          id: 'ollama-call-$i-${fn['name']}',
          name: fn['name'] as String,
          input: _parseArguments(fn['arguments']),
        ));
      }
      return AgentToolRequest(
        text: ModelService.stripThinking(rawText),
        calls: calls,
        // 原样回写 assistant 消息——content + tool_calls 都要带回，下一轮 Ollama
        // 会按这个 anchor 配对 tool 响应。
        assistantMessage: {
          'role': 'assistant',
          'content': rawText,
          'tool_calls': toolCalls,
        },
      );
    }

    return AgentDone(ModelService.stripThinking(rawText));
  }

  @override
  List<Map<String, dynamic>> buildToolResultMessages(List<ToolResult> results) {
    // Ollama: 每个 tool 结果是一条独立的 `role:tool` 消息，按顺序匹配 tool_calls。
    return results
        .map((r) => <String, dynamic>{
              'role': 'tool',
              'content': r.isError ? 'tool error: ${r.content}' : r.content,
            })
        .toList();
  }

  /// Ollama 的 `arguments` 在新版是 Map（已 JSON 解码），但旧版/某些 build 会
  /// 输出 JSON 字符串。两种都吃掉，无法解析时给空 Map（让上层 tool 报错而不
  /// 是 Dart 端崩 cast）。
  static Map<String, dynamic> _parseArguments(dynamic raw) {
    if (raw is Map) return raw.cast<String, dynamic>();
    if (raw is String && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) return decoded.cast<String, dynamic>();
      } catch (_) {/* fall through */}
    }
    return <String, dynamic>{};
  }
}
