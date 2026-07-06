import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';
import '../models/knowledge_card.dart';
import '../models/message.dart';
import '../providers/app_state_provider.dart';
import '../theme/design_tokens.dart';
import '../utils/time_format.dart';
import '../utils/user_facing_error.dart';
import 'app_toast.dart';

/// 调系统分享面板分享一段文本（share_plus）。空串不分享。
void shareText(String text) {
  if (text.trim().isEmpty) return;
  SharePlus.instance.share(ShareParams(text: text));
}

/// 长按消息的操作面板：复制 / 转发 / 多选（头部带完整时间戳）。
/// [onEnterSelection] 非空时显示"多选"——点选后进入多选删除模式并以本条为初选。
void showMessageActions(
  BuildContext context,
  WidgetRef ref,
  Message message, {
  void Function(Message seed)? onEnterSelection,
}) {
  showModalBottomSheet(
    context: context,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            fmtMessageStamp(
                DateTime.fromMillisecondsSinceEpoch(message.timestamp)),
            style: Theme.of(ctx).textTheme.labelSmall?.copyWith(
                color: Theme.of(ctx).colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: AppSpacing.xs),
          if (message.content.isNotEmpty) ...[
            ListTile(
              leading: const Icon(Icons.copy_rounded),
              title: const Text('复制'),
              onTap: () {
                Navigator.pop(ctx);
                Clipboard.setData(ClipboardData(text: message.content));
                showAppToast('已复制', icon: Icons.copy_rounded);
              },
            ),
            ListTile(
              leading: const Icon(Icons.translate_rounded),
              title: const Text('翻译'),
              onTap: () {
                Navigator.pop(ctx);
                showTranslateDialog(context, ref, message.content);
              },
            ),
            ListTile(
              leading: const Icon(Icons.ios_share_rounded),
              title: const Text('分享'),
              onTap: () {
                Navigator.pop(ctx);
                shareText(message.content);
              },
            ),
          ],
          ListTile(
            leading: const Icon(Icons.forward_rounded),
            title: const Text('转发'),
            onTap: () {
              Navigator.pop(ctx);
              showForwardPicker(context, ref, message);
            },
          ),
          if (onEnterSelection != null)
            ListTile(
              leading: const Icon(Icons.checklist_rounded),
              title: const Text('多选'),
              onTap: () {
                Navigator.pop(ctx);
                onEnterSelection(message);
              },
            ),
        ],
      ),
    ),
  );
}

/// 转发目标选择：所有角色私聊 + 群聊。
void showForwardPicker(
    BuildContext context, WidgetRef ref, Message message) {
  final state = ref.read(appStateProvider);
  showModalBottomSheet(
    context: context,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(ctx).size.height * 0.6,
        ),
        child: ListView(
          shrinkWrap: true,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                  AppSpacing.md, 0, AppSpacing.md, AppSpacing.xs),
              child: Text('转发到',
                  style: Theme.of(ctx)
                      .textTheme
                      .titleMedium
                      ?.copyWith(fontWeight: FontWeight.w700)),
            ),
            for (final role in state.roles)
              ListTile(
                leading: Text(role.icon,
                    style: const TextStyle(fontSize: 22)),
                title: Text(role.name),
                onTap: () {
                  Navigator.pop(ctx);
                  ref
                      .read(appStateProvider.notifier)
                      .forwardMessage(message, toRoleId: role.id);
                  showAppToast('已转发给 ${role.name}',
                      icon: Icons.forward_rounded);
                },
              ),
            for (final group in state.groups)
              ListTile(
                leading: const Icon(Icons.groups_outlined),
                title: Text(group.name),
                onTap: () {
                  Navigator.pop(ctx);
                  ref
                      .read(appStateProvider.notifier)
                      .forwardMessage(message, toGroupId: group.id);
                  showAppToast('已转发到 ${group.name}',
                      icon: Icons.forward_rounded);
                },
              ),
          ],
        ),
      ),
    ),
  );
}

/// AI 翻译选中/整条文本，弹窗显示译文（不进对话历史）。未配置模型先提示。
void showTranslateDialog(BuildContext context, WidgetRef ref, String text) {
  if (text.trim().isEmpty) return;
  if (ref.read(appStateProvider).currentModel.isEmpty) {
    showAppToast('未配置模型，请先在设置选择模型',
        icon: Icons.cloud_off_outlined);
    return;
  }
  // future 在这里创建一次，避免 FutureBuilder 随弹窗重建反复触发翻译。
  final future = ref.read(appStateProvider.notifier).translateText(text);
  showDialog(
    context: context,
    builder: (_) => _LlmResultDialog(
        title: '翻译', source: text, sourceTag: '翻译', future: future),
  );
}

/// 解释选中的 [term]——只带它在 [fullText] 里所在的一两句作语境，一次性调模型，
/// 弹窗显示结果（不污染对话、不拖全历史）。用户显式触发，绝非后台扫描。
void showExplainDialog(
    BuildContext context, WidgetRef ref, String term, String fullText) {
  if (term.trim().isEmpty) return;
  if (ref.read(appStateProvider).currentModel.isEmpty) {
    showAppToast('未配置模型，请先在设置选择模型',
        icon: Icons.cloud_off_outlined);
    return;
  }
  final ctx = _surroundingContext(fullText, term);
  final future = ref.read(appStateProvider.notifier).explainInContext(term, ctx);
  showDialog(
    context: context,
    builder: (_) => _LlmResultDialog(
        title: '解释', source: term, sourceTag: '释义', future: future),
  );
}

/// 取 [selection] 在 [full] 中所在的一两句作语境（最小必要量，不甩整段对话）。
/// 以中英文句末标点 / 换行切句；定位不到就退回 selection 本身。
String _surroundingContext(String full, String selection) {
  final idx = full.indexOf(selection);
  if (idx < 0) return selection;
  const enders = '。！？!?\n；;';
  var start = idx;
  while (start > 0 && !enders.contains(full[start - 1])) {
    start--;
  }
  var end = idx + selection.length;
  while (end < full.length && !enders.contains(full[end])) {
    end++;
  }
  if (end < full.length) end++; // 含句末标点
  final sentence = full.substring(start, end).trim();
  // 句子太短（如选中就是大半句），补上前一句给点语境；整体仍远小于整段对话。
  if (sentence.length < 30 && start > 0) {
    var prev = start - 1;
    while (prev > 0 && !enders.contains(full[prev - 1])) {
      prev--;
    }
    return full.substring(prev, end).trim();
  }
  return sentence;
}

/// 释义/翻译结果弹窗——展示正文 + LLM 推荐标签（可多选），可「保存到知识卡片」。
/// [sourceTag]（释义/翻译）作为卡片的**来源分类**单独存，不混进话题标签；
/// 保存时只存用户勾选的推荐标签。
class _LlmResultDialog extends ConsumerStatefulWidget {
  final String title;
  final String source;
  final String sourceTag;
  final Future<LlmCardResult> future;
  const _LlmResultDialog({
    required this.title,
    required this.source,
    required this.sourceTag,
    required this.future,
  });

  @override
  ConsumerState<_LlmResultDialog> createState() => _LlmResultDialogState();
}

class _LlmResultDialogState extends ConsumerState<_LlmResultDialog> {
  LlmCardResult? _result;
  Object? _error;
  bool _saved = false;

  /// 勾选要保存的标签——结果就绪时默认全选。
  final Set<String> _selected = {};

  @override
  void initState() {
    super.initState();
    widget.future.then((r) {
      if (!mounted) return;
      setState(() {
        _result = r;
        _selected
          ..clear()
          ..addAll(r.tags);
      });
    }).catchError((Object e) {
      if (!mounted) return;
      setState(() => _error = e);
    });
  }

  Future<void> _save() async {
    final r = _result;
    if (r == null) return;
    try {
      await ref.read(appStateProvider.notifier).saveKnowledgeCard(
            term: widget.source,
            content: r.text,
            source: widget.sourceTag,
            tags: _selected.toList(),
          );
      if (!mounted) return;
      setState(() => _saved = true);
      showAppToast('已存入知识卡片', icon: Icons.bookmark_added_rounded);
    } catch (e) {
      showAppToast(userFacingError(e), icon: Icons.error_outline_rounded);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final r = _result;
    return AlertDialog(
      title: Text(widget.title),
      content: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.5,
        ),
        child: _error != null
            ? Text(userFacingError(_error!),
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: theme.colorScheme.error))
            : r == null
                ? const SizedBox(
                    height: 72,
                    child: Center(child: CircularProgressIndicator()),
                  )
                : SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(widget.source,
                            style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant)),
                        const Divider(height: AppSpacing.lg),
                        SelectableText(r.text,
                            style: theme.textTheme.bodyLarge),
                        if (r.tags.isNotEmpty) ...[
                          const SizedBox(height: AppSpacing.md),
                          Text('标签（点选要保存的）',
                              style: theme.textTheme.labelSmall?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant)),
                          const SizedBox(height: AppSpacing.xs),
                          Wrap(
                            spacing: AppSpacing.sm,
                            runSpacing: AppSpacing.xs,
                            children: [
                              for (final t in r.tags)
                                () {
                                  final sel = _selected.contains(t);
                                  return FilterChip(
                                    label: Text(t),
                                    selected: sel,
                                    showCheckmark: false,
                                    selectedColor: theme.colorScheme.primary,
                                    backgroundColor: theme
                                        .colorScheme.surfaceContainerHighest,
                                    side: BorderSide.none,
                                    labelStyle:
                                        theme.textTheme.labelMedium?.copyWith(
                                      color: sel
                                          ? theme.colorScheme.onPrimary
                                          : theme.colorScheme.onSurfaceVariant,
                                    ),
                                    visualDensity: VisualDensity.compact,
                                    materialTapTargetSize:
                                        MaterialTapTargetSize.shrinkWrap,
                                    onSelected: _saved
                                        ? null
                                        : (on) => setState(() => on
                                            ? _selected.add(t)
                                            : _selected.remove(t)),
                                  );
                                }(),
                            ],
                          ),
                        ],
                      ],
                    ),
                  ),
      ),
      actions: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextButton.icon(
              onPressed: (r != null && !_saved) ? _save : null,
              icon: Icon(
                _saved
                    ? Icons.bookmark_added_rounded
                    : Icons.bookmark_add_outlined,
                size: 18,
              ),
              label: Text(_saved ? '已保存' : '保存到知识卡片'),
            ),
            TextButton(
              onPressed: r != null
                  ? () {
                      Clipboard.setData(ClipboardData(text: r.text.trim()));
                      showAppToast('已复制', icon: Icons.copy_rounded);
                    }
                  : null,
              child: const Text('复制'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('关闭'),
            ),
          ],
        ),
      ],
    );
  }
}
