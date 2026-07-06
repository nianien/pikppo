import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';
import '../database.dart';

part 'tags_dao.g.dart';

/// 标签实体 + 卡片↔标签关联的低阶访问。**不在 barrel 导出**，仅
/// [KnowledgeRepository] 持有。维护 [TagRow.usageCount] 去规范化缓存（弱一致），
/// 并按 [CardTagRows] 实表判定孤儿标签后删除。
@DriftAccessor(tables: [TagRows, CardTagRows])
class TagsDao extends DatabaseAccessor<PikppoDatabase> with _$TagsDaoMixin {
  TagsDao(super.db);

  static const _uuid = Uuid();

  // ---- 候选（软约束收敛） ----

  /// 全部标签，按 usageCount 降序——候选筛选时本地再做字面命中加权。
  Future<List<TagRow>> all() {
    return (select(tagRows)..orderBy([(t) => OrderingTerm.desc(t.usageCount)]))
        .get();
  }

  // ---- 某卡的标签 ----

  /// 某卡已关联的标签实体（含 id+name），供 Repository 做新旧差量对账。
  Future<List<TagRow>> tagsForCard(String cardId) {
    final q = select(cardTagRows).join([
      innerJoin(tagRows, tagRows.id.equalsExp(cardTagRows.tagId)),
    ])
      ..where(cardTagRows.cardId.equals(cardId));
    return q.map((row) => row.readTable(tagRows)).get();
  }

  // ---- 写（仅供 KnowledgeRepository 调用） ----

  /// 按 name 查标签实体，没有就新建（uuid）。返回 tagId。
  Future<String> findOrCreate(String name, DateTime stampUtc) async {
    final existing =
        await (select(tagRows)..where((t) => t.name.equals(name))).getSingleOrNull();
    if (existing != null) return existing.id;
    final id = _uuid.v4();
    await into(tagRows).insert(TagRowsCompanion(
      id: Value(id),
      name: Value(name),
      usageCount: const Value(0),
      updatedAt: Value(stampUtc),
    ));
    return id;
  }

  /// 建立卡片↔标签关联并把引用计数 +1。
  Future<void> associate(String cardId, String tagId, DateTime stampUtc) async {
    await into(cardTagRows).insertOnConflictUpdate(
      CardTagRowsCompanion(cardId: Value(cardId), tagId: Value(tagId)),
    );
    await _bump(tagId, 1, stampUtc);
  }

  /// 解除关联、计数 -1，并按实表判定孤儿后删除标签实体。
  Future<void> dissociate(
      String cardId, String tagId, DateTime stampUtc) async {
    await (delete(cardTagRows)
          ..where((t) => t.cardId.equals(cardId) & t.tagId.equals(tagId)))
        .go();
    await _bump(tagId, -1, stampUtc);
    await _pruneIfOrphan(tagId);
  }

  /// 删卡时解除其全部关联（计数 -1 + 孤儿清理）。
  Future<void> dissociateAll(String cardId, DateTime stampUtc) async {
    final rows = await (select(cardTagRows)
          ..where((t) => t.cardId.equals(cardId)))
        .get();
    for (final r in rows) {
      await dissociate(cardId, r.tagId, stampUtc);
    }
  }

  // ---- 私有 ----

  Future<void> _bump(String tagId, int delta, DateTime stampUtc) async {
    final existing =
        await (select(tagRows)..where((t) => t.id.equals(tagId))).getSingleOrNull();
    if (existing == null) return;
    final next = (existing.usageCount + delta).clamp(0, 1 << 31);
    await (update(tagRows)..where((t) => t.id.equals(tagId))).write(
      TagRowsCompanion(usageCount: Value(next), updatedAt: Value(stampUtc)),
    );
  }

  /// 孤儿判定看 [CardTagRows] 实表（精确），不看 usageCount 缓存——所以缓存就算
  /// 漂移也绝不会误删仍被引用的标签。
  Future<void> _pruneIfOrphan(String tagId) async {
    final ref = await (select(cardTagRows)
          ..where((t) => t.tagId.equals(tagId))
          ..limit(1))
        .getSingleOrNull();
    if (ref == null) {
      await (delete(tagRows)..where((t) => t.id.equals(tagId))).go();
    }
  }
}
