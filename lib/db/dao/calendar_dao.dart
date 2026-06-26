import 'package:drift/drift.dart';
import '../../models/calendar_event.dart';
import '../database.dart';

part 'calendar_dao.g.dart';

/// 日历表的低阶访问。
///
/// **不在 barrel 中导出**，仅 [CalendarRepository] 直接持有。任何其它代码绕过
/// Repository 直接调本 DAO 的写方法都视为缺陷——副作用编排（reminder 调度、
/// `dirty` 盖戳、同步钩子）会全部丢失。
///
/// 设计纪律：
/// - 读方法统一过滤 `deleted = false`，避免调用方漏写条件读到墓碑。
/// - 写方法只做最薄的行级 upsert / 软删——业务规则（盖戳、单调钟、事务编排）
///   都在 Repository 层。
@DriftAccessor(tables: [CalendarEventRows])
class CalendarDao extends DatabaseAccessor<PikppoDatabase>
    with _$CalendarDaoMixin {
  CalendarDao(super.db);

  // ---- 读 ----

  Future<CalendarEvent?> getById(String id) async {
    final row = await (select(calendarEventRows)
          ..where((t) => t.id.equals(id) & t.deleted.equals(false))
          ..limit(1))
        .getSingleOrNull();
    return row == null ? null : _fromRow(row);
  }

  /// 闭区间 [startUtc, endUtc]：把 startTime 落在窗口内的所有非墓碑事件返回。
  /// UTC 入参——调用方负责把本地日期/时间转换成 UTC 区间。
  Future<List<CalendarEvent>> listRange(
      DateTime startUtc, DateTime endUtc) async {
    final rows = await (select(calendarEventRows)
          ..where((t) =>
              t.deleted.equals(false) &
              t.startTime.isBiggerOrEqualValue(startUtc) &
              t.startTime.isSmallerOrEqualValue(endUtc))
          ..orderBy([(t) => OrderingTerm.asc(t.startTime)]))
        .get();
    return rows.map(_fromRow).toList();
  }

  Stream<List<CalendarEvent>> watchRange(
      DateTime startUtc, DateTime endUtc) {
    return (select(calendarEventRows)
          ..where((t) =>
              t.deleted.equals(false) &
              t.startTime.isBiggerOrEqualValue(startUtc) &
              t.startTime.isSmallerOrEqualValue(endUtc))
          ..orderBy([(t) => OrderingTerm.asc(t.startTime)]))
        .watch()
        .map((rows) => rows.map(_fromRow).toList());
  }

  // ---- 写（仅供 CalendarRepository 调用） ----

  Future<void> upsert(CalendarEvent event) =>
      into(calendarEventRows).insertOnConflictUpdate(_toCompanion(event));

  /// 软删——保留行作为墓碑，刷新 `updatedAt` 让 LWW 能识别；置 `dirty=true`
  /// 让 Phase 2 同步引擎把删除事实推到服务端。
  Future<void> markDeleted(String id, {required DateTime updatedAt}) async {
    await (update(calendarEventRows)..where((t) => t.id.equals(id))).write(
      CalendarEventRowsCompanion(
        deleted: const Value(true),
        dirty: const Value(true),
        updatedAt: Value(updatedAt),
      ),
    );
  }

  // ---- Mappers ----

  static CalendarEvent _fromRow(CalendarEventRow r) => CalendarEvent(
        id: r.id,
        title: r.title,
        description: r.description,
        startTime: r.startTime,
        endTime: r.endTime,
        allDay: r.allDay,
        recurrenceRule: r.recurrenceRule,
        reminderMinutes: r.reminderMinutes,
        routedRoleId: r.routedRoleId,
        updatedAt: r.updatedAt,
        deleted: r.deleted,
        dirty: r.dirty,
        serverVersion: r.serverVersion,
      );

  static CalendarEventRowsCompanion _toCompanion(CalendarEvent e) =>
      CalendarEventRowsCompanion(
        id: Value(e.id),
        title: Value(e.title),
        description: Value(e.description),
        startTime: Value(e.startTime),
        endTime: Value(e.endTime),
        allDay: Value(e.allDay),
        recurrenceRule: Value(e.recurrenceRule),
        reminderMinutes: Value(e.reminderMinutes),
        routedRoleId: Value(e.routedRoleId),
        updatedAt: Value(e.updatedAt),
        deleted: Value(e.deleted),
        dirty: Value(e.dirty),
        serverVersion: Value(e.serverVersion),
      );
}
