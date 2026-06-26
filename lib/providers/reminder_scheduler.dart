import 'dart:async';
import '../models/calendar_event.dart';

/// 一条到点的提醒——`diffMinutes` 是相对当前时刻"还有多少分钟开始"，用于
/// 消息措辞（"30 分钟后开始" / "约 1 小时后开始"）。
class ReminderEvent {
  final CalendarEvent event;
  final int diffMinutes;
  const ReminderEvent(this.event, this.diffMinutes);
}

/// 日程提醒巡检——独立组件，跟数据源与消息呈现层都解耦。
///
/// 数据流向：
///   CalendarRepository 改动 → drift watch → AppStateNotifier.setEvents
///   ReminderScheduler 周期性 _tick → 命中事件入 [events] 流
///   AppStateNotifier 订阅 [events] → 路由（ReminderRouter）→ 在目标角色私聊
///   里 append kind='reminder' 消息
///
/// **为什么用 Stream 而非 callback**：呈现层（toast / 聊天消息 / 系统通知）的
/// 选择是产品决策，scheduler 不该硬编码。Stream 让订阅者自决，scheduler 自
/// 己只管"什么时候算到点"。
class ReminderScheduler {
  final Duration interval;

  Timer? _timer;
  final Set<String> _remindedIds = {};
  List<CalendarEvent> _events = const [];
  final _controller = StreamController<ReminderEvent>.broadcast();

  ReminderScheduler({required this.interval});

  /// 命中提醒窗口的事件流。订阅者在收到一条 [ReminderEvent] 后自行决定如何
  /// 呈现（路由到角色私聊、toast、系统通知等）。每条事件只发出一次（避免
  /// 一个事件刷屏），由 [forget] / [setEvents] 决定何时允许再次进入窗口。
  Stream<ReminderEvent> get events => _controller.stream;

  void start() {
    _timer?.cancel();
    _timer = Timer.periodic(interval, (_) => _tick());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  void dispose() {
    stop();
    _controller.close();
  }

  /// 把"当前窗口内的所有事件"推进来——通常是 30 天内非墓碑事件。每次新流推送
  /// 时调用，scheduler 内部不缓存历史窗口。
  void setEvents(List<CalendarEvent> events) {
    _events = events;
    // 窗口外的事件清出去重表——避免长期累积。
    final liveIds = events.map((e) => e.id).toSet();
    _remindedIds.removeWhere((id) => !liveIds.contains(id));
  }

  /// 事件被更新（时间/提醒改了）或删除时，调用方应清掉对应 id——让事件可以
  /// 重新进入提醒窗口。Repository 的 `_afterWrite` 和 `delete` 都会调它。
  void forget(String eventId) => _remindedIds.remove(eventId);

  void _tick() {
    final now = DateTime.now();
    for (final event in _events) {
      final reminder = event.reminderMinutes;
      if (reminder == null) continue;
      if (event.allDay) continue;
      final localStart = event.localStart;
      final diffMinutes = localStart.difference(now).inMinutes;
      if (diffMinutes <= 0) continue;
      if (diffMinutes > reminder) continue;
      if (_remindedIds.contains(event.id)) continue;
      _remindedIds.add(event.id);
      _controller.add(ReminderEvent(event, diffMinutes));
    }
  }
}
