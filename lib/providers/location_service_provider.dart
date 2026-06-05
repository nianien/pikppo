import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/location_service.dart';

/// Singleton LocationService kept alive for the app lifetime.
/// AppStateNotifier 启动时触发一次 refresh，之后由 LocationService 内部根据
/// maxAge 决定是否真的去拉 GPS。
final locationServiceProvider = Provider<LocationService>((ref) {
  return LocationService();
});
