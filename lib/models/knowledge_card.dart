/// LLM 释义/翻译/优化的结构化返回：正文 + 推荐标签。
class LlmCardResult {
  final String text;
  final List<String> tags;
  const LlmCardResult(this.text, this.tags);
}

/// 知识卡片——用户从对话里收藏下来的释义/译文。`term` 词条/原文，`content`
/// 释义/译文，`source` 来源分类（[sourceExplain] / [sourceTranslate]，**存而不显**，
/// 留作未来按来源过滤/统计），`tags` 话题标签（经 `card_tags` 关联，加载时填充）。
/// `importance` 重要程度：0=普通，>0=收藏（v1 仅 0/1，预留升级到 1/2/3）。
class KnowledgeCard {
  final String id;
  final String term;
  final String content;

  /// 来源分类（释义 / 翻译）——表示卡片怎么来的，存储但 UI 不展示（B 方案）。
  final String source;

  /// 重要程度。0 普通，>0 收藏。列存成 int 以便将来扩成分级而不迁移。
  final int importance;

  /// 话题标签名列表——真相在 `card_tags` 关联表，此处是加载时 join 填充的视图。
  final List<String> tags;
  final int createdAt;

  const KnowledgeCard({
    required this.id,
    required this.term,
    required this.content,
    this.source = '',
    this.importance = 0,
    this.tags = const [],
    required this.createdAt,
  });

  /// 来源取值——保存时由释义/翻译弹窗写入。
  static const sourceExplain = '释义';
  static const sourceTranslate = '翻译';

  bool get isFavorite => importance > 0;

  KnowledgeCard copyWith({
    String? term,
    String? content,
    String? source,
    int? importance,
    List<String>? tags,
  }) =>
      KnowledgeCard(
        id: id,
        term: term ?? this.term,
        content: content ?? this.content,
        source: source ?? this.source,
        importance: importance ?? this.importance,
        tags: tags ?? this.tags,
        createdAt: createdAt,
      );
}
