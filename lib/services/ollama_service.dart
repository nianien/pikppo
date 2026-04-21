import 'package:dio/dio.dart';
import 'model_service.dart';

class OllamaService extends ModelService {
  late final Dio _dio;

  OllamaService(super.host) {
    _dio = Dio(BaseOptions(
      baseUrl: host,
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 120),
    ));
  }

  @override
  Future<List<String>> fetchModels() async {
    final response = await _dio.get('/api/tags');
    final models = response.data['models'] as List;
    return models.map((m) => m['name'] as String).toList();
  }

  @override
  Future<String> chat(List<Map<String, String>> messages, String model) async {
    final response = await _dio.post('/api/chat', data: {
      'model': model,
      'messages': messages,
      'stream': false,
    });
    return response.data['message']['content'] as String;
  }
}
