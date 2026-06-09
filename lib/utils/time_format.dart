/// 时间/日期格式化工具。**唯一来源**，禁止再分散到各 widget/notifier。
library;

const _weekdays = ['一', '二', '三', '四', '五', '六', '日'];

/// `YYYY-MM-DD`。
String fmtDate(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

/// 周中文：`周一`/`周二`/…/`周日`。
String fmtWeekday(DateTime d) => '周${_weekdays[d.weekday - 1]}';

/// `HH:mm`。
String fmtHourMinute(DateTime d) =>
    '${d.hour.toString().padLeft(2, '0')}:'
    '${d.minute.toString().padLeft(2, '0')}';

/// `YYYY-MM-DD 周X HH:mm`，用于消息 tooltip。
String fmtMessageStamp(DateTime d) =>
    '${fmtDate(d)} ${fmtWeekday(d)} ${fmtHourMinute(d)}';

/// system prompt 用："当前时间是 YYYY-MM-DD 周X HH:mm CST"——含时区缩写与 UTC 偏移。
String fmtSystemTimestamp(DateTime now) {
  final tz = now.timeZoneName;
  final offset = now.timeZoneOffset;
  final sign = offset.isNegative ? '-' : '+';
  final hOff = offset.inHours.abs().toString().padLeft(2, '0');
  final mOff = (offset.inMinutes.abs() % 60).toString().padLeft(2, '0');
  return '${fmtDate(now)} ${fmtWeekday(now)} ${fmtHourMinute(now)} '
      '$tz UTC$sign$hOff:$mOff';
}
