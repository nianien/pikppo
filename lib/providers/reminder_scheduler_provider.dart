import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'reminder_scheduler.dart';

/// Reminder 巡检频率——30s 足够准确（提醒精度本来就以分钟为单位），又不至于
/// 真机后台耗电。
const _kReminderInterval = Duration(seconds: 30);

/// ReminderScheduler 单实例。
///
/// **独立于 [appStateProvider]** 是为了打破 Repository ↔ AppStateNotifier 的
/// 循环依赖：CalendarRepository 构造时需要 scheduler 引用以在写后 `forget`，
/// 而 AppStateNotifier 又订阅 calendar 流并把事件 push 给 scheduler——拆出
/// provider 后两条依赖各自走单向。
///
/// 提醒命中时不再走 toast；由 [AppStateNotifier] 订阅 `events` 流后，经
/// ReminderRouter 路由到角色私聊，以 `kind='reminder'` 聊天消息呈现
/// （v3.1 §4 / 产品方案 §3.2）。
final reminderSchedulerProvider = Provider<ReminderScheduler>((ref) {
  final scheduler = ReminderScheduler(interval: _kReminderInterval);
  scheduler.start();
  ref.onDispose(scheduler.dispose);
  return scheduler;
});
