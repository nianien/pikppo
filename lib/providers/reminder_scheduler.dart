import 'dart:async';
import '../models/calendar_event.dart';

/// 日程提醒巡检——独立组件，只负责"扫描日程 → 命中提醒窗口 → 回调通知"。
///
/// 与 AppState 解耦：通过 [getEvents] 拉当前日程，通过 [onReminder] 通知触发，
/// AppStateNotifier 负责把通知翻成 UI 上的"⏰"消息。
class ReminderScheduler {
  final Duration interval;
  final List<CalendarEvent> Function() getEvents;
  final void Function(CalendarEvent event, int diffMinutes) onReminder;

  Timer? _timer;
  final Set<String> _remindedIds = {};

  ReminderScheduler({
    required this.interval,
    required this.getEvents,
    required this.onReminder,
  });

  void start() {
    _timer?.cancel();
    _timer = Timer.periodic(interval, (_) => _tick());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// 事件被更新（时间/提醒改了）时，调用方应清掉对应 id——让事件可以重新进入
  /// 提醒窗口。
  void forget(String eventId) => _remindedIds.remove(eventId);

  void _tick() {
    final now = DateTime.now();
    for (final event in getEvents()) {
      if (event.time == null || event.reminderMinutes == null) continue;
      final parts = event.time!.split(':');
      if (parts.length != 2) continue;
      final eventDateTime = DateTime(
        event.date.year,
        event.date.month,
        event.date.day,
        int.parse(parts[0]),
        int.parse(parts[1]),
      );
      final diffMinutes = eventDateTime.difference(now).inMinutes;
      if (diffMinutes <= 0) continue;
      if (diffMinutes > event.reminderMinutes!) continue;
      if (_remindedIds.contains(event.id)) continue;
      _remindedIds.add(event.id);
      onReminder(event, diffMinutes);
    }
  }
}
