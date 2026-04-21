import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/model_service.dart';
import '../services/ollama_service.dart';
import '../services/lmstudio_service.dart';
import 'app_state_provider.dart';

final modelServiceProvider = Provider<ModelService?>((ref) {
  final appState = ref.watch(appStateProvider);
  if (appState.serviceHost.isEmpty) return null;

  if (appState.serviceType == 'ollama') {
    return OllamaService(appState.serviceHost);
  } else {
    return LMStudioService(appState.serviceHost);
  }
});

final availableModelsProvider =
    FutureProvider.autoDispose<List<String>>((ref) async {
  final service = ref.watch(modelServiceProvider);
  if (service == null) return [];
  return service.fetchModels();
});
