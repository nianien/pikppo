import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../services/model_service.dart';
import '../services/ollama_service.dart';
import '../services/cloud_model_service.dart';
import '../services/gemini_service.dart';
import 'app_state_provider.dart';

const _kAnthropicApiKey = 'anthropic_api_key';
const _kGeminiApiKey = 'gemini_api_key';

final secureStorageProvider = Provider<FlutterSecureStorage>(
  (_) => const FlutterSecureStorage(),
);

/// Cached Anthropic API key. `null` means not loaded yet; '' means absent.
final anthropicApiKeyProvider = StateProvider<String?>((_) => null);

/// Cached Gemini API key. Same null/'' semantics as Anthropic.
final geminiApiKeyProvider = StateProvider<String?>((_) => null);

/// Read the persisted Anthropic API key into [anthropicApiKeyProvider]. The
/// caller passes the storage + a setter so the helper works from both
/// provider-side ([Ref]) and widget-side ([WidgetRef]).
Future<void> loadAnthropicApiKeyWith({
  required FlutterSecureStorage storage,
  required void Function(String) setKey,
}) async {
  final value = await storage.read(key: _kAnthropicApiKey) ?? '';
  setKey(value);
}

Future<void> saveAnthropicApiKeyWith({
  required FlutterSecureStorage storage,
  required String key,
  required void Function(String) setKey,
}) async {
  await storage.write(key: _kAnthropicApiKey, value: key);
  setKey(key);
}

Future<void> loadGeminiApiKeyWith({
  required FlutterSecureStorage storage,
  required void Function(String) setKey,
}) async {
  final value = await storage.read(key: _kGeminiApiKey) ?? '';
  setKey(value);
}

Future<void> saveGeminiApiKeyWith({
  required FlutterSecureStorage storage,
  required String key,
  required void Function(String) setKey,
}) async {
  await storage.write(key: _kGeminiApiKey, value: key);
  setKey(key);
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
  required String? anthropicKey,
  required String? geminiKey,
}) {
  if (type == 'cloud') {
    if (cloudProvider == 'gemini') {
      final key = geminiKey ?? '';
      if (key.isEmpty) return null;
      return GeminiService(apiKey: key, host: host);
    }
    final key = anthropicKey ?? '';
    if (key.isEmpty) return null;
    return CloudModelService(apiKey: key, host: host);
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
    anthropicKey: ref.watch(anthropicApiKeyProvider),
    geminiKey: ref.watch(geminiApiKeyProvider),
  );
});

final availableModelsProvider =
    FutureProvider.autoDispose<List<String>>((ref) async {
  final service = ref.watch(modelServiceProvider);
  if (service == null) return [];
  return service.fetchModels();
});
