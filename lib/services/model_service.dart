abstract class ModelService {
  final String host;

  ModelService(this.host);

  Future<List<String>> fetchModels();
  Future<String> chat(List<Map<String, String>> messages, String model);
}
