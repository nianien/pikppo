import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import '../providers/app_state_provider.dart';
import '../models/app_state.dart';
import '../models/memory.dart';

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
    if (memories.isEmpty) {
      return const Center(child: Text('暂无语义记忆'));
    }
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Wrap(
        spacing: 10,
        runSpacing: 10,
        children: memories.map((mem) {
          return Dismissible(
            key: Key(mem.id),
            direction: DismissDirection.endToStart,
            background: Container(
              alignment: Alignment.centerRight,
              padding: const EdgeInsets.only(right: 16),
              color: Colors.red,
              child: const Icon(Icons.delete, color: Colors.white),
            ),
            onDismissed: (_) {
              ref.read(appStateProvider.notifier).deleteMemory(mem.id);
            },
            child: Chip(
              avatar: mem.tags.isNotEmpty
                  ? CircleAvatar(
                      backgroundColor:
                          theme.colorScheme.primary.withValues(alpha: 0.15),
                      child: Text(mem.tags.first[0],
                          style: TextStyle(
                              fontSize: 10,
                              color: theme.colorScheme.primary)),
                    )
                  : null,
              label: Text(mem.content),
              backgroundColor:
                  theme.colorScheme.surfaceContainerHighest,
              deleteIcon: const Icon(Icons.close, size: 16),
              onDeleted: () {
                ref.read(appStateProvider.notifier).deleteMemory(mem.id);
              },
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildListTab(
      List<Memory> memories, AppState appState, ThemeData theme) {
    if (memories.isEmpty) {
      return const Center(child: Text('暂无记忆'));
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: memories.length,
      itemBuilder: (context, index) {
        final mem = memories[index];
        final role = mem.roleId != null
            ? appState.roles
                .where((r) => r.id == mem.roleId)
                .firstOrNull
            : null;

        return Dismissible(
          key: Key(mem.id),
          direction: DismissDirection.endToStart,
          background: Container(
            alignment: Alignment.centerRight,
            padding: const EdgeInsets.only(right: 20),
            color: Colors.red,
            child:
                const Icon(Icons.delete_outline, color: Colors.white),
          ),
          onDismissed: (_) {
            ref.read(appStateProvider.notifier).deleteMemory(mem.id);
          },
          child: ListTile(
            leading: CircleAvatar(
              backgroundColor: theme.colorScheme.surfaceContainerHighest,
              child: Icon(
                mem.type == 'episodic'
                    ? Icons.history
                    : Icons.pending_actions,
                size: 20,
                color: theme.colorScheme.primary,
              ),
            ),
            title: Text(mem.content),
            subtitle: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
              children: [
                Text(_formatTime(mem.timestamp),
                    style: theme.textTheme.labelSmall),
                if (role != null) ...[
                  const SizedBox(width: 8),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                    decoration: BoxDecoration(
                      color: Color(int.parse(
                              role.color.replaceFirst('#', '0xFF')))
                          .withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      role.name,
                      style: TextStyle(
                        fontSize: 10,
                        color: Color(int.parse(
                            role.color.replaceFirst('#', '0xFF'))),
                      ),
                    ),
                  ),
                ],
                ...mem.tags.map((tag) => Padding(
                      padding: const EdgeInsets.only(left: 6),
                      child: Text('· $tag',
                          style: theme.textTheme.labelSmall
                              ?.copyWith(color: theme.colorScheme.outline)),
                    )),
              ],
            ),
            ),
          ),
        );
      },
    );
  }
}
