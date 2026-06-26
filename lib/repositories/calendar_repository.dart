import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
import '../db/dao/calendar_dao.dart';
import '../db/database.dart';
import '../models/calendar_event.dart';
import '../providers/reminder_scheduler.dart';

const _uuid = Uuid();

/// 写副作用回调：事件最终态（已盖戳、已落库）传入，由调用方决定如何路由 +
/// 调度系统通知。Repository 不直接持 Router / NotificationService，避免与
/// AppStateNotifier（角色清单的拥有者）形成环。注入点见 main wiring。
typedef CalendarWriteHook = Future<void> Function(CalendarEvent event);

/// 删除副作用回调：仅需要 event id（删除已经发生，原行墓碑化）。
typedef CalendarDeleteHook = Future<void> Function(String eventId);

/// 日历事件的唯一写入口——所有增 / 改 / 软删都从这里走。
///
/// 为什么需要这一层（架构 §1 第三条原则）：
/// - **盖戳**：每次写统一刷新 `updatedAt` + 置 `dirty=true`，让 Phase 2 同步引
///   擎能识别"待推送"。任何绕过 Repository 直接写 DAO 的代码都会破坏 LWW。
/// - **副作用编排**：reminder 调度 + 同步钩子在写完后一并触发，UI 和 LLM 工具
///   走的是同一条路径，行为完全一致。
/// - **写后读 / 读改写**：update 必须在事务里 read-modify-write，避免 UI 操作
///   和 LLM 工具调用并发交错时丢失中间变更。
class CalendarRepository {
  final PikppoDatabase _db;
  final CalendarDao _dao;
  final ReminderScheduler _reminderScheduler;

  /// 写后副作用钩子——典型实现：ReminderRouter 路由 + 写回 routedRoleId +
  /// NotificationService.scheduleFor。Phase 1 启动时由 AppStateNotifier 注入。
  /// null 时（启动早期或测试）走 fall-through，仅 ReminderScheduler.forget。
  CalendarWriteHook? _onWrite;
  CalendarDeleteHook? _onDelete;

  CalendarRepository(this._db, this._reminderScheduler)
      : _dao = CalendarDao(_db);

  /// 注入写副作用——main wiring 在 Repository 构造完后调用一次。可重入（账号
  /// 切换时重新注入新一组角色/路由）。
  void bindHooks({
    required CalendarWriteHook onWrite,
    required CalendarDeleteHook onDelete,
  }) {
    _onWrite = onWrite;
    _onDelete = onDelete;
  }

  // ---------- 写 ----------

  Future<CalendarEvent> create(CalendarEventDraft draft) async {
    final event = draft.toEvent(
      id: _uuid.v4(),
      updatedAt: DateTime.now().toUtc(),
    );
    await _dao.upsert(event);
    await _afterWrite(event);
    return event;
  }

  Future<CalendarEvent> update(String id, CalendarEventPatch patch) async {
    return _db.transaction(() async {
      final current = await _dao.getById(id);
      if (current == null) {
        throw CalendarEventNotFound(id);
      }
      final next = patch.applyTo(current).copyWith(
            updatedAt: _monotonicStamp(current.updatedAt),
            dirty: true,
          );
      await _dao.upsert(next);
      await _afterWrite(next);
      return next;
    });
  }

  /// 写回路由结果——由写后钩子在路由完成后调用，不重复触发副作用。
  /// 单独抽出是因为 _onWrite 在 _afterWrite 里被调用时事件还没写回 routedRoleId；
  /// 钩子拿到事件 + 路由出 roleId 后调本方法做 cache。
  Future<void> setRoutedRoleId(String eventId, String? roleId) async {
    final current = await _dao.getById(eventId);
    if (current == null) return;
    if (current.routedRoleId == roleId) return; // no-op
    final next = current.copyWith(
      routedRoleId: roleId,
      clearRoutedRoleId: roleId == null,
      updatedAt: _monotonicStamp(current.updatedAt),
      dirty: true,
    );
    await _dao.upsert(next);
    // 这条变更也是核心资产的一次修改：dirty=true 让 P2 备份能感知；不再触发
    // _onWrite（已经在路由流程内部，再调会无限递归）。
  }

  /// 软删——墓碑也要盖戳，LWW 依赖它判断"删除事实"比"修改事实"新。
  /// 幂等：id 不存在直接返回，不报错。
  Future<void> delete(String id) async {
    final current = await _dao.getById(id);
    if (current == null) return;
    await _dao.markDeleted(
      id,
      updatedAt: _monotonicStamp(current.updatedAt),
    );
    _reminderScheduler.forget(id);
    final hook = _onDelete;
    if (hook != null) {
      try {
        await hook(id);
      } catch (e) {
        debugPrint('calendar delete hook failed: $e');
      }
    }
    _syncHook();
  }

  // ---------- 读（DAO 已滤墓碑） ----------

  Future<CalendarEvent?> getById(String id) => _dao.getById(id);

  Future<List<CalendarEvent>> listRange(
          DateTime startUtc, DateTime endUtc) =>
      _dao.listRange(startUtc, endUtc);

  Stream<List<CalendarEvent>> watchRange(
          DateTime startUtc, DateTime endUtc) =>
      _dao.watchRange(startUtc, endUtc);

  /// UI 常用窗口：从今天本地零点开始的 [windowDays] 天内事件。reminder 调度也
  /// 用这个窗口——超过 30 天的日程不进入即将提醒范围。
  Stream<List<CalendarEvent>> watchUpcoming({int windowDays = 30}) {
    final now = DateTime.now();
    final startLocal = DateTime(now.year, now.month, now.day);
    final endLocal = startLocal.add(Duration(days: windowDays));
    return watchRange(startLocal.toUtc(), endLocal.toUtc());
  }

  // ---------- 私有 ----------

  /// 客户端单调钟：设备时钟可能因 NTP 校正、跨时区飞行、用户手动改表而回拨；
  /// 同一行的连续编辑若 updated_at 倒退，会在 LWW 里被自己的旧版本击败。
  /// 保证 next > previous，最小 1ms 增量。
  DateTime _monotonicStamp(DateTime previous) {
    final now = DateTime.now().toUtc();
    if (now.isAfter(previous)) return now;
    return previous.add(const Duration(milliseconds: 1));
  }

  Future<void> _afterWrite(CalendarEvent event) async {
    _reminderScheduler.forget(event.id); // 时间/提醒可能变了，让事件重新进入窗口
    final hook = _onWrite;
    if (hook != null) {
      try {
        await hook(event);
      } catch (e) {
        debugPrint('calendar write hook failed: $e');
      }
    }
    _syncHook();
  }

  /// Phase 1 空实现。Phase 2 接到 SyncEngine.requestSync()——写后防抖 2-3 秒触发
  /// 一轮 push/pull。
  void _syncHook() {
    // 故意为空——见类注释。
    assert(() {
      debugPrint('calendar sync hook (no-op in Phase 1)');
      return true;
    }());
  }
}

class CalendarEventNotFound implements Exception {
  final String id;
  const CalendarEventNotFound(this.id);
  @override
  String toString() => 'calendar event not found: $id';
}
