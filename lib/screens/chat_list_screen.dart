import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/app_state_provider.dart';
import '../models/role.dart';
import '../models/group.dart';
import 'chat_detail_screen.dart';
import 'group_chat_screen.dart';

Color _parseColor(String hex) {
  return Color(int.parse(hex.replaceFirst('#', '0xFF')));
}

String _formatTime(int? timestamp) {
  if (timestamp == null) return '';
  final dt = DateTime.fromMillisecondsSinceEpoch(timestamp);
  final now = DateTime.now();
  final diff = now.difference(dt);
  if (diff.inMinutes < 1) return '刚刚';
  if (diff.inMinutes < 60) return '${diff.inMinutes}分钟前';
  if (diff.inHours < 24) return '${diff.inHours}小时前';
  if (diff.inDays < 7) return '${diff.inDays}天前';
  return '${dt.month}/${dt.day}';
}

class ChatListScreen extends ConsumerWidget {
  const ChatListScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final appState = ref.watch(appStateProvider);
    final notifier = ref.read(appStateProvider.notifier);
    final theme = Theme.of(context);

    // Group chats sorted by last message time
    final groupItems = <_GroupChatItem>[];
    for (final group in appState.groups) {
      final lastTime = notifier.getLastGroupMessageTime(group.id);
      final msgs = notifier.getGroupMessagesList(group.id);
      final lastMsg = msgs.isNotEmpty ? msgs.last.content : '群聊已创建';
      groupItems.add(_GroupChatItem(
        group: group,
        lastMessage: lastMsg,
        lastTime: lastTime ?? 0,
        roles: group.roleIds
            .map((id) => appState.getRoleById(id))
            .whereType<Role>()
            .toList(),
      ));
    }
    groupItems.sort((a, b) => b.lastTime.compareTo(a.lastTime));

    // Private chats sorted by last message time
    final privateItems = <_PrivateChatItem>[];
    for (final role in appState.roles) {
      final msgs = notifier.getMessagesForRole(role.id);
      if (msgs.isEmpty) continue;
      final lastMsg = msgs.last;
      privateItems.add(_PrivateChatItem(
        role: role,
        lastMessage: lastMsg.content,
        lastTime: lastMsg.timestamp,
      ));
    }
    privateItems.sort((a, b) => b.lastTime.compareTo(a.lastTime));

    final isEmpty = groupItems.isEmpty && privateItems.isEmpty;
    final hasGroups = groupItems.isNotEmpty;
    final hasPrivate = privateItems.isNotEmpty;

    // Flat index layout: [group header?, ...groups, private header?, ...privates]
    int totalItems = 0;
    if (hasGroups) totalItems += 1 + groupItems.length;
    if (hasPrivate) totalItems += 1 + privateItems.length;

    return Scaffold(
      appBar: AppBar(
        title: const Text('聊天'),
        actions: [
          IconButton(
            onPressed: () => _showNewChatSheet(context, ref),
            icon: const Icon(Icons.add_comment_outlined),
            tooltip: '发起聊天',
          ),
        ],
      ),
      body: isEmpty
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.chat_bubble_outline,
                      size: 64,
                      color:
                          theme.colorScheme.onSurface.withValues(alpha: 0.2)),
                  const SizedBox(height: 16),
                  Text('暂无聊天',
                      style: theme.textTheme.bodyLarge?.copyWith(
                          color: theme.colorScheme.onSurface
                              .withValues(alpha: 0.4))),
                  const SizedBox(height: 8),
                  TextButton(
                    onPressed: () => _showNewChatSheet(context, ref),
                    child: const Text('开始新对话'),
                  ),
                ],
              ),
            )
          : ListView.builder(
              itemCount: totalItems,
              itemBuilder: (context, index) {
                int cursor = 0;

                if (hasGroups) {
                  if (index == cursor) return _buildSectionHeader('群聊', theme);
                  cursor++;
                  if (index < cursor + groupItems.length) {
                    final item = groupItems[index - cursor];
                    final isLastGroup = index == cursor + groupItems.length - 1;
                    return Column(mainAxisSize: MainAxisSize.min, children: [
                      _buildGroupTile(context, item, theme),
                      if (!isLastGroup || hasPrivate)
                        Divider(height: 1, indent: 76,
                            color: theme.colorScheme.outlineVariant.withValues(alpha: 0.3)),
                    ]);
                  }
                  cursor += groupItems.length;
                }

                if (hasPrivate) {
                  if (index == cursor) return _buildSectionHeader('单聊', theme);
                  cursor++;
                  if (index < cursor + privateItems.length) {
                    final item = privateItems[index - cursor];
                    final isLastPrivate = index == cursor + privateItems.length - 1;
                    return Column(mainAxisSize: MainAxisSize.min, children: [
                      _buildPrivateTile(context, item, notifier, theme),
                      if (!isLastPrivate)
                        Divider(height: 1, indent: 76,
                            color: theme.colorScheme.outlineVariant.withValues(alpha: 0.3)),
                    ]);
                  }
                }

                return const SizedBox.shrink();
              },
            ),
    );
  }

  Widget _buildSectionHeader(String title, ThemeData theme) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
      child: Text(title,
          style: theme.textTheme.labelMedium?.copyWith(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
              fontWeight: FontWeight.w600)),
    );
  }

  Widget _buildPrivateTile(BuildContext context, _PrivateChatItem item,
      notifier, ThemeData theme) {
    final color = _parseColor(item.role.color);
    return ListTile(
      contentPadding:
          const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      leading: CircleAvatar(
        radius: 24,
        backgroundColor: color.withValues(alpha: 0.15),
        child: Text(item.role.icon, style: const TextStyle(fontSize: 26)),
      ),
      title: Row(
        children: [
          Expanded(
            child: Text(item.role.name,
                style: theme.textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.w600)),
          ),
          Text(_formatTime(item.lastTime),
              style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.4))),
        ],
      ),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Text(item.lastMessage,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.5))),
      ),
      onTap: () {
        notifier.switchRole(item.role.id);
        Navigator.push(
          context,
          MaterialPageRoute(
              builder: (_) => ChatDetailScreen(role: item.role)),
        );
      },
    );
  }

  Widget _buildGroupTile(
      BuildContext context, _GroupChatItem item, ThemeData theme) {
    return ListTile(
      contentPadding:
          const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      leading: SizedBox(
        width: 48,
        height: 48,
        child: _MiniGroupAvatar(roles: item.roles),
      ),
      title: Row(
        children: [
          Expanded(
            child: Row(
              children: [
                Flexible(
                  child: Text(item.group.name,
                      overflow: TextOverflow.ellipsis,
                      maxLines: 1,
                      style: theme.textTheme.titleMedium
                          ?.copyWith(fontWeight: FontWeight.w600)),
                ),
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 5, vertical: 1),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.secondaryContainer,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text('${item.roles.length}',
                      style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onSecondaryContainer)),
                ),
              ],
            ),
          ),
          Text(_formatTime(item.lastTime),
              style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.4))),
        ],
      ),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Text(item.lastMessage,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.5))),
      ),
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(
              builder: (_) => GroupChatScreen(group: item.group)),
        );
      },
    );
  }

  void _showNewChatSheet(BuildContext context, WidgetRef ref) {
    final appState = ref.read(appStateProvider);
    final notifier = ref.read(appStateProvider.notifier);
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.6,
        maxChildSize: 0.9,
        builder: (context, scrollController) => Column(
          children: [
            const SizedBox(height: 12),
            Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.outlineVariant,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 16),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('选择角色开始聊天',
                    style: Theme.of(context)
                        .textTheme
                        .titleMedium
                        ?.copyWith(fontWeight: FontWeight.bold)),
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: ListView(
                controller: scrollController,
                children: appState.roles.map((role) {
                  final color = _parseColor(role.color);
                  return ListTile(
                    leading: CircleAvatar(
                      backgroundColor: color.withValues(alpha: 0.15),
                      child: Text(role.icon,
                          style: const TextStyle(fontSize: 22)),
                    ),
                    title: Text(role.name),
                    subtitle: Text(role.description),
                    onTap: () {
                      Navigator.pop(context);
                      notifier.switchRole(role.id);
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                            builder: (_) => ChatDetailScreen(role: role)),
                      );
                    },
                  );
                }).toList(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---- Mini group avatar for list ----
class _MiniGroupAvatar extends StatelessWidget {
  final List<Role> roles;

  const _MiniGroupAvatar({required this.roles});

  @override
  Widget build(BuildContext context) {
    final display = roles.take(4).toList();
    return GridView.count(
      crossAxisCount: 2,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 2,
      crossAxisSpacing: 2,
      children: display.map((role) {
        final color = _parseColor(role.color);
        return Container(
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(3),
          ),
          child: Center(
            child: Text(role.icon, style: const TextStyle(fontSize: 10)),
          ),
        );
      }).toList(),
    );
  }
}

// ---- Data classes ----
abstract class _ListItem {
  int get lastTime;
  String get lastMessage;
}

class _PrivateChatItem extends _ListItem {
  final Role role;
  @override final String lastMessage;
  @override final int lastTime;

  _PrivateChatItem({
    required this.role,
    required this.lastMessage,
    required this.lastTime,
  });
}

class _GroupChatItem extends _ListItem {
  final Group group;
  final List<Role> roles;
  @override final String lastMessage;
  @override final int lastTime;

  _GroupChatItem({
    required this.group,
    required this.roles,
    required this.lastMessage,
    required this.lastTime,
  });
}
