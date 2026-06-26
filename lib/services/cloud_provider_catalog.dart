/// 云端模型服务商目录——所有 cloud provider 的可视/可配信息集中在此一处。
///
/// 加新 provider 的边际成本 = 往 [cloudProviderCatalog] 加一行 + 在 model
/// service 工厂里加一个 case，不再需要散落在三四个文件里改五处。
class CloudProviderSpec {
  /// 内部 id，用于 [AppState.cloudProvider]、secure storage key 拼接、工厂分流。
  final String id;

  /// UI 下拉里显示给用户看的名字。
  final String displayName;

  /// 对话内切换面板等紧凑场景用的短名。
  final String shortName;

  /// 用户未在设置里输入自定义 host 时的默认值。
  final String defaultHost;

  /// API key 输入框的 placeholder 提示——给的是各家 key 的常见前缀样例。
  final String apiKeyHint;

  /// API key 输入框的 label 文案。
  final String apiKeyLabel;

  /// 该 provider 的 API key 在 [flutter_secure_storage] 里的 key 名。
  /// **历史值不可变**：anthropic / gemini 在多版本前就已用这两个名字落盘；
  /// 重命名 = 老用户秘钥丢失，新用户被迫重新输入。
  final String secureStorageKey;

  const CloudProviderSpec({
    required this.id,
    required this.displayName,
    required this.shortName,
    required this.defaultHost,
    required this.apiKeyHint,
    required this.apiKeyLabel,
    required this.secureStorageKey,
  });
}

/// 顺序即下拉显示顺序：按用户语境的常见度排（中英文厂商混排，国内 / 国际
/// 各覆盖到主流）。新 provider 插队即可，不影响现有用户已选择的 provider。
const cloudProviderCatalog = <String, CloudProviderSpec>{
  'anthropic': CloudProviderSpec(
    id: 'anthropic',
    displayName: 'Anthropic (Claude)',
    shortName: 'Claude',
    defaultHost: 'https://api.anthropic.com',
    apiKeyHint: 'sk-ant-...',
    apiKeyLabel: 'Anthropic API Key',
    secureStorageKey: 'anthropic_api_key',
  ),
  'openai': CloudProviderSpec(
    id: 'openai',
    displayName: 'OpenAI (ChatGPT)',
    shortName: 'OpenAI',
    defaultHost: 'https://api.openai.com',
    apiKeyHint: 'sk-...',
    apiKeyLabel: 'OpenAI API Key',
    secureStorageKey: 'openai_api_key',
  ),
  'gemini': CloudProviderSpec(
    id: 'gemini',
    displayName: 'Google Gemini',
    shortName: 'Gemini',
    defaultHost: 'https://generativelanguage.googleapis.com',
    apiKeyHint: 'AIza...',
    apiKeyLabel: 'Google AI Studio API Key',
    secureStorageKey: 'gemini_api_key',
  ),
  'deepseek': CloudProviderSpec(
    id: 'deepseek',
    displayName: 'DeepSeek',
    shortName: 'DeepSeek',
    defaultHost: 'https://api.deepseek.com',
    apiKeyHint: 'sk-...',
    apiKeyLabel: 'DeepSeek API Key',
    secureStorageKey: 'deepseek_api_key',
  ),
  'qwen': CloudProviderSpec(
    id: 'qwen',
    displayName: '阿里通义千问',
    shortName: '千问',
    // DashScope 的 OpenAI 兼容入口 base URL（v1 段由 chat / models 端点拼接）。
    defaultHost: 'https://dashscope.aliyuncs.com/compatible-mode',
    apiKeyHint: 'sk-...',
    apiKeyLabel: 'DashScope API Key',
    secureStorageKey: 'qwen_api_key',
  ),
};

/// 兜底：[id] 不在目录里时返回 [cloudProviderCatalog]['anthropic']——历史默认
/// 值与现行行为保持一致，避免老 prefs 里残留的未知值崩 UI。
CloudProviderSpec cloudProviderSpec(String id) =>
    cloudProviderCatalog[id] ?? cloudProviderCatalog['anthropic']!;
