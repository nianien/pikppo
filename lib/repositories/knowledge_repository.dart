import '../db/dao/knowledge_dao.dart';
import '../db/dao/tags_dao.dart';
import '../db/database.dart';
import '../models/knowledge_card.dart';

/// 知识卡片的唯一写入口——所有增/改/软删都从这里走（同 calendar/memory 纪律）。
/// 每次写盖戳 `updatedAt`（UTC 单调护栏），为 P2 加密备份的 LWW 合并留位。
///
/// 标签经 [TagsDao] 的 `tags` 实体表 + `card_tags` 关联表维护：写卡片时按新旧
/// 标签差量建立/解除关联，孤儿标签自动删；[candidateTags] 用弱一致的 usageCount
/// 做"软约束收敛"（把已有标签喂回 LLM 让它优先复用）。
class KnowledgeRepository {
  final KnowledgeDao _dao;
  final TagsDao _tags;

  DateTime _lastStamp = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);

  /// 候选标签封顶——总量超过它才按"字面命中 + 频次"筛，否则全送。
  static const _candidateCap = 25;

  KnowledgeRepository(PikppoDatabase db)
      : _dao = KnowledgeDao(db),
        _tags = TagsDao(db);

  // ---------- 写 ----------

  Future<KnowledgeCard> add(KnowledgeCard card) async {
    await _dao.upsertCard(card, _monotonicStamp());
    for (final name in card.tags) {
      final id = await _tags.findOrCreate(name, _monotonicStamp());
      await _tags.associate(card.id, id, _monotonicStamp());
    }
    return card;
  }

  /// 改写卡片内容 / 标签——upsert 卡片本体，再按新旧标签名差量对账关联。
  Future<KnowledgeCard> update(KnowledgeCard card) async {
    final old = await _tags.tagsForCard(card.id);
    final oldNames = {for (final t in old) t.name};
    final newNames = card.tags.toSet();

    await _dao.upsertCard(card, _monotonicStamp());

    for (final name in newNames.difference(oldNames)) {
      final id = await _tags.findOrCreate(name, _monotonicStamp());
      await _tags.associate(card.id, id, _monotonicStamp());
    }
    for (final t in old.where((t) => !newNames.contains(t.name))) {
      await _tags.dissociate(card.id, t.id, _monotonicStamp());
    }
    return card;
  }

  /// 只改重要程度（收藏切换）——不动标签关联。
  Future<void> setImportance(String id, int importance) async {
    await _dao.setImportance(id, importance, _monotonicStamp());
  }

  Future<void> delete(String id) async {
    await _dao.markDeleted(id, updatedAtUtc: _monotonicStamp());
    await _tags.dissociateAll(id, _monotonicStamp());
  }

  // ---------- 读 ----------

  Stream<List<KnowledgeCard>> watchAll() => _dao.watchAlive();
  Future<KnowledgeCard?> getById(String id) => _dao.getById(id);

  /// 候选标签（软约束收敛用）——拼进释义/翻译 prompt 让 LLM 优先复用。
  /// 词表 ≤ [_candidateCap] 时全量返回；超了则：当前文本里**整词命中**的标签
  /// 优先，再用频次 top-N 补足，封顶 [_candidateCap]。剔除已归零的标签。
  Future<List<String>> candidateTags(String text) async {
    final pool = (await _tags.all())
        .where((r) => r.usageCount > 0)
        .toList(); // 已按 usageCount 降序

    if (pool.length <= _candidateCap) {
      return pool.map((r) => r.name).toList();
    }

    final hits = <String>[];
    final rest = <String>[];
    for (final r in pool) {
      (text.contains(r.name) ? hits : rest).add(r.name);
    }
    final out = <String>[...hits];
    for (final name in rest) {
      if (out.length >= _candidateCap) break;
      out.add(name);
    }
    return out.take(_candidateCap).toList();
  }

  // ---------- 私有 ----------

  DateTime _monotonicStamp() {
    final now = DateTime.now().toUtc();
    _lastStamp = now.isAfter(_lastStamp)
        ? now
        : _lastStamp.add(const Duration(milliseconds: 1));
    return _lastStamp;
  }
}
