import 'package:dio/dio.dart';
import 'model_service.dart';

class LMStudioService extends ModelService {
  late final Dio _dio;

  LMStudioService(super.host) {
    _dio = Dio(BaseOptions(
      baseUrl: host,
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 30),
    ));
  }

  @override
  Future<List<String>> fetchModels() async {
    final response = await _dio.get('/v1/models');
    final models = response.data['data'] as List;
    return models.map((m) => m['id'] as String).toList();
  }

  @override
  Future<String> chat(List<Map<String, String>> messages, String model) async {
    final response = await _dio.post('/v1/chat/completions', data: {
      'model': model,
      'messages': messages,
      'stream': false,
    });
    return response.data['choices'][0]['message']['content'] as String;
  }
}
