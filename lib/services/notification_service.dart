import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;
import '../models/calendar_event.dart';
import '../models/role.dart';

/// 提醒通知服务——把日历事件预调度到 OS（iOS UNUserNotificationCenter /
/// Android AlarmManager），App 被杀也能弹。
///
/// 设计要点（v3.2 §4 / 产品方案 §4.5）：
/// - **创建时即调度**：事件由 [CalendarRepository] 写入时调用 [scheduleFor]，
///   OS 自己持有 alarm queue；触发时 App 在与否无关
/// - **微信式样式**：title=角色名（含 emoji icon），body=事件标题 + 时间提示
///   group key=roleId，让同角色多条提醒堆叠
/// - **隐私可控**：[setShowDetailsOnLockScreen] 在 OFF 时把 visibility 切到
///   private（锁屏只露"pikppo · 1 条提醒"）
/// - **零知识相容**：全部走端上 OS API，服务端永不参与"该不该提醒、提醒给谁"
class NotificationService {
  static const _kChannelId = 'reminders';
  static const _kChannelName = '日程提醒';
  static const _kChannelDesc = '日历事件到点的角色提醒';

  /// 通知 payload JSON 键。
  static const payloadEventId = 'event_id';
  static const payloadRoleId = 'role_id';

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  /// 上次 [setShowDetailsOnLockScreen] 写入的状态；默认 true（产品方案 §3.5）。
  bool _showDetailsOnLockScreen = true;

  /// tap 通知后端上收到的 payload；由 MainShell 等订阅者读取处理 deep link。
  /// 设计为单值最近一次 + 由消费方读后清；多条 tap 之间用户已经在不同界面跳
  /// 转，没必要保留历史。
  ({String eventId, String roleId})? _pendingDeepLink;
  ({String eventId, String roleId})? takePendingDeepLink() {
    final v = _pendingDeepLink;
    _pendingDeepLink = null;
    return v;
  }

  bool _initialized = false;

  /// 启动时调一次。安全可重入。
  Future<void> init({
    required void Function(String eventId, String roleId) onTap,
  }) async {
    if (_initialized) return;
    _initialized = true;

    // tzdata 是 ~900KB，但 zonedSchedule 必需；首启时一次性加载。
    tzdata.initializeTimeZones();
    try {
      final localTz = await FlutterTimezone.getLocalTimezone();
      tz.setLocalLocation(tz.getLocation(localTz));
    } catch (e) {
      debugPrint('local timezone unknown, fallback to UTC: $e');
      tz.setLocalLocation(tz.UTC);
    }

    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    const iosInit = DarwinInitializationSettings(
      requestAlertPermission: false, // 由 [requestPermissions] 显式请求，便于引导
      requestBadgePermission: false,
      requestSoundPermission: false,
    );

    await _plugin.initialize(
      const InitializationSettings(android: androidInit, iOS: iosInit),
      onDidReceiveNotificationResponse: (resp) {
        final payload = resp.payload;
        if (payload == null || payload.isEmpty) return;
        try {
          final m = jsonDecode(payload) as Map<String, dynamic>;
          final eventId = m[payloadEventId] as String?;
          final roleId = m[payloadRoleId] as String?;
          if (eventId != null && roleId != null) {
            _pendingDeepLink = (eventId: eventId, roleId: roleId);
            onTap(eventId, roleId);
          }
        } catch (e) {
          debugPrint('notification payload decode failed: $e');
        }
      },
    );

    // Android channel——必须在调度之前创建。重要级别 high 让锁屏 heads-up
    // 横幅样式触发（与微信一致）。
    final androidImpl = _plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();
    await androidImpl?.createNotificationChannel(
      const AndroidNotificationChannel(
        _kChannelId,
        _kChannelName,
        description: _kChannelDesc,
        importance: Importance.high,
      ),
    );

    // 检查冷启动 tap：用户点通知拉起 App 时取出 payload。
    final launchDetails = await _plugin.getNotificationAppLaunchDetails();
    if (launchDetails?.didNotificationLaunchApp == true) {
      final payload = launchDetails?.notificationResponse?.payload;
      if (payload != null && payload.isNotEmpty) {
        try {
          final m = jsonDecode(payload) as Map<String, dynamic>;
          final eventId = m[payloadEventId] as String?;
          final roleId = m[payloadRoleId] as String?;
          if (eventId != null && roleId != null) {
            _pendingDeepLink = (eventId: eventId, roleId: roleId);
          }
        } catch (_) {/* ignore */}
      }
    }
  }

  /// Android 13+ POST_NOTIFICATIONS / iOS APNS alert permission。设置页"启
  /// 用提醒"开关 + 首次创建事件时一次性请求。
  Future<bool> requestPermissions() async {
    final android = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    final androidOk = await android?.requestNotificationsPermission() ?? true;

    final ios = _plugin.resolvePlatformSpecificImplementation<
        IOSFlutterLocalNotificationsPlugin>();
    final iosOk = await ios?.requestPermissions(
          alert: true,
          badge: true,
          sound: true,
        ) ??
        true;
    return androidOk && iosOk;
  }

  /// 锁屏显示详情的隐私开关——OFF 时通知内容退化为 "pikppo · 1 条提醒"，详情
  /// 进 App 才看。下次调度生效（已注册的通知不会回头改）。
  void setShowDetailsOnLockScreen(bool show) {
    _showDetailsOnLockScreen = show;
  }

  bool get showDetailsOnLockScreen => _showDetailsOnLockScreen;

  // ---------- 调度 ----------

  /// 预调度提醒。事件无 [CalendarEvent.reminderMinutes] 时不调度；时间已过
  /// 也不调度。同 id 重复调度自动覆盖（plugin 行为）。
  ///
  /// 通知 id 用稳定 hash(event.id) 让同事件 schedule / cancel 一一对应。
  Future<void> scheduleFor(CalendarEvent event, Role role) async {
    final reminder = event.reminderMinutes;
    if (reminder == null) return;
    if (event.allDay) return; // 全天事件暂不通知（产品决定）

    final fireAt = event.startTime.subtract(Duration(minutes: reminder));
    if (fireAt.isBefore(DateTime.now())) return;

    final tzFireAt = tz.TZDateTime.from(fireAt, tz.local);
    final notifId = _stableNotificationId(event.id);

    final timeLabel = event.localTimeLabel ?? '';
    final timeHint = reminder >= 60
        ? '${reminder ~/ 60} 小时后'
        : '$reminder 分钟后';
    final body = '$timeLabel${event.title}（$timeHint）'.trim();
    final title = '${role.icon} ${role.name}';

    final androidDetails = AndroidNotificationDetails(
      _kChannelId,
      _kChannelName,
      channelDescription: _kChannelDesc,
      importance: Importance.high,
      priority: Priority.high,
      groupKey: 'role:${role.id}', // 同角色多条提醒堆叠
      visibility: _showDetailsOnLockScreen
          ? NotificationVisibility.public
          : NotificationVisibility.private,
      // 隐私模式下的锁屏替代文案——仅在 visibility=private 生效。
      ticker: '$title · 1 条提醒',
    );
    final iosDetails = DarwinNotificationDetails(
      threadIdentifier: 'role:${role.id}',
      // iOS 锁屏文案模式：showsLockScreenSummary=false 时锁屏不展开（不同 OS
      // 版本细节略异，整体退化到"1 条新提醒"风格）。
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
    );
    final details = NotificationDetails(
      android: androidDetails,
      iOS: iosDetails,
    );

    final payload = jsonEncode({
      payloadEventId: event.id,
      payloadRoleId: role.id,
    });

    await _plugin.zonedSchedule(
      notifId,
      title,
      body,
      tzFireAt,
      details,
      androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
      // iOS 旧版兼容：把 tzFireAt 解释为"绝对时刻"（而非"挂钟时刻"），保证
      // 设备切时区时仍按原 UTC 触发。
      uiLocalNotificationDateInterpretation:
          UILocalNotificationDateInterpretation.absoluteTime,
      payload: payload,
    );
  }

  /// 取消已调度。事件删除、reschedule 前调用。
  Future<void> cancelFor(String eventId) async {
    await _plugin.cancel(_stableNotificationId(eventId));
  }

  /// 立即弹一条——前台触发时由 dispatcher 调用，作为 OS 漏触发的兜底（罕见但
  /// 厂商省电极端时可能发生）。
  Future<void> showImmediate(CalendarEvent event, Role role) async {
    final reminder = event.reminderMinutes ?? 0;
    final timeLabel = event.localTimeLabel ?? '';
    final timeHint = reminder >= 60
        ? '${reminder ~/ 60} 小时后'
        : reminder > 0
            ? '$reminder 分钟后'
            : '即将开始';
    final body = '$timeLabel${event.title}（$timeHint）'.trim();
    final title = '${role.icon} ${role.name}';

    final details = NotificationDetails(
      android: AndroidNotificationDetails(
        _kChannelId,
        _kChannelName,
        channelDescription: _kChannelDesc,
        importance: Importance.high,
        priority: Priority.high,
        groupKey: 'role:${role.id}',
        visibility: _showDetailsOnLockScreen
            ? NotificationVisibility.public
            : NotificationVisibility.private,
        ticker: '$title · 1 条提醒',
      ),
      iOS: DarwinNotificationDetails(
        threadIdentifier: 'role:${role.id}',
        presentAlert: true,
        presentBadge: true,
        presentSound: true,
      ),
    );
    final payload = jsonEncode({
      payloadEventId: event.id,
      payloadRoleId: role.id,
    });
    await _plugin.show(
      _stableNotificationId(event.id),
      title,
      body,
      details,
      payload: payload,
    );
  }

  /// 全量取消并重建——账号切换、Settings 隐私开关切换、角色变更后调。
  Future<void> cancelAll() => _plugin.cancelAll();

  /// 把 UUID 字符串折成 31-bit int（Android 通知 id 上限 INT32）。同 id 折出
  /// 同 hash，schedule / cancel 一一对应；碰撞率忽略（用户日程量级）。
  static int _stableNotificationId(String eventId) {
    var hash = 0;
    for (final code in eventId.codeUnits) {
      hash = (hash * 31 + code) & 0x7fffffff;
    }
    return hash;
  }
}
