import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/knowledge_card.dart';
import '../providers/app_state_provider.dart';
import '../providers/knowledge_repository_provider.dart';
import '../theme/design_tokens.dart';
import '../utils/user_facing_error.dart';
import '../widgets/app_toast.dart';
import '../widgets/message_actions.dart' show shareText;

/// 知识卡片页（v1，纯本地）——浏览 / 删除 / 按标签过滤 / 收藏 / 一键优化。
/// 卡片由对话里的「释义」「翻译」弹窗保存而来，不参与 LLM 上下文。
class KnowledgeCardsScreen extends ConsumerStatefulWidget {
  const KnowledgeCardsScreen({super.key});

  @override
  ConsumerState<KnowledgeCardsScreen> createState() =>
      _KnowledgeCardsScreenState();
}

class _KnowledgeCardsScreenState extends ConsumerState<KnowledgeCardsScreen> {
  /// 当前过滤标签；null = 不按标签过滤。
  String? _tagFilter;

  /// 只看收藏。与标签过滤互斥（单选语义）。
  bool _favOnly = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final async = ref.watch(knowledgeCardsProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('知识卡片')),
      body: async.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (err, _) => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text('加载失败：${userFacingError(err)}',
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: theme.colorScheme.error)),
          ),
        ),
        data: (cards) {
          if (cards.isEmpty) return const _EmptyState();

          // 标签全集（话题标签，按出现顺序去重）。
          final tags = <String>[];
          for (final c in cards) {
            for (final t in c.tags) {
              if (!tags.contains(t)) tags.add(t);
            }
          }
          // 过滤标签可能已随卡片删除而消失——失效则回落到全部。
          if (_tagFilter != null && !tags.contains(_tagFilter)) {
            _tagFilter = null;
          }

          final visible = _favOnly
              ? cards.where((c) => c.isFavorite).toList()
              : _tagFilter == null
                  ? cards
                  : cards.where((c) => c.tags.contains(_tagFilter)).toList();

          return Column(
            children: [
              _FilterBar(
                tags: tags,
                tagFilter: _tagFilter,
                favOnly: _favOnly,
                onAll: () => setState(() {
                  _favOnly = false;
                  _tagFilter = null;
                }),
                onFavorite: () => setState(() {
                  _favOnly = !_favOnly;
                  _tagFilter = null;
                }),
                onTag: (t) => setState(() {
                  _favOnly = false;
                  _tagFilter = _tagFilter == t ? null : t;
                }),
              ),
              Expanded(
                child: ListView.builder(
                  padding: const EdgeInsets.fromLTRB(
                      AppSpacing.md, AppSpacing.xs, AppSpacing.md, AppSpacing.xl),
                  itemCount: visible.length,
                  itemBuilder: (context, i) => _CardTile(
                    card: visible[i],
                    onToggleFavorite: () => _toggleFavorite(visible[i]),
                    onOptimize: () => _optimize(visible[i]),
                    onEditTags: () => _editTags(visible[i]),
                    onShare: () => _share(visible[i]),
                    onDelete: () => _delete(visible[i]),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _toggleFavorite(KnowledgeCard card) async {
    try {
      await ref
          .read(appStateProvider.notifier)
          .setKnowledgeCardImportance(card.id, card.isFavorite ? 0 : 1);
    } catch (e) {
      showAppToast(userFacingError(e), icon: Icons.error_outline_rounded);
    }
  }

  Future<void> _delete(KnowledgeCard card) async {
    try {
      await ref.read(appStateProvider.notifier).deleteKnowledgeCard(card.id);
      showAppToast('已删除', icon: Icons.delete_outline_rounded);
    } catch (e) {
      showAppToast(userFacingError(e), icon: Icons.error_outline_rounded);
    }
  }

  void _share(KnowledgeCard card) {
    final text =
        card.term.isNotEmpty ? '${card.term}\n${card.content}' : card.content;
    shareText(text);
  }

  /// 整理标签——增删话题标签。落库后关联表对账，删掉的标签若无人引用即被清除
  /// （孤儿删除），其引用计数也随之消化。收藏是 importance、不在标签里编辑。
  Future<void> _editTags(KnowledgeCard card) async {
    final result = await showDialog<List<String>>(
      context: context,
      builder: (_) => _EditTagsDialog(card: card),
    );
    if (result == null) return;
    try {
      await ref
          .read(appStateProvider.notifier)
          .updateKnowledgeCard(card.copyWith(tags: result));
    } catch (e) {
      showAppToast(userFacingError(e), icon: Icons.error_outline_rounded);
    }
  }

  Future<void> _optimize(KnowledgeCard card) async {
    final notifier = ref.read(appStateProvider.notifier);
    final result = await showDialog<LlmCardResult>(
      context: context,
      builder: (_) => _OptimizeDialog(
        card: card,
        future: notifier.optimizeKnowledgeCard(card),
      ),
    );
    if (result == null) return;
    // 合并标签：保留原有，并入新推荐里没有的。
    final merged = List<String>.from(card.tags);
    for (final t in result.tags) {
      if (!merged.contains(t)) merged.add(t);
    }
    try {
      await notifier.updateKnowledgeCard(
          card.copyWith(content: result.text, tags: merged));
      showAppToast('已优化', icon: Icons.auto_awesome_rounded);
    } catch (e) {
      showAppToast(userFacingError(e), icon: Icons.error_outline_rounded);
    }
  }
}

class _FilterBar extends StatelessWidget {
  final List<String> tags;
  final String? tagFilter;
  final bool favOnly;
  final VoidCallback onAll;
  final VoidCallback onFavorite;
  final ValueChanged<String> onTag;
  const _FilterBar({
    required this.tags,
    required this.tagFilter,
    required this.favOnly,
    required this.onAll,
    required this.onFavorite,
    required this.onTag,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 48,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
        children: [
          Padding(
            padding: const EdgeInsets.only(right: AppSpacing.sm),
            child: ChoiceChip(
              label: const Text('全部'),
              selected: !favOnly && tagFilter == null,
              onSelected: (_) => onAll(),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(right: AppSpacing.sm),
            child: ChoiceChip(
              avatar: Icon(
                favOnly ? Icons.star_rounded : Icons.star_border_rounded,
                size: 16,
                color: favOnly ? const Color(0xFFF59E0B) : null,
              ),
              label: const Text('收藏'),
              selected: favOnly,
              onSelected: (_) => onFavorite(),
            ),
          ),
          for (final t in tags)
            Padding(
              padding: const EdgeInsets.only(right: AppSpacing.sm),
              child: ChoiceChip(
                label: Text(t),
                selected: !favOnly && tagFilter == t,
                onSelected: (_) => onTag(t),
              ),
            ),
        ],
      ),
    );
  }
}

class _CardTile extends StatelessWidget {
  final KnowledgeCard card;
  final VoidCallback onToggleFavorite;
  final VoidCallback onOptimize;
  final VoidCallback onEditTags;
  final VoidCallback onShare;
  final VoidCallback onDelete;
  const _CardTile({
    required this.card,
    required this.onToggleFavorite,
    required this.onOptimize,
    required this.onEditTags,
    required this.onShare,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final displayTags = card.tags;

    return Card(
      margin: const EdgeInsets.only(bottom: AppSpacing.sm),
      elevation: 0,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.lg)),
      color: scheme.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
            AppSpacing.md, AppSpacing.sm, AppSpacing.xs, AppSpacing.sm),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  child: Text(card.term,
                      style: theme.textTheme.titleMedium
                          ?.copyWith(fontWeight: FontWeight.w600)),
                ),
                IconButton(
                  onPressed: onToggleFavorite,
                  visualDensity: VisualDensity.compact,
                  icon: Icon(
                    card.isFavorite
                        ? Icons.star_rounded
                        : Icons.star_border_rounded,
                    color: card.isFavorite ? const Color(0xFFF59E0B) : null,
                  ),
                  tooltip: card.isFavorite ? '取消收藏' : '收藏',
                ),
                PopupMenuButton<String>(
                  icon: const Icon(Icons.more_vert),
                  tooltip: '更多',
                  onSelected: (v) {
                    if (v == 'optimize') onOptimize();
                    if (v == 'tags') onEditTags();
                    if (v == 'share') onShare();
                    if (v == 'delete') onDelete();
                  },
                  itemBuilder: (_) => [
                    const PopupMenuItem(
                      value: 'optimize',
                      child: ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(Icons.auto_awesome_outlined),
                        title: Text('一键优化'),
                      ),
                    ),
                    const PopupMenuItem(
                      value: 'tags',
                      child: ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(Icons.sell_outlined),
                        title: Text('整理标签'),
                      ),
                    ),
                    const PopupMenuItem(
                      value: 'share',
                      child: ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(Icons.ios_share),
                        title: Text('分享'),
                      ),
                    ),
                    PopupMenuItem(
                      value: 'delete',
                      child: ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(Icons.delete_outline,
                            color: scheme.error),
                        title: Text('删除',
                            style: TextStyle(color: scheme.error)),
                      ),
                    ),
                  ],
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(right: AppSpacing.sm),
              child: Text(card.content,
                  style: theme.textTheme.bodyMedium?.copyWith(
                      color: scheme.onSurface.withValues(alpha: 0.85),
                      height: 1.4)),
            ),
            if (displayTags.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.sm),
              Wrap(
                spacing: AppSpacing.sm,
                runSpacing: AppSpacing.xs,
                children: [
                  for (final t in displayTags)
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 3),
                      decoration: BoxDecoration(
                        color:
                            scheme.secondaryContainer.withValues(alpha: 0.5),
                        borderRadius: BorderRadius.circular(AppRadius.sm),
                      ),
                      child: Text(t,
                          style: theme.textTheme.labelSmall?.copyWith(
                              color: scheme.onSecondaryContainer)),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 整理标签弹窗——删除现有话题标签 / 添加自定义标签。确认 pop 回新的标签列表。
class _EditTagsDialog extends StatefulWidget {
  final KnowledgeCard card;
  const _EditTagsDialog({required this.card});

  @override
  State<_EditTagsDialog> createState() => _EditTagsDialogState();
}

class _EditTagsDialogState extends State<_EditTagsDialog> {
  late final List<String> _tags = List<String>.from(widget.card.tags);
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _add() {
    final t = _controller.text.trim();
    if (t.isEmpty || _tags.contains(t)) {
      _controller.clear();
      return;
    }
    setState(() => _tags.add(t));
    _controller.clear();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('整理标签'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_tags.isEmpty)
            Text('暂无标签',
                style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant))
          else
            Wrap(
              spacing: AppSpacing.sm,
              runSpacing: AppSpacing.xs,
              children: [
                for (final t in _tags)
                  InputChip(
                    label: Text(t),
                    visualDensity: VisualDensity.compact,
                    onDeleted: () => setState(() => _tags.remove(t)),
                  ),
              ],
            ),
          const SizedBox(height: AppSpacing.md),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _controller,
                  textInputAction: TextInputAction.done,
                  decoration: const InputDecoration(
                    isDense: true,
                    hintText: '添加标签',
                    border: OutlineInputBorder(),
                  ),
                  onSubmitted: (_) => _add(),
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              IconButton.filledTonal(
                onPressed: _add,
                icon: const Icon(Icons.add),
                tooltip: '添加',
              ),
            ],
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _tags),
          child: const Text('保存'),
        ),
      ],
    );
  }
}

/// 一键优化预览弹窗——跑 LLM，给出优化后的正文供用户确认。确认 pop 回 result。
class _OptimizeDialog extends StatelessWidget {
  final KnowledgeCard card;
  final Future<LlmCardResult> future;
  const _OptimizeDialog({required this.card, required this.future});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('一键优化'),
      content: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.5,
        ),
        child: FutureBuilder<LlmCardResult>(
          future: future,
          builder: (context, snap) {
            if (snap.connectionState != ConnectionState.done) {
              return const SizedBox(
                height: 72,
                child: Center(child: CircularProgressIndicator()),
              );
            }
            if (snap.hasError) {
              return Text(userFacingError(snap.error!),
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(color: theme.colorScheme.error));
            }
            return SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('原释义',
                      style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant)),
                  const SizedBox(height: 4),
                  Text(card.content,
                      style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurface
                              .withValues(alpha: 0.5))),
                  const Divider(height: AppSpacing.lg),
                  Text('优化后',
                      style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.primary)),
                  const SizedBox(height: 4),
                  SelectableText(snap.data!.text,
                      style: theme.textTheme.bodyLarge),
                ],
              ),
            );
          },
        ),
      ),
      actions: [
        FutureBuilder<LlmCardResult>(
          future: future,
          builder: (context, snap) {
            final r = (snap.connectionState == ConnectionState.done &&
                    !snap.hasError)
                ? snap.data
                : null;
            final ready = r != null && r.text.trim().isNotEmpty;
            return Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: ready ? () => Navigator.pop(context, r) : null,
                  child: const Text('应用'),
                ),
              ],
            );
          },
        ),
      ],
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.bookmarks_outlined,
              size: 48,
              color: theme.colorScheme.onSurface.withValues(alpha: 0.15)),
          const SizedBox(height: AppSpacing.sm),
          Text('还没有知识卡片',
              style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.4))),
          const SizedBox(height: 4),
          Text('对话里选中文字 → 释义/翻译 → 保存',
              style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.3))),
        ],
      ),
    );
  }
}
