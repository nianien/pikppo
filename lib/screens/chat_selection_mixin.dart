import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/app_state_provider.dart';
import '../theme/design_tokens.dart';

/// 私聊 / 群聊共用的"消息多选删除"状态机。删的是单/多条消息，不是会话。
/// 落到 [AppStateNotifier.deleteMessages]——对私聊（groupId==null）和群聊消息
/// 同样成立。混入到各自的 [ConsumerState]，UI 再读 [selectionMode] / [selectedIds]。
mixin ChatSelectionMixin<T extends ConsumerStatefulWidget> on ConsumerState<T> {
  bool selectionMode = false;
  final Set<String> selectedIds = {};

  /// 进入多选模式，并以 [seedId] 为初选（长按面板"多选"触发）。
  void enterSelection(String seedId) {
    setState(() {
      selectionMode = true;
      selectedIds
        ..clear()
        ..add(seedId);
    });
  }

  void exitSelection() {
    setState(() {
      selectionMode = false;
      selectedIds.clear();
    });
  }

  void toggleSelect(String id) {
    setState(() {
      if (!selectedIds.add(id)) selectedIds.remove(id);
    });
  }

  Future<void> _deleteSelected() async {
    if (selectedIds.isEmpty) {
      exitSelection();
      return;
    }
    final ids = Set<String>.from(selectedIds);
    await ref.read(appStateProvider.notifier).deleteMessages(ids);
    exitSelection();
  }

  /// 多选模式顶栏：关闭（退出）+ "已选 N 条" + 删除（带二次确认）。
  AppBar buildSelectionAppBar(BuildContext context) {
    final theme = Theme.of(context);
    final n = selectedIds.length;
    return AppBar(
      leading: IconButton(
        icon: const Icon(Icons.close_rounded),
        onPressed: exitSelection,
      ),
      title: Text('已选 $n 条'),
      actions: [
        IconButton(
          icon: const Icon(Icons.delete_outline_rounded),
          color: theme.colorScheme.error,
          onPressed: n == 0 ? null : () => _confirmDeleteSelected(context),
        ),
        const SizedBox(width: AppSpacing.xs),
      ],
    );
  }

  void _confirmDeleteSelected(BuildContext context) {
    final n = selectedIds.length;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除消息'),
        content: Text('确定删除选中的 $n 条消息吗？此操作不可恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              _deleteSelected();
            },
            style: FilledButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.error),
            child: const Text('删除'),
          ),
        ],
      ),
    );
  }
}
