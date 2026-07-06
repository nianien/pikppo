import 'package:drift/drift.dart';
import '../../models/knowledge_card.dart';
import '../database.dart';

part 'knowledge_dao.g.dart';

/// 知识卡片表的低阶访问。**不在 barrel 导出**，仅 [KnowledgeRepository] 持有
/// （同 calendar/memory 纪律）——盖戳、软删墓碑、单调钟在 Repository 层。
/// 读层统一过滤 `deleted = false`，并 join `card_tags`/`tags` 填充每张卡的标签名。
@DriftAccessor(tables: [KnowledgeCardRows, CardTagRows, TagRows])
class KnowledgeDao extends DatabaseAccessor<PikppoDatabase>
    with _$KnowledgeDaoMixin {
  KnowledgeDao(super.db);

  // ---- 读（含标签 join） ----

  /// 存活卡片实时流——join 关联表填充标签名。任一相关表变更都会重发。新→旧。
  Stream<List<KnowledgeCard>> watchAlive() {
    final query = (select(knowledgeCardRows)
          ..where((t) => t.deleted.equals(false))
          ..orderBy([(t) => OrderingTerm.desc(t.createdAt)]))
        .join([
      leftOuterJoin(
          cardTagRows, cardTagRows.cardId.equalsExp(knowledgeCardRows.id)),
      leftOuterJoin(tagRows, tagRows.id.equalsExp(cardTagRows.tagId)),
    ]);
    return query.watch().map(_groupRows);
  }

  Future<KnowledgeCard?> getById(String id) async {
    final query = (select(knowledgeCardRows)
          ..where((t) => t.id.equals(id) & t.deleted.equals(false)))
        .join([
      leftOuterJoin(
          cardTagRows, cardTagRows.cardId.equalsExp(knowledgeCardRows.id)),
      leftOuterJoin(tagRows, tagRows.id.equalsExp(cardTagRows.tagId)),
    ]);
    final grouped = _groupRows(await query.get());
    return grouped.isEmpty ? null : grouped.first;
  }

  /// 把 join 结果按卡片分组、聚合标签名，保持 createdAt desc 的出现顺序。
  List<KnowledgeCard> _groupRows(List<TypedResult> rows) {
    final cardRows = <String, KnowledgeCardRow>{};
    final tagsByCard = <String, List<String>>{};
    final order = <String>[];
    for (final row in rows) {
      final c = row.readTable(knowledgeCardRows);
      if (!cardRows.containsKey(c.id)) {
        cardRows[c.id] = c;
        tagsByCard[c.id] = [];
        order.add(c.id);
      }
      final tag = row.readTableOrNull(tagRows);
      if (tag != null) tagsByCard[c.id]!.add(tag.name);
    }
    return [
      for (final id in order) _fromRow(cardRows[id]!, tagsByCard[id]!),
    ];
  }

  // ---- 写（仅供 KnowledgeRepository 调用） ----

  /// 写卡片本体（不含标签关联，关联由 Repository 经 TagsDao 维护）。
  Future<void> upsertCard(KnowledgeCard card, DateTime updatedAtUtc) =>
      into(knowledgeCardRows)
          .insertOnConflictUpdate(_toCompanion(card, updatedAtUtc));

  /// 只改重要程度（收藏）——避免收藏一下就走整套标签对账。
  Future<void> setImportance(
      String id, int importance, DateTime updatedAtUtc) async {
    await (update(knowledgeCardRows)..where((t) => t.id.equals(id))).write(
      KnowledgeCardRowsCompanion(
        importance: Value(importance),
        updatedAt: Value(updatedAtUtc),
      ),
    );
  }

  /// 软删——保留墓碑，刷新 updatedAt 让 LWW 识别删除事实。
  Future<void> markDeleted(String id, {required DateTime updatedAtUtc}) async {
    await (update(knowledgeCardRows)..where((t) => t.id.equals(id))).write(
      KnowledgeCardRowsCompanion(
        deleted: const Value(true),
        updatedAt: Value(updatedAtUtc),
      ),
    );
  }

  // ---- Mappers ----

  static KnowledgeCard _fromRow(KnowledgeCardRow r, List<String> tags) =>
      KnowledgeCard(
        id: r.id,
        term: r.term,
        content: r.content,
        source: r.source,
        importance: r.importance,
        tags: tags,
        createdAt: r.createdAt,
      );

  static KnowledgeCardRowsCompanion _toCompanion(
          KnowledgeCard c, DateTime updatedAtUtc) =>
      KnowledgeCardRowsCompanion(
        id: Value(c.id),
        term: Value(c.term),
        content: Value(c.content),
        source: Value(c.source),
        importance: Value(c.importance),
        createdAt: Value(c.createdAt),
        updatedAt: Value(updatedAtUtc),
        deleted: const Value(false),
      );
}
