/// 日历事件——local-first 数据模型，对应 drift `calendar_events` 表与服务端
/// `calendar_events` 行的并集。
///
/// 时间字段语义：
/// - [startTime] / [endTime] / [updatedAt] **一律 UTC**——LWW 冲突解决与跨设备
///   同步都依赖绝对时间。展示时调用方自行 `.toLocal()`，模型不缓存本地副本以
///   避免时区切换后产生数据不一致。
/// - [allDay] 为 true 时，[startTime] 取本地零点对应的 UTC 时刻，UI 只显示日期。
///
/// 同步元数据：
/// - [dirty]=true 表示有未推送到服务端的变更；Phase 1 写操作全部置 true。
/// - [deleted]=true 是墓碑行，UI 与 LLM 均看不到；DAO 读层统一过滤。
/// - [serverVersion] 由服务端在 push 接受时回填；Phase 1 恒为 null。
class CalendarEvent {
  final String id;
  final String title;
  final String description;
  final DateTime startTime;
  final DateTime? endTime;
  final bool allDay;
  final String? recurrenceRule;
  final int? reminderMinutes;

  /// 提醒归属角色 id（v3.2）——事件写入时由 ReminderRouter 决定；nullable 表示
  /// 尚未路由（v3 老行 / 路由失败），触发时由 dispatcher 即时兜底。
  final String? routedRoleId;

  final DateTime updatedAt;
  final bool deleted;
  final bool dirty;
  final int? serverVersion;

  const CalendarEvent({
    required this.id,
    required this.title,
    required this.startTime,
    required this.updatedAt,
    this.description = '',
    this.endTime,
    this.allDay = false,
    this.recurrenceRule,
    this.reminderMinutes,
    this.routedRoleId,
    this.deleted = false,
    this.dirty = true,
    this.serverVersion,
  });

  CalendarEvent copyWith({
    String? title,
    String? description,
    DateTime? startTime,
    DateTime? endTime,
    bool clearEndTime = false,
    bool? allDay,
    String? recurrenceRule,
    bool clearRecurrenceRule = false,
    int? reminderMinutes,
    bool clearReminderMinutes = false,
    String? routedRoleId,
    bool clearRoutedRoleId = false,
    DateTime? updatedAt,
    bool? deleted,
    bool? dirty,
    int? serverVersion,
    bool clearServerVersion = false,
  }) {
    return CalendarEvent(
      id: id,
      title: title ?? this.title,
      description: description ?? this.description,
      startTime: startTime ?? this.startTime,
      endTime: clearEndTime ? null : (endTime ?? this.endTime),
      allDay: allDay ?? this.allDay,
      recurrenceRule:
          clearRecurrenceRule ? null : (recurrenceRule ?? this.recurrenceRule),
      reminderMinutes: clearReminderMinutes
          ? null
          : (reminderMinutes ?? this.reminderMinutes),
      routedRoleId:
          clearRoutedRoleId ? null : (routedRoleId ?? this.routedRoleId),
      updatedAt: updatedAt ?? this.updatedAt,
      deleted: deleted ?? this.deleted,
      dirty: dirty ?? this.dirty,
      serverVersion:
          clearServerVersion ? null : (serverVersion ?? this.serverVersion),
    );
  }

  // ---- UI 投影 ----

  /// 本地时区下的开始时刻——所有 UI 渲染、reminder 调度都用它换算。
  DateTime get localStart => startTime.toLocal();

  /// 本地时区下的结束时刻——若无 [endTime] 则退化到 [localStart]。
  DateTime get localEnd => (endTime ?? startTime).toLocal();

  /// 本地日期（零点）——UI 按日筛选时的归属日。
  DateTime get localDate {
    final l = localStart;
    return DateTime(l.year, l.month, l.day);
  }

  /// 本地时间 "HH:mm"；[allDay] 时返回 null（UI 显示"全天"）。
  String? get localTimeLabel {
    if (allDay) return null;
    final l = localStart;
    return _hhmm(l);
  }

  String? get localEndTimeLabel {
    if (allDay || endTime == null) return null;
    return _hhmm(endTime!.toLocal());
  }

  String? get reminderText {
    final m = reminderMinutes;
    if (m == null) return null;
    if (m >= 1440) return '提前${m ~/ 1440}天';
    if (m >= 60) return '提前${m ~/ 60}小时';
    return '提前$m分钟';
  }

  static String _hhmm(DateTime dt) =>
      '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
}

/// 创建日程时的入参：仅业务字段，无 id / 同步元数据——这些由 Repository 盖戳。
class CalendarEventDraft {
  final String title;
  final String description;
  final DateTime startTime;
  final DateTime? endTime;
  final bool allDay;
  final String? recurrenceRule;
  final int? reminderMinutes;

  const CalendarEventDraft({
    required this.title,
    required this.startTime,
    this.description = '',
    this.endTime,
    this.allDay = false,
    this.recurrenceRule,
    this.reminderMinutes,
  });

  CalendarEvent toEvent({
    required String id,
    required DateTime updatedAt,
  }) {
    return CalendarEvent(
      id: id,
      title: title,
      description: description,
      startTime: startTime.toUtc(),
      endTime: endTime?.toUtc(),
      allDay: allDay,
      recurrenceRule: recurrenceRule,
      reminderMinutes: reminderMinutes,
      updatedAt: updatedAt,
      deleted: false,
      dirty: true,
    );
  }
}

/// 更新日程时的入参：每个字段非空意味"设为该值"；为空意味"保持不变"。
///
/// 对 nullable 字段（[endTime] / [recurrenceRule] / [reminderMinutes]）增设 `clearX`
/// 标志区分"保持不变"和"显式置 null"——LocalTool 与 UI 都需要这种区分。
class CalendarEventPatch {
  final String? title;
  final String? description;
  final DateTime? startTime;
  final DateTime? endTime;
  final bool clearEndTime;
  final bool? allDay;
  final String? recurrenceRule;
  final bool clearRecurrenceRule;
  final int? reminderMinutes;
  final bool clearReminderMinutes;

  const CalendarEventPatch({
    this.title,
    this.description,
    this.startTime,
    this.endTime,
    this.clearEndTime = false,
    this.allDay,
    this.recurrenceRule,
    this.clearRecurrenceRule = false,
    this.reminderMinutes,
    this.clearReminderMinutes = false,
  });

  CalendarEvent applyTo(CalendarEvent base) {
    return base.copyWith(
      title: title,
      description: description,
      startTime: startTime?.toUtc(),
      endTime: endTime?.toUtc(),
      clearEndTime: clearEndTime,
      allDay: allDay,
      recurrenceRule: recurrenceRule,
      clearRecurrenceRule: clearRecurrenceRule,
      reminderMinutes: reminderMinutes,
      clearReminderMinutes: clearReminderMinutes,
    );
  }
}
