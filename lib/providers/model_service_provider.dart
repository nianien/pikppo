import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/cloud_model_service.dart';
import '../services/cloud_provider_catalog.dart';
import '../services/gemini_service.dart';
import '../services/llm_gateway.dart';
import '../services/model_service.dart';
import '../services/ollama_service.dart';
import '../services/openai_compatible_service.dart';
import 'app_state_provider.dart';

final secureStorageProvider = Provider<FlutterSecureStorage>(
  (_) => const FlutterSecureStorage(),
);

/// 所有 cloud provider 的 API key 缓存。键 = provider id（见
/// [cloudProviderCatalog]），值 = key（空串表示未配置）。
///
/// **整体设计**：5 个 provider 不再各自一个 StateProvider——条目按 provider id
/// 入同一个 map，新增 provider 是 catalog 加一行，本层零改动。
///
/// 语义：
/// - map 缺该 provider key（如 `keys['openai']` 不存在）→ 尚未从 secure storage
///   读出来（启动时 [loadAllCloudApiKeys] 未跑完）
/// - 值为空串 → 已读出，但用户未配置
/// - 非空串 → 已配置的 key
final cloudApiKeysProvider =
    StateProvider<Map<String, String>>((_) => const {});

/// 开发期 key 兜底：`flutter run --dart-define-from-file=.env` 注入，免得每次
/// 重装 App 都要在设置页重新输入。未传 define（如正常 release 构建）时全为
/// 空串，零影响；secure storage 里已有的 key 永远优先于此处的值。
const _envSeedKeys = <String, String>{
  'anthropic': String.fromEnvironment('CLAUDE_API_KEY'),
  'openai': String.fromEnvironment('OPENAI_API_KEY'),
  'gemini': String.fromEnvironment('GEMINI_API_KEY'),
  'deepseek': String.fromEnvironment('DEEPSEEK_API_KEY'),
  'qwen': String.fromEnvironment('QWEN_API_KEY'),
};

/// 从 secure storage 把所有 provider 的 key 一次性灌进 [cloudApiKeysProvider]。
/// 启动时调一次。读失败的 provider 给空串，不阻塞其它 provider。
Future<void> loadAllCloudApiKeys({
  required FlutterSecureStorage storage,
  required void Function(Map<String, String>) setKeys,
}) async {
  final out = <String, String>{};
  for (final spec in cloudProviderCatalog.values) {
    var stored = '';
    try {
      stored = await storage.read(key: spec.secureStorageKey) ?? '';
    } catch (_) {}
    out[spec.id] =
        stored.isNotEmpty ? stored : (_envSeedKeys[spec.id] ?? '');
  }
  setKeys(out);
}

/// 保存某 provider 的 key，同步刷新内存缓存。Settings 输入框 onChanged 调。
Future<void> saveCloudApiKey({
  required FlutterSecureStorage storage,
  required String provider,
  required String key,
  required Map<String, String> currentKeys,
  required void Function(Map<String, String>) setKeys,
}) async {
  final spec = cloudProviderCatalog[provider];
  if (spec == null) {
    throw ArgumentError('unknown cloud provider: $provider');
  }
  await storage.write(key: spec.secureStorageKey, value: key);
  final updated = Map<String, String>.from(currentKeys)..[provider] = key;
  setKeys(updated);
}

/// 纯工厂：按配置组装 ModelService。`modelServiceProvider` 和
/// `AppStateNotifier._modelService()` 都通过它构建，单一来源避免分支漂移。
///
/// 之所以做成纯函数（而不是让 notifier 去 `ref.read(modelServiceProvider)`），
/// 是因为 `modelServiceProvider` 反过来 watch `appStateProvider`——若 notifier
/// 再读 provider，Riverpod 会判定循环依赖并抛 `CircularDependencyError`。
ModelService? buildModelService({
  required String type,
  required String host,
  required String localProvider,
  required String cloudProvider,
  required Map<String, String> cloudApiKeys,
}) {
  if (type == 'cloud') {
    // 网关模式（[useLlmGateway]）：云端经 pikppo-llm 中转，host 指网关、带网关
    // token、**不要求用户 key**（真实 key 在网关服务端）。详见 [llm_gateway.dart]。
    if (useLlmGateway) {
      final gwHost = llmGatewayHostFor(cloudProvider);
      final token = llmGatewayToken;
      switch (cloudProvider) {
        case 'gemini':
          return GeminiService(apiKey: '', host: gwHost, gatewayToken: token);
        case 'openai':
          return OpenAIService(apiKey: '', host: gwHost, gatewayToken: token);
        case 'deepseek':
          return DeepSeekService(apiKey: '', host: gwHost, gatewayToken: token);
        case 'qwen':
          return QwenService(apiKey: '', host: gwHost, gatewayToken: token);
        case 'anthropic':
        default:
          return CloudModelService(
              apiKey: '', host: gwHost, gatewayToken: token);
      }
    }
    // BYO 直连（无网关 token）：用户自配 key。
    final key = cloudApiKeys[cloudProvider] ?? '';
    if (key.isEmpty) return null;
    switch (cloudProvider) {
      case 'gemini':
        return GeminiService(apiKey: key, host: host);
      case 'openai':
        return OpenAIService(apiKey: key, host: host);
      case 'deepseek':
        return DeepSeekService(apiKey: key, host: host);
      case 'qwen':
        return QwenService(apiKey: key, host: host);
      case 'anthropic':
      default:
        return CloudModelService(apiKey: key, host: host);
    }
  }
  if (host.isEmpty) return null;
  switch (localProvider) {
    case 'ollama':
    default:
      return OllamaService(host);
  }
}

/// UI 层用：观察当前配置组装出来的 ModelService。Provider 内部 watch 配置字
/// 段，配置改变时返回新实例；`OllamaService` 的能力缓存通过 host 维度的 static
/// 表跨实例保活（见 `OllamaService` 内部）。
final modelServiceProvider = Provider<ModelService?>((ref) {
  return buildModelService(
    type: ref.watch(appStateProvider.select((s) => s.serviceType)),
    host: ref.watch(appStateProvider.select((s) => s.serviceHost)),
    localProvider:
        ref.watch(appStateProvider.select((s) => s.localProvider)),
    cloudProvider:
        ref.watch(appStateProvider.select((s) => s.cloudProvider)),
    cloudApiKeys: ref.watch(cloudApiKeysProvider),
  );
});

/// 各 provider 模型列表的缓存。键 = cloud provider id 或 `'local'`。
/// 启动时从 prefs 灌入（见 [decodeModelCache]），检测连接 / 切换面板首次拉取
/// 成功后写回——**模型列表是低频变化数据，不值得每次打开面板都打一遍 API**。
final modelCacheProvider =
    StateProvider<Map<String, List<String>>>((_) => const {});

const modelCachePrefsKey = 'modelListCache';

Future<void> persistModelCache(Map<String, List<String>> cache) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(modelCachePrefsKey, jsonEncode(cache));
}

Map<String, List<String>> decodeModelCache(String? raw) {
  if (raw == null || raw.isEmpty) return const {};
  try {
    final m = jsonDecode(raw) as Map<String, dynamic>;
    return m.map((k, v) => MapEntry(k, (v as List).cast<String>()));
  } catch (_) {
    return const {};
  }
}

/// 把一次成功的拉取结果写入缓存并持久化。
void updateModelCache(WidgetRef ref, String providerId, List<String> models) {
  final updated = {...ref.read(modelCacheProvider), providerId: models};
  ref.read(modelCacheProvider.notifier).state = updated;
  unawaited(persistModelCache(updated));
}

/// 清掉某 provider 的缓存（key 变更 / 手动刷新时），下次读取自动重新拉。
void invalidateModelCache(WidgetRef ref, String providerId) {
  final updated = {...ref.read(modelCacheProvider)}..remove(providerId);
  ref.read(modelCacheProvider.notifier).state = updated;
  unawaited(persistModelCache(updated));
}

/// 对话内切换面板用：按 provider 拉模型列表，**不改全局配置**。
/// family key：cloud provider id，或 `'local'`（当前本地推理服务）。
/// 缓存优先：命中 [modelCacheProvider] 直接返回（零网络请求）；未命中才打
/// API，成功后写回缓存。host 规则：该 provider 就是当前生效配置时尊重用户
/// 自定义 host，否则用默认。
final providerModelsProvider = FutureProvider.autoDispose
    .family<List<String>, String>((ref, providerId) async {
  final cached =
      ref.watch(modelCacheProvider.select((c) => c[providerId]));
  if (cached != null && cached.isNotEmpty) return cached;

  final type = ref.watch(appStateProvider.select((s) => s.serviceType));
  final host = ref.watch(appStateProvider.select((s) => s.serviceHost));
  final ModelService? service;
  if (providerId == 'local') {
    service = buildModelService(
      type: 'local',
      host: host,
      localProvider:
          ref.watch(appStateProvider.select((s) => s.localProvider)),
      cloudProvider: '',
      cloudApiKeys: const {},
    );
  } else {
    final cloudProvider =
        ref.watch(appStateProvider.select((s) => s.cloudProvider));
    final effectiveHost = (type == 'cloud' && cloudProvider == providerId)
        ? host
        : cloudProviderSpec(providerId).defaultHost;
    service = buildModelService(
      type: 'cloud',
      host: effectiveHost,
      localProvider: '',
      cloudProvider: providerId,
      cloudApiKeys: ref.watch(cloudApiKeysProvider),
    );
  }
  final list = await service?.fetchModels() ?? const <String>[];
  if (list.isNotEmpty) {
    final updated = {...ref.read(modelCacheProvider), providerId: list};
    ref.read(modelCacheProvider.notifier).state = updated;
    unawaited(persistModelCache(updated));
  }
  return list;
});
