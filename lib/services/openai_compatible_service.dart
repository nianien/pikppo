import 'package:dio/dio.dart';
import 'agent.dart';
import 'model_service.dart';

/// OpenAI Chat Completions 协议兼容服务的基类。OpenAI 自家、DeepSeek、阿里
/// DashScope（OpenAI 兼容模式）共享同一份请求/响应结构与 function calling 规
/// 范，差异只在 host / 默认 model 列表 / models 端点过滤上。
///
/// 子类只需提供四样：[fallbackModels]、[isChatModel]（可选）、[modelsEndpoint]
/// 与 [chatEndpoint] 默认即可。
abstract class OpenAICompatibleService extends ModelService {
  final String apiKey;
  late final Dio _dio;
  static const _defaultMaxTokens = 4096;

  /// 网关模式 token——非空时 `Authorization: Bearer` 带的是网关 token（而非用户
  /// key），host 指网关，真实 key 由网关注入。
  final String? gatewayToken;

  OpenAICompatibleService({
    required this.apiKey,
    required String host,
    this.gatewayToken,
  }) : super(host) {
    _dio = Dio(BaseOptions(
      baseUrl: host,
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 120),
      headers: {
        'Authorization': 'Bearer ${gatewayToken ?? apiKey}',
        'content-type': 'application/json',
      },
    ));
  }

  /// 网络获取失败 / key 为空时的兜底模型列表——用户至少能选到一个。
  List<String> get fallbackModels;

  /// `/v1/models` 端点路径。绝大多数 OpenAI 兼容服务用 `/v1/models`，DashScope
  /// 在 base URL 已含 `/compatible-mode` 时也是 `/v1/models` 拼接。
  String get modelsEndpoint => '/v1/models';

  /// `/v1/chat/completions` 端点路径。
  String get chatEndpoint => '/v1/chat/completions';

  /// 从 `/v1/models` 返回里过滤出 chat 模型——OpenAI 会塞 tts/whisper/embedding
  /// 等非 chat 模型，子类按自家命名规则覆盖。默认 pass-through。
  bool isChatModel(String id) => true;

  @override
  bool get supportsTools => true;

  @override
  Future<List<String>> fetchModels() async {
    if (apiKey.isEmpty && gatewayToken == null) return fallbackModels;
    try {
      final response = await _dio.get(modelsEndpoint);
      final data = response.data['data'] as List?;
      if (data == null || data.isEmpty) return fallbackModels;
      final ids = <String>[];
      for (final m in data) {
        if (m is! Map) continue;
        final id = m['id'] as String?;
        if (id == null) continue;
        if (!isChatModel(id)) continue;
        ids.add(id);
      }
      return ids.isEmpty ? fallbackModels : ids;
    } on DioException catch (e) {
      // 认证错误必须暴露给"测试连接"，静态回退只兜网络类故障。
      final code = e.response?.statusCode;
      if (code == 401 || code == 403) rethrow;
      return fallbackModels;
    } catch (_) {
      return fallbackModels;
    }
  }

  @override
  Future<String> chat(List<Map<String, String>> messages, String model) async {
    // OpenAI 协议下 system 跟其他 role 一样落在 messages 数组里，不需要拆出来。
    final body = messages
        .map((m) => {
              'role': m['role'] ?? 'user',
              'content': m['content'] ?? '',
            })
        .toList();
    if (body.isEmpty) return '';

    final payload =
        _buildPayload(model: model, messages: body, tools: const []);
    final response = await _dio.post(chatEndpoint, data: payload);
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
          system: system, messages: messages, model: model, tools: tools);

  @override
  Future<AgentStep> agentContinue({
    required String system,
    required List<Map<String, dynamic>> messages,
    required String model,
    required List<ToolDefinition> tools,
  }) =>
      _agentRequest(
          system: system, messages: messages, model: model, tools: tools);

  Future<AgentStep> _agentRequest({
    required String system,
    required List<Map<String, dynamic>> messages,
    required String model,
    required List<ToolDefinition> tools,
  }) async {
    final body = <Map<String, dynamic>>[
      if (system.isNotEmpty) {'role': 'system', 'content': system},
      ...messages,
    ];
    final payload = _buildPayload(model: model, messages: body, tools: tools);
    final response = await _dio.post(chatEndpoint, data: payload);

    final choices = response.data['choices'] as List? ?? const [];
    if (choices.isEmpty) return const AgentDone('');
    final firstChoice = choices.first as Map;
    final message = firstChoice['message'] as Map? ?? const {};
    final finishReason = firstChoice['finish_reason'] as String?;
    final toolCalls = message['tool_calls'] as List? ?? const [];

    if (finishReason == 'tool_calls' || toolCalls.isNotEmpty) {
      final calls = <ToolUseRequest>[];
      for (final tc in toolCalls) {
        if (tc is! Map) continue;
        if (tc['type'] != 'function') continue;
        final fn = tc['function'] as Map? ?? const {};
        calls.add(ToolUseRequest(
          id: tc['id'] as String? ?? '',
          name: fn['name'] as String? ?? '',
          // OpenAI 把 arguments 序列化成 JSON 字符串；parseToolArguments 容错。
          input: parseToolArguments(fn['arguments']),
        ));
      }
      final preamble = (message['content'] as String?) ?? '';
      return AgentToolRequest(
        text: preamble,
        calls: calls,
        // 整条 assistant message 原样回传。OpenAI 协议规定 tool 消息序列前
        // 必须**紧跟同一条带 tool_calls 的 assistant 消息**——不能丢字段。
        assistantMessage: {
          'role': 'assistant',
          if (preamble.isNotEmpty) 'content': preamble,
          'tool_calls': toolCalls.cast<dynamic>(),
        },
      );
    }

    return AgentDone((message['content'] as String?) ?? '');
  }

  @override
  List<Map<String, dynamic>> buildToolResultMessages(
      List<ToolResult> results) {
    // OpenAI 协议：每个工具结果一条独立 `role: 'tool'` 消息（不像 Anthropic
    // 那样合并）。`tool_call_id` 对应原 assistant turn 里 `tool_calls[].id`。
    return results
        .map((r) => {
              'role': 'tool',
              'tool_call_id': r.toolUseId,
              // `content` 必须是字符串；错误信息加 `[ERROR] ` 前缀让模型在文本
              // 里看到——OpenAI 协议没有 `is_error` 字段。
              'content': r.isError ? '[ERROR] ${r.content}' : r.content,
            })
        .toList();
  }

  /// 推理模型族（OpenAI 的 o1/o3/o4 系列）用 `max_completion_tokens`；普通
  /// gpt-* 用 `max_tokens`。两个字段不能同时给。
  bool _isReasoningModel(String model) {
    return model.startsWith('o1') ||
        model.startsWith('o3') ||
        model.startsWith('o4');
  }

  Map<String, dynamic> _buildPayload({
    required String model,
    required List<Map<String, dynamic>> messages,
    required List<ToolDefinition> tools,
  }) {
    return <String, dynamic>{
      'model': model,
      'messages': messages,
      if (_isReasoningModel(model))
        'max_completion_tokens': _defaultMaxTokens
      else
        'max_tokens': _defaultMaxTokens,
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
  }

  static String _extractText(Map<String, dynamic> body) {
    final choices = body['choices'] as List? ?? const [];
    if (choices.isEmpty) return '';
    final message = (choices.first as Map)['message'] as Map? ?? const {};
    return (message['content'] as String?) ?? '';
  }
}

/// OpenAI 官方 API：GPT 系列 + o 系列推理模型。
class OpenAIService extends OpenAICompatibleService {
  static const defaultBaseUrl = 'https://api.openai.com';

  OpenAIService({required super.apiKey, super.host = defaultBaseUrl, super.gatewayToken});

  @override
  List<String> get fallbackModels => const [
        'gpt-4o',
        'gpt-4o-mini',
        'gpt-4-turbo',
        'gpt-4',
        'o1',
        'o1-mini',
      ];

  /// OpenAI 的 `/v1/models` 包括 tts / whisper / dall-e / embedding 等非 chat 模
  /// 型——按名字前缀挑出真正能聊天的。
  ///
  /// `gpt-` 前缀下还混着只走专用端点的模型（audio/realtime → Realtime API、
  /// tts/transcribe → Audio API、image → Images API、codex → Responses API、
  /// instruct → legacy Completions），按关键词排除。
  static const _nonChatKeywords = [
    '-tts',
    'transcribe',
    'realtime',
    'audio',
    'image',
    'instruct',
    'codex',
  ];

  @override
  bool isChatModel(String id) {
    final prefixOk = id.startsWith('gpt-') ||
        id.startsWith('chatgpt-') ||
        id.startsWith('o1') ||
        id.startsWith('o3') ||
        id.startsWith('o4');
    if (!prefixOk) return false;
    return !_nonChatKeywords.any(id.contains);
  }
}

/// DeepSeek API：完全 OpenAI 兼容协议。
class DeepSeekService extends OpenAICompatibleService {
  static const defaultBaseUrl = 'https://api.deepseek.com';

  DeepSeekService({required super.apiKey, super.host = defaultBaseUrl, super.gatewayToken});

  @override
  List<String> get fallbackModels => const [
        'deepseek-chat',
        'deepseek-reasoner',
      ];

  @override
  bool isChatModel(String id) => id.startsWith('deepseek-');
}

/// 阿里云 DashScope 的 OpenAI 兼容模式：通义千问全系列。host 默认
/// `https://dashscope.aliyuncs.com/compatible-mode`，端点拼接后为
/// `/v1/chat/completions`。
class QwenService extends OpenAICompatibleService {
  static const defaultBaseUrl =
      'https://dashscope.aliyuncs.com/compatible-mode';

  QwenService({required super.apiKey, super.host = defaultBaseUrl, super.gatewayToken});

  @override
  List<String> get fallbackModels => const [
        'qwen-max',
        'qwen-plus',
        'qwen-turbo',
        'qwen2.5-72b-instruct',
        'qwen2.5-32b-instruct',
        'qwen2.5-14b-instruct',
        'qwen2.5-7b-instruct',
        'qwq-32b-preview',
      ];

  /// DashScope `/v1/models` 在 OpenAI 兼容模式下可能不返回完整 chat 模型列
  /// 表；返回空时基类自动回退到 [fallbackModels]。这里只挑名字前缀对得上的，
  /// 滤掉 embedding / multimodal 等非纯 chat 项。
  @override
  bool isChatModel(String id) =>
      id.startsWith('qwen') || id.startsWith('qwq');
}
