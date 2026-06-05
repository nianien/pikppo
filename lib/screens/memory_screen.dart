import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import '../providers/app_state_provider.dart';
import '../models/app_state.dart';
import '../models/memory.dart';
import '../theme/design_tokens.dart';

Color _parseRoleColor(String hex) =>
    Color(int.parse(hex.replaceFirst('#', '0xFF')));

const _uuid = Uuid();

String _formatTime(int timestamp) {
  final dt = DateTime.fromMillisecondsSinceEpoch(timestamp);
  final now = DateTime.now();
  final diff = now.difference(dt);
  if (diff.inMinutes < 60) return '${diff.inMinutes}分钟前';
  if (diff.inHours < 24) return '${diff.inHours}小时前';
  if (diff.inDays < 30) return '${diff.inDays}天前';
  return '${dt.month}月${dt.day}日';
}

class MemoryScreen extends ConsumerStatefulWidget {
  const MemoryScreen({super.key});

  @override
  ConsumerState<MemoryScreen> createState() => _MemoryScreenState();
}

class _MemoryScreenState extends ConsumerState<MemoryScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  void _showAddMemoryDialog() {
    final contentController = TextEditingController();
    final tagController = TextEditingController();
    String type = 'semantic';

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('添加记忆'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'semantic', label: Text('语义')),
                  ButtonSegment(value: 'episodic', label: Text('情节')),
                  ButtonSegment(value: 'working', label: Text('工作')),
                ],
                selected: {type},
                onSelectionChanged: (val) =>
                    setDialogState(() => type = val.first),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: contentController,
                decoration: const InputDecoration(
                  labelText: '记忆内容',
                  border: OutlineInputBorder(),
                ),
                maxLines: 3,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: tagController,
                decoration: const InputDecoration(
                  labelText: '标签（逗号分隔）',
                  hintText: '如：饮食, 偏好',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () {
                if (contentController.text.trim().isEmpty) return;
                final memory = Memory(
                  id: _uuid.v4(),
                  type: type,
                  content: contentController.text.trim(),
                  timestamp: DateTime.now().millisecondsSinceEpoch,
                  tags: tagController.text
                      .split(',')
                      .map((t) => t.trim())
                      .where((t) => t.isNotEmpty)
                      .toList(),
                );
                ref.read(appStateProvider.notifier).addMemory(memory);
                Navigator.pop(ctx);
              },
              child: const Text('添加'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final appState = ref.watch(appStateProvider);
    final theme = Theme.of(context);

    final semanticMemories =
        appState.memories.where((m) => m.type == 'semantic').toList();
    final episodicMemories =
        appState.memories.where((m) => m.type == 'episodic').toList()
          ..sort((a, b) => b.timestamp.compareTo(a.timestamp));
    final workingMemories =
        appState.memories.where((m) => m.type == 'working').toList()
          ..sort((a, b) => b.timestamp.compareTo(a.timestamp));

    return Scaffold(
      appBar: AppBar(
        title: const Text('记忆面板'),
        actions: [
          IconButton(
            onPressed: _showAddMemoryDialog,
            icon: const Icon(Icons.add),
            tooltip: '手动添加',
          ),
        ],
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(text: '语义记忆'),
            Tab(text: '情节记忆'),
            Tab(text: '工作记忆'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          // Semantic memories - tag style
          _buildSemanticTab(semanticMemories, theme),
          // Episodic memories - timeline
          _buildListTab(episodicMemories, appState, theme),
          // Working memories - list
          _buildListTab(workingMemories, appState, theme),
        ],
      ),
    );
  }

  Widget _buildSemanticTab(List<Memory> memories, ThemeData theme) {
    if (memories.isEmpty) return _emptyState(theme, '暂无语义记忆');
    return SingleChildScrollView(
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Wrap(
        spacing: AppSpacing.xs,
        runSpacing: AppSpacing.xs,
        children: memories
            .map((mem) => _SemanticChip(
                  memory: mem,
                  onDelete: () => ref
                      .read(appStateProvider.notifier)
                      .deleteMemory(mem.id),
                ))
            .toList(),
      ),
    );
  }

  Widget _buildListTab(
      List<Memory> memories, AppState appState, ThemeData theme) {
    if (memories.isEmpty) return _emptyState(theme, '暂无记忆');
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.md,
        AppSpacing.xs,
        AppSpacing.md,
        AppSpacing.xl,
      ),
      itemCount: memories.length,
      itemBuilder: (context, index) {
        final mem = memories[index];
        final role = mem.roleId != null
            ? appState.roles
                .where((r) => r.id == mem.roleId)
                .firstOrNull
            : null;

        return _MemoryCard(
          memory: mem,
          roleName: role?.name,
          roleColor: role != null ? _parseRoleColor(role.color) : null,
          onDelete: () =>
              ref.read(appStateProvider.notifier).deleteMemory(mem.id),
        );
      },
    );
  }

  Widget _emptyState(ThemeData theme, String text) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(AppRadius.lg),
            ),
            child: Icon(
              Icons.auto_awesome_outlined,
              color:
                  theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          Text(
            text,
            style: theme.textTheme.bodyMedium?.copyWith(
              color:
                  theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
            ),
          ),
        ],
      ),
    );
  }
}

class _SemanticChip extends StatelessWidget {
  final Memory memory;
  final VoidCallback onDelete;
  const _SemanticChip({required this.memory, required this.onDelete});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Material(
      color: scheme.primaryContainer.withValues(alpha: 0.4),
      borderRadius: BorderRadius.circular(AppRadius.pill),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.pill),
        onLongPress: onDelete,
        child: Padding(
          padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.sm + 2, vertical: AppSpacing.xs),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (memory.tags.isNotEmpty) ...[
                Text('#${memory.tags.first}',
                    style: theme.textTheme.labelSmall?.copyWith(
                        color: scheme.primary,
                        fontWeight: FontWeight.w600)),
                const SizedBox(width: AppSpacing.xs),
              ],
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 240),
                child: Text(
                  memory.content,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: scheme.onPrimaryContainer,
                  ),
                ),
              ),
              const SizedBox(width: AppSpacing.xs),
              GestureDetector(
                onTap: onDelete,
                child: Icon(Icons.close,
                    size: 16,
                    color: scheme.onPrimaryContainer
                        .withValues(alpha: 0.7)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MemoryCard extends StatelessWidget {
  final Memory memory;
  final String? roleName;
  final Color? roleColor;
  final VoidCallback onDelete;

  const _MemoryCard({
    required this.memory,
    this.roleName,
    this.roleColor,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.xs),
      child: Dismissible(
        key: Key(memory.id),
        direction: DismissDirection.endToStart,
        background: Container(
          alignment: Alignment.centerRight,
          padding: const EdgeInsets.only(right: AppSpacing.lg),
          decoration: BoxDecoration(
            color: scheme.errorContainer,
            borderRadius: BorderRadius.circular(AppRadius.lg),
          ),
          child:
              Icon(Icons.delete_outline, color: scheme.onErrorContainer),
        ),
        onDismissed: (_) => onDelete(),
        child: Material(
          color: scheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(AppRadius.lg),
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.md),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: scheme.primary.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(AppRadius.md),
                  ),
                  child: Icon(
                    memory.type == 'episodic'
                        ? Icons.history
                        : Icons.pending_actions,
                    size: 20,
                    color: scheme.primary,
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(memory.content,
                          style: theme.textTheme.bodyLarge),
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: AppSpacing.xs,
                        runSpacing: 4,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Text(
                            _formatTime(memory.timestamp),
                            style: theme.textTheme.labelSmall?.copyWith(
                                color: scheme.onSurfaceVariant),
                          ),
                          if (roleName != null && roleColor != null)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 2),
                              decoration: BoxDecoration(
                                color: roleColor!.withValues(alpha: 0.16),
                                borderRadius:
                                    BorderRadius.circular(AppRadius.pill),
                              ),
                              child: Text(
                                roleName!,
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: roleColor,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ...memory.tags.map((tag) => Text('#$tag',
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: scheme.onSurfaceVariant
                                    .withValues(alpha: 0.7),
                              ))),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
