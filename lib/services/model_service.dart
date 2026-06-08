import 'agent.dart';

abstract class ModelService {
  final String host;

  ModelService(this.host);

  /// 关闭思考的统一指令——以 system prompt 形式注入。`think:false` 这类引擎私
  /// 有字段只是语法糖，唯一可靠的控制点是喂给模型的 token，所以直接写进 prompt
  /// 在任何引擎/协议下都成立。
  static const noThinkDirective =
      '直接输出最终答案，禁止输出任何思考、推理、分析或自我纠正过程，'
      '也不要输出 <think>、<thinking>、<analysis> 等标签包裹的内容。';

  /// 把 [noThinkDirective] 合并到 messages 的 system 消息里；没有 system 就插
  /// 一条到最前面。返回新 list，不修改入参。
  static List<Map<String, String>> withNoThink(
      List<Map<String, String>> messages) {
    var injected = false;
    final out = <Map<String, String>>[];
    for (final m in messages) {
      if (!injected && m['role'] == 'system') {
        out.add({
          'role': 'system',
          'content': '${m['content'] ?? ''}\n\n$noThinkDirective',
        });
        injected = true;
      } else {
        out.add(m);
      }
    }
    if (!injected) {
      out.insert(0, {'role': 'system', 'content': noThinkDirective});
    }
    return out;
  }

  /// 兜底：剥掉模型仍然输出的思考段（`<think>...</think>` 之类）。指令压不住
  /// 硬编码思考的模型时由这里收尾。
  static final _thinkBlockPattern = RegExp(
    r'<(think|thinking|analysis|reasoning)\b[^>]*>[\s\S]*?</\1>',
    caseSensitive: false,
  );
  static String stripThinking(String text) =>
      text.replaceAll(_thinkBlockPattern, '').trim();

  Future<List<String>> fetchModels();

  /// Plain (non-agentic) chat. Used when no tools are wired up.
  Future<String> chat(List<Map<String, String>> messages, String model);

  /// 协议层是否支持 agent tool_use 循环——服务整体能力。Anthropic / Gemini /
  /// Ollama 全是 true。
  ///
  /// 该字段**不等于**当前所选模型可用 tool；像 Ollama 必须看具体模型的
  /// capabilities（`gemma3:4b` 没有 tools，`qwen2.5:7b` 有）。所以调用方判定
  /// 是否走 agent loop 时应该用 [modelSupportsTools]，不要直接看本字段。
  bool get supportsTools => false;

  /// 当前选定的 [model] 是否真能跑 tool_use。默认沿用服务级 [supportsTools]，
  /// Ollama 这种"协议支持但模型分化"的实现会重写为按 `/api/tags` 缓存查能力。
  ///
  /// 异步是给本地缓存留懒加载的位置（首次未拉过模型列表时按需补拉）。
  Future<bool> modelSupportsTools(String model) async => supportsTools;

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

  /// Build the message(s) carrying [results] back to the model. Most providers
  /// pack all results into one user/tool message (Anthropic, Gemini) — they
  /// return a single-element list. Ollama-style protocols emit one `role:tool`
  /// message per call, so multi-element lists are also legal. Caller appends
  /// the returned items to its running history in order.
  List<Map<String, dynamic>> buildToolResultMessages(List<ToolResult> results) {
    throw UnsupportedError('agentic tool use not supported by this provider');
  }
}
