import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/reminder_router.dart';

/// ReminderRouter 单实例。
///
/// 无状态、纯函数式——所有依赖（ModelService、可见角色清单）每次 [route] 调用
/// 时由调用方提供，避免与 [appStateProvider] 互相依赖。
final reminderRouterProvider = Provider<ReminderRouter>((_) => ReminderRouter());
