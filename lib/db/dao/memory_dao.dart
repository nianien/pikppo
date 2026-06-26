import 'dart:convert';
import 'package:drift/drift.dart';
import '../../models/memory.dart';
import '../database.dart';

part 'memory_dao.g.dart';

/// 记忆表的低阶访问。
///
/// **不在 barrel 中导出**，仅 [MemoryRepository] 直接持有——同 calendar_dao 的
/// 纪律。任何其它代码绕过 Repository 直接写本 DAO 都视为缺陷：盖戳（updatedAt）、
/// 软删墓碑、单调钟、批量事务编排全在 Repository 层。
///
/// 读层：统一过滤 `deleted = false`，避免调用方漏写条件读到墓碑。
@DriftAccessor(tables: [MemoryRows])
class MemoryDao extends DatabaseAccessor<PikppoDatabase>
    with _$MemoryDaoMixin {
  MemoryDao(super.db);

  // ---- 读 ----

  Future<List<Memory>> allAlive() async {
    final rows = await (select(memoryRows)
          ..where((t) => t.deleted.equals(false))
          ..orderBy([(t) => OrderingTerm.desc(t.timestamp)]))
        .get();
    return rows.map(_fromRow).toList();
  }

  Future<Memory?> getById(String id) async {
    final row = await (select(memoryRows)
          ..where((t) => t.id.equals(id) & t.deleted.equals(false))
          ..limit(1))
        .getSingleOrNull();
    return row == null ? null : _fromRow(row);
  }

  // ---- 写（仅供 MemoryRepository 调用） ----

  Future<void> upsert(Memory memory, DateTime updatedAtUtc) =>
      into(memoryRows).insertOnConflictUpdate(_toCompanion(memory, updatedAtUtc));

  /// 批量 upsert——MemorySummarizer 归纳完一轮，updated + added 一次事务下，
  /// 减少 IO 风暴。
  Future<void> upsertBatch(List<Memory> memories, DateTime updatedAtUtc) async {
    if (memories.isEmpty) return;
    await batch((b) {
      for (final m in memories) {
        b.insert(
          memoryRows,
          _toCompanion(m, updatedAtUtc),
          mode: InsertMode.insertOrReplace,
        );
      }
    });
  }

  /// 软删——保留行作为墓碑，刷新 updatedAt 让 LWW 识别删除事实。
  Future<void> markDeleted(String id, {required DateTime updatedAtUtc}) async {
    await (update(memoryRows)..where((t) => t.id.equals(id))).write(
      MemoryRowsCompanion(
        deleted: const Value(true),
        updatedAt: Value(updatedAtUtc),
      ),
    );
  }

  /// 全删：墓碑化所有现存记忆。设置页"清除全部记忆"调；与物理删的差别是
  /// 让备份/恢复链路能感知"曾经存在已删除"的事实。
  Future<int> markAllDeleted({required DateTime updatedAtUtc}) async {
    return (update(memoryRows)..where((t) => t.deleted.equals(false))).write(
      MemoryRowsCompanion(
        deleted: const Value(true),
        updatedAt: Value(updatedAtUtc),
      ),
    );
  }

  // ---- Mappers ----

  static Memory _fromRow(MemoryRow r) {
    final tags = (jsonDecode(r.tagsJson) as List).cast<String>();
    return Memory(
      id: r.id,
      type: r.type,
      content: r.content,
      roleId: r.roleId,
      timestamp: r.timestamp,
      tags: tags,
    );
  }

  static MemoryRowsCompanion _toCompanion(Memory m, DateTime updatedAtUtc) =>
      MemoryRowsCompanion(
        id: Value(m.id),
        type: Value(m.type),
        content: Value(m.content),
        roleId: Value(m.roleId),
        timestamp: Value(m.timestamp),
        tagsJson: Value(jsonEncode(m.tags)),
        updatedAt: Value(updatedAtUtc),
        deleted: const Value(false),
      );
}
