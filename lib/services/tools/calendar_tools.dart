import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../models/calendar_event.dart';
import '../../providers/calendar_repository_provider.dart';
import '../../repositories/calendar_repository.dart';
import '../../utils/tool_error_code.dart';
import '../../utils/user_facing_error.dart';
import '../tool_registry.dart';

/// 注册 4 个 LocalTool 暴露给 LLM agent loop：
/// `calendar_list_events` / `calendar_create_event` / `calendar_update_event` /
/// `calendar_delete_event`。
///
/// 每个 handler 是 JSON ↔ Repository 的薄壳——**不含业务逻辑**。日程的盖戳、
/// 软删、reminder 调度全部在 [CalendarRepository] 里，与 UI 共享同一路径，
/// "LLM 加的日程"与"手动加的日程"行为完全一致。
List<LocalTool> buildCalendarTools(Ref ref) {
  Future<CalendarRepository> repo() =>
      ref.read(calendarRepositoryProvider.future);

  return [
    LocalTool(
      name: 'calendar_list_events',
      description: '列出用户本地日历中指定日期范围内的日程。'
          'start_date / end_date 是 ISO 8601 本地日期（YYYY-MM-DD），闭区间。',
      inputSchema: const {
        'type': 'object',
        'properties': {
          'start_date': {
            'type': 'string',
            'description': '起始日期（YYYY-MM-DD），按设备本地时区解释',
          },
          'end_date': {
            'type': 'string',
            'description': '结束日期（YYYY-MM-DD），按设备本地时区解释；含当天',
          },
        },
        'required': ['start_date', 'end_date'],
      },
      handler: (input) async {
        try {
          final start = _parseLocalDateStart(input['start_date']);
          final end = _parseLocalDateEnd(input['end_date']);
          final events = await (await repo()).listRange(start, end);
          return jsonEncode({
            'events': events.map(_eventToToolJson).toList(),
          });
        } on FormatException catch (e) {
          return _toolError(ToolErrorCode.invalidInput, e.message);
        } catch (e) {
          debugPrint('calendar_list_events failed: ${debugReason(e)}');
          return _toolError(ToolErrorCode.invalidInput, e.toString());
        }
      },
    ),
    LocalTool(
      name: 'calendar_create_event',
      description: '在用户的本地日历中创建一个新日程。'
          'start_time 是 ISO 8601，建议带时区（如 2026-06-15T14:00:00+08:00）；'
          '不带时区时按设备本地时区解析。',
      inputSchema: const {
        'type': 'object',
        'properties': {
          'title': {'type': 'string', 'description': '日程标题'},
          'start_time': {
            'type': 'string',
            'description': 'ISO 8601 开始时间，建议带时区',
          },
          'end_time': {
            'type': 'string',
            'description': 'ISO 8601 结束时间（可选）',
          },
          'description': {
            'type': 'string',
            'description': '备注（可选）',
          },
          'reminder_minutes': {
            'type': 'integer',
            'description': '提前多少分钟提醒（可选）',
          },
          'all_day': {
            'type': 'boolean',
            'description': '是否全天日程（可选，默认 false）',
          },
        },
        'required': ['title', 'start_time'],
      },
      handler: (input) async {
        try {
          final draft = _draftFromInput(input);
          final created = await (await repo()).create(draft);
          return jsonEncode({
            'ok': true,
            'id': created.id,
            'title': created.title,
            'start_time': created.startTime.toIso8601String(),
          });
        } on FormatException catch (e) {
          return _toolError(ToolErrorCode.invalidInput, e.message);
        } catch (e) {
          debugPrint('calendar_create_event failed: ${debugReason(e)}');
          return _toolError(ToolErrorCode.invalidInput, e.toString());
        }
      },
    ),
    LocalTool(
      name: 'calendar_update_event',
      description: '修改用户本地日历中已有日程。'
          'id 必填，其它字段按需提供——未提供的字段保持原值。',
      inputSchema: const {
        'type': 'object',
        'properties': {
          'id': {'type': 'string', 'description': '日程 id'},
          'title': {'type': 'string'},
          'start_time': {'type': 'string', 'description': 'ISO 8601'},
          'end_time': {'type': 'string', 'description': 'ISO 8601；空字符串表示清除'},
          'description': {'type': 'string'},
          'reminder_minutes': {
            'type': 'integer',
            'description': '提醒分钟数；-1 表示清除提醒',
          },
          'all_day': {'type': 'boolean'},
        },
        'required': ['id'],
      },
      handler: (input) async {
        final id = input['id'];
        if (id is! String || id.isEmpty) {
          return _toolError(ToolErrorCode.invalidInput, 'id is required');
        }
        try {
          final patch = _patchFromInput(input);
          final updated = await (await repo()).update(id, patch);
          return jsonEncode({
            'ok': true,
            'id': updated.id,
            'title': updated.title,
            'start_time': updated.startTime.toIso8601String(),
          });
        } on CalendarEventNotFound {
          return _toolError(ToolErrorCode.notFound, 'event $id not found');
        } on FormatException catch (e) {
          return _toolError(ToolErrorCode.invalidInput, e.message);
        } catch (e) {
          debugPrint('calendar_update_event failed: ${debugReason(e)}');
          return _toolError(ToolErrorCode.invalidInput, e.toString());
        }
      },
    ),
    LocalTool(
      name: 'calendar_delete_event',
      description: '从用户本地日历中删除一个日程。id 不存在时静默返回成功（幂等）。',
      inputSchema: const {
        'type': 'object',
        'properties': {
          'id': {'type': 'string', 'description': '日程 id'},
        },
        'required': ['id'],
      },
      handler: (input) async {
        final id = input['id'];
        if (id is! String || id.isEmpty) {
          return _toolError(ToolErrorCode.invalidInput, 'id is required');
        }
        try {
          await (await repo()).delete(id);
          return jsonEncode({'ok': true});
        } catch (e) {
          debugPrint('calendar_delete_event failed: ${debugReason(e)}');
          return _toolError(ToolErrorCode.invalidInput, e.toString());
        }
      },
    ),
  ];
}

// ---- 输入解析 ----

CalendarEventDraft _draftFromInput(Map<String, dynamic> input) {
  final title = _requireString(input, 'title');
  final startTime = _parseEventTime(_requireString(input, 'start_time'));
  final endTimeRaw = input['end_time'];
  final endTime = (endTimeRaw is String && endTimeRaw.isNotEmpty)
      ? _parseEventTime(endTimeRaw)
      : null;
  final description = (input['description'] as String?) ?? '';
  final reminder = input['reminder_minutes'];
  return CalendarEventDraft(
    title: title,
    description: description,
    startTime: startTime,
    endTime: endTime,
    allDay: (input['all_day'] as bool?) ?? false,
    reminderMinutes:
        reminder is int && reminder >= 0 ? reminder : null,
  );
}

CalendarEventPatch _patchFromInput(Map<String, dynamic> input) {
  DateTime? startTime;
  if (input['start_time'] is String) {
    startTime = _parseEventTime(input['start_time'] as String);
  }
  DateTime? endTime;
  var clearEndTime = false;
  if (input.containsKey('end_time')) {
    final raw = input['end_time'];
    if (raw is String && raw.isNotEmpty) {
      endTime = _parseEventTime(raw);
    } else if (raw == null || (raw is String && raw.isEmpty)) {
      clearEndTime = true;
    }
  }
  int? reminderMinutes;
  var clearReminder = false;
  if (input.containsKey('reminder_minutes')) {
    final raw = input['reminder_minutes'];
    if (raw is int) {
      if (raw < 0) {
        clearReminder = true;
      } else {
        reminderMinutes = raw;
      }
    } else if (raw == null) {
      clearReminder = true;
    }
  }
  return CalendarEventPatch(
    title: input['title'] as String?,
    description: input['description'] as String?,
    startTime: startTime,
    endTime: endTime,
    clearEndTime: clearEndTime,
    allDay: input['all_day'] as bool?,
    reminderMinutes: reminderMinutes,
    clearReminderMinutes: clearReminder,
  );
}

/// 时间解析容错：`DateTime.parse` 同时吃带时区（`...+08:00` / `...Z`）和不带时
/// 区（按设备本地时区解析）。一律转 UTC 返回——库里只存 UTC。
DateTime _parseEventTime(String input) {
  return DateTime.parse(input).toUtc();
}

/// 把 "YYYY-MM-DD" 解释成设备本地零点对应的 UTC 时刻。
DateTime _parseLocalDateStart(Object? raw) {
  if (raw is! String) {
    throw const FormatException('start_date must be YYYY-MM-DD');
  }
  final parsed = DateTime.parse(raw); // 不带时区 → 本地
  return DateTime(parsed.year, parsed.month, parsed.day).toUtc();
}

/// 把 "YYYY-MM-DD" 解释成设备本地当日 23:59:59.999 对应的 UTC 时刻——闭区间。
DateTime _parseLocalDateEnd(Object? raw) {
  if (raw is! String) {
    throw const FormatException('end_date must be YYYY-MM-DD');
  }
  final parsed = DateTime.parse(raw);
  return DateTime(
    parsed.year,
    parsed.month,
    parsed.day,
    23,
    59,
    59,
    999,
  ).toUtc();
}

String _requireString(Map<String, dynamic> input, String key) {
  final v = input[key];
  if (v is! String || v.isEmpty) {
    throw FormatException('$key is required');
  }
  return v;
}

// ---- 返回投影 ----

/// 单条事件投影给 LLM：精简字段 + description 截断 300 字符（避免 context 爆）。
Map<String, dynamic> _eventToToolJson(CalendarEvent e) {
  return {
    'id': e.id,
    'title': e.title,
    'start': e.startTime.toIso8601String(),
    if (e.endTime != null) 'end': e.endTime!.toIso8601String(),
    if (e.allDay) 'all_day': true,
    if (e.description.isNotEmpty) 'description': _truncate(e.description, 300),
    if (e.reminderMinutes != null) 'reminder_minutes': e.reminderMinutes,
  };
}

String _truncate(String s, int max) =>
    s.length <= max ? s : '${s.substring(0, max)}…';

String _toolError(String code, String detail) =>
    jsonEncode({'ok': false, 'error': code, 'detail': detail});
