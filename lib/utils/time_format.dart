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

const _monthAbbr = <String, int>{
  'Jan': 1, 'Feb': 2, 'Mar': 3, 'Apr': 4, 'May': 5, 'Jun': 6,
  'Jul': 7, 'Aug': 8, 'Sep': 9, 'Oct': 10, 'Nov': 11, 'Dec': 12,
};

/// 解析 RFC-1123 / HTTP 日期串（如 `Tue, 16 Jun 2026 00:02:31 +0000`、
/// 末尾也可为 `GMT`/`UTC`），返回**UTC** [DateTime]；无法解析返回 null。
/// 外部 API（汇率等）的 `updated_at` 常是这种格式，客户端需转本地时区再展示。
DateTime? parseRfc1123(String s) {
  final m = RegExp(
    r'(\d{1,2})\s+([A-Za-z]{3})\s+(\d{4})\s+(\d{2}):(\d{2}):(\d{2})\s*([+-]\d{4}|GMT|UTC)?',
  ).firstMatch(s.trim());
  if (m == null) return null;
  final month = _monthAbbr[m.group(2)!];
  if (month == null) return null;
  var dt = DateTime.utc(
    int.parse(m.group(3)!), // year
    month,
    int.parse(m.group(1)!), // day
    int.parse(m.group(4)!), // hour
    int.parse(m.group(5)!), // minute
    int.parse(m.group(6)!), // second
  );
  // 把带 ±zzzz 偏移的挂钟时间换算回真正的 UTC 瞬间（GMT/UTC/缺省视为 +0000）。
  final tz = m.group(7);
  if (tz != null && tz != 'GMT' && tz != 'UTC') {
    final sign = tz[0] == '-' ? -1 : 1;
    dt = dt.subtract(Duration(
      hours: sign * int.parse(tz.substring(1, 3)),
      minutes: sign * int.parse(tz.substring(3, 5)),
    ));
  }
  return dt;
}

/// 把外部接口的更新时间串格式化成**本地时区**的中文相对时间：
/// `今天 HH:mm` / `昨天 HH:mm` / `M月D日 HH:mm` / `YYYY年M月D日 HH:mm`。
/// 解析失败时原样返回（不丢信息）。
String fmtUpdatedAt(String raw) {
  final utc = parseRfc1123(raw);
  if (utc == null) return raw;
  final local = utc.toLocal();
  final now = DateTime.now();
  final diffDays = DateTime(now.year, now.month, now.day)
      .difference(DateTime(local.year, local.month, local.day))
      .inDays;
  final hm = fmtHourMinute(local);
  if (diffDays == 0) return '今天 $hm';
  if (diffDays == 1) return '昨天 $hm';
  if (local.year == now.year) return '${local.month}月${local.day}日 $hm';
  return '${local.year}年${local.month}月${local.day}日 $hm';
}

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
