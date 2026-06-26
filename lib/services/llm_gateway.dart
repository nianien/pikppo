// LLM 出海网关（pikppo-llm）接入配置。
//
// 云端 provider 经此中转，解决中国区直连 Anthropic/OpenAI/Gemini 被墙的问题：
// 客户端只带网关预共享 token（Authorization: Bearer），不再持各家 provider key
// ——真实 key 在网关服务端，网关校验 token 后注入并转发。详见
// pikppo-llm/docs/设计方案.md。与 MCP_TOKEN 同等处理：经 --dart-define-from-file=.env
// 注入，永不入库。

/// 网关 base。默认线上 `https://llm.pikppo.com`；本地联调用
/// `--dart-define=LLM_GATEWAY=http://10.0.2.2:8000` 覆盖。
String get llmGatewayBase {
  const override = String.fromEnvironment('LLM_GATEWAY');
  return override.isNotEmpty ? override : 'https://llm.pikppo.com';
}

/// 网关预共享 token（`--dart-define=LLM_TOKEN=...`）。
/// **非空 = 启用网关模式**（云端走网关、不要求用户 key）；空 = 退回 BYO 直连各家 API。
String get llmGatewayToken => const String.fromEnvironment('LLM_TOKEN');

/// 是否启用网关模式。
bool get useLlmGateway => llmGatewayToken.isNotEmpty;

/// 某 provider 经网关的 host：`<base>/<provider>`（如 `https://llm.pikppo.com/anthropic`）。
/// 各 service 的请求路径（`/v1/messages` 等）原样拼在其后，网关按前缀路由到上游。
String llmGatewayHostFor(String provider) => '$llmGatewayBase/$provider';
