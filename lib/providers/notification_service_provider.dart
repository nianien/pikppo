import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/notification_service.dart';

/// NotificationService 单实例——只有一个，全 App 共享。
///
/// 初始化（[NotificationService.init]）在 main.dart 启动早期完成，时机点是
/// 拿到全局 NavigatorState 之后、`runApp` 之前；onTap 回调里用全局
/// scaffoldMessengerKey 做 deep link 调度（见 main.dart）。
final notificationServiceProvider =
    Provider<NotificationService>((_) => NotificationService());
