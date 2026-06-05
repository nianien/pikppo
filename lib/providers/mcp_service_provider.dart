import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/mcp_service.dart';

/// Singleton McpService kept alive for the app lifetime. Connection is
/// initiated by [AppStateNotifier] once persisted state has loaded.
final mcpServiceProvider = Provider<McpService>((ref) {
  final service = McpService();
  ref.onDispose(service.dispose);
  return service;
});
