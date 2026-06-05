import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../services/model_service.dart';
import '../services/ollama_service.dart';
import '../services/lmstudio_service.dart';
import '../services/cloud_model_service.dart';
import 'app_state_provider.dart';

const _kAnthropicApiKey = 'anthropic_api_key';

final secureStorageProvider = Provider<FlutterSecureStorage>(
  (_) => const FlutterSecureStorage(),
);

/// Cached Anthropic API key. `null` means not loaded yet; '' means absent.
final anthropicApiKeyProvider = StateProvider<String?>((_) => null);

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

final modelServiceProvider = Provider<ModelService?>((ref) {
  final appState = ref.watch(appStateProvider);
  if (appState.serviceType == 'cloud') {
    final apiKey = ref.watch(anthropicApiKeyProvider) ?? '';
    if (apiKey.isEmpty) return null;
    return CloudModelService(apiKey: apiKey, host: appState.serviceHost);
  }
  if (appState.serviceHost.isEmpty) return null;
  if (appState.serviceType == 'ollama') {
    return OllamaService(appState.serviceHost);
  }
  return LMStudioService(appState.serviceHost);
});

final availableModelsProvider =
    FutureProvider.autoDispose<List<String>>((ref) async {
  final service = ref.watch(modelServiceProvider);
  if (service == null) return [];
  return service.fetchModels();
});
