import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/app_state_provider.dart';
import '../models/conversation_summary.dart';
import '../models/role.dart';
import '../models/group.dart';
import '../theme/design_tokens.dart';
import '../utils/color_hex.dart';
import 'chat_detail_screen.dart';
import 'group_chat_screen.dart';

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

    // 用启动时一次性预加载的会话摘要——避免迭代 state.messages 全表。
    final summaries = appState.conversationSummaries;

    final groupItems = <_GroupChatItem>[];
    for (final group in appState.groups) {
      final summary =
          summaries[ConversationSummary.keyForGroup(group.id)];
      groupItems.add(_GroupChatItem(
        group: group,
        lastMessage: summary?.lastContent ?? '群聊已创建',
        lastTime: summary?.lastTimestamp ?? 0,
        roles: group.roleIds
            .map((id) => appState.getRoleById(id))
            .whereType<Role>()
            .toList(),
      ));
    }
    groupItems.sort((a, b) => b.lastTime.compareTo(a.lastTime));

    final privateItems = <_PrivateChatItem>[];
    for (final role in appState.roles) {
      final summary =
          summaries[ConversationSummary.keyForRole(role.id)];
      if (summary == null) continue;
      privateItems.add(_PrivateChatItem(
        role: role,
        lastMessage: summary.lastContent,
        lastTime: summary.lastTimestamp,
      ));
    }
    privateItems.sort((a, b) => b.lastTime.compareTo(a.lastTime));

    final isEmpty = groupItems.isEmpty && privateItems.isEmpty;

    return Scaffold(
      appBar: AppBar(
        title: const Text('聊天'),
        actions: [
          IconButton(
            onPressed: () => _showNewChatSheet(context, ref),
            icon: const Icon(Icons.add_comment_outlined),
            tooltip: '发起聊天',
          ),
          const SizedBox(width: AppSpacing.xs),
        ],
      ),
      body: isEmpty
          ? _EmptyState(onStart: () => _showNewChatSheet(context, ref))
          : ListView(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.md,
                AppSpacing.xs,
                AppSpacing.md,
                AppSpacing.xl,
              ),
              children: [
                if (groupItems.isNotEmpty) ...[
                  _SectionLabel(label: '群聊', count: groupItems.length),
                  const SizedBox(height: AppSpacing.xs),
                  ...groupItems.map((item) => _ChatCard(
                        leading: _MiniGroupAvatar(roles: item.roles),
                        title: item.group.name,
                        trailingChip: '${item.roles.length} 人',
                        time: _formatTime(item.lastTime),
                        subtitle: item.lastMessage,
                        onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) =>
                                GroupChatScreen(group: item.group),
                          ),
                        ),
                      )),
                  const SizedBox(height: AppSpacing.lg),
                ],
                if (privateItems.isNotEmpty) ...[
                  _SectionLabel(label: '单聊', count: privateItems.length),
                  const SizedBox(height: AppSpacing.xs),
                  ...privateItems.map((item) {
                    final color = parseHexColor(item.role.color);
                    return _ChatCard(
                      leading: _RoleAvatar(
                          color: color, icon: item.role.icon),
                      title: item.role.name,
                      time: _formatTime(item.lastTime),
                      subtitle: item.lastMessage,
                      accent: color,
                      onTap: () {
                        ref
                            .read(appStateProvider.notifier)
                            .switchRole(item.role.id);
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) =>
                                ChatDetailScreen(role: item.role),
                          ),
                        );
                      },
                    );
                  }),
                ],
              ],
            ),
      floatingActionButton: !isEmpty
          ? FloatingActionButton(
              onPressed: () => _showNewChatSheet(context, ref),
              child: const Icon(Icons.edit_outlined),
            )
          : null,
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
        builder: (context, scrollController) {
          final theme = Theme.of(context);
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
            child: Column(
              children: [
                const SizedBox(height: AppSpacing.md),
                Text(
                  '选择角色开始聊天',
                  style: theme.textTheme.titleLarge,
                ),
                const SizedBox(height: AppSpacing.sm),
                Expanded(
                  child: ListView.separated(
                    controller: scrollController,
                    padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
                    itemCount: appState.roles.length,
                    separatorBuilder: (_, _) =>
                        const SizedBox(height: AppSpacing.xs),
                    itemBuilder: (_, i) {
                      final role = appState.roles[i];
                      final color = parseHexColor(role.color);
                      return _ChatCard(
                        leading: _RoleAvatar(color: color, icon: role.icon),
                        title: role.name,
                        time: '',
                        subtitle: role.description,
                        accent: color,
                        onTap: () {
                          Navigator.pop(context);
                          notifier.switchRole(role.id);
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) =>
                                  ChatDetailScreen(role: role),
                            ),
                          );
                        },
                      );
                    },
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String label;
  final int count;
  const _SectionLabel({required this.label, required this.count});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, AppSpacing.sm, 4, AppSpacing.xs),
      child: Row(
        children: [
          Text(
            label,
            style: theme.textTheme.labelLarge?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.4,
            ),
          ),
          const SizedBox(width: AppSpacing.xs),
          Text(
            count.toString(),
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant
                  .withValues(alpha: 0.6),
            ),
          ),
        ],
      ),
    );
  }
}

class _ChatCard extends StatelessWidget {
  final Widget leading;
  final String title;
  final String time;
  final String? trailingChip;
  final String subtitle;
  final Color? accent;
  final VoidCallback onTap;

  const _ChatCard({
    required this.leading,
    required this.title,
    required this.time,
    this.trailingChip,
    required this.subtitle,
    this.accent,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.xs),
      child: Material(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(AppRadius.lg),
          child: Padding(
            padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.md, vertical: AppSpacing.sm + 2),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                leading,
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.titleMedium?.copyWith(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          if (trailingChip != null) ...[
                            const SizedBox(width: AppSpacing.xs),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 2),
                              decoration: BoxDecoration(
                                color: scheme.secondaryContainer,
                                borderRadius:
                                    BorderRadius.circular(AppRadius.pill),
                              ),
                              child: Text(
                                trailingChip!,
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: scheme.onSecondaryContainer,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ],
                          const Spacer(),
                          if (time.isNotEmpty)
                            Text(
                              time,
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: scheme.onSurfaceVariant
                                    .withValues(alpha: 0.7),
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
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

class _RoleAvatar extends StatelessWidget {
  final Color color;
  final String icon;
  const _RoleAvatar({required this.color, required this.icon});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 48,
      height: 48,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            color.withValues(alpha: 0.22),
            color.withValues(alpha: 0.10),
          ],
        ),
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(
          color: color.withValues(alpha: 0.28),
          width: 0.5,
        ),
      ),
      alignment: Alignment.center,
      child: Text(icon, style: const TextStyle(fontSize: 24)),
    );
  }
}

class _MiniGroupAvatar extends StatelessWidget {
  final List<Role> roles;
  const _MiniGroupAvatar({required this.roles});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final display = roles.take(4).toList();
    return Container(
      width: 48,
      height: 48,
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      child: GridView.count(
        crossAxisCount: 2,
        mainAxisSpacing: 2,
        crossAxisSpacing: 2,
        physics: const NeverScrollableScrollPhysics(),
        children: display.map((role) {
          final color = parseHexColor(role.color);
          return Container(
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.18),
              borderRadius: BorderRadius.circular(AppRadius.xs / 2),
            ),
            alignment: Alignment.center,
            child: Text(role.icon, style: const TextStyle(fontSize: 12)),
          );
        }).toList(),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  final VoidCallback onStart;
  const _EmptyState({required this.onStart});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 96,
            height: 96,
            decoration: BoxDecoration(
              color: scheme.primaryContainer.withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(AppRadius.xl),
            ),
            alignment: Alignment.center,
            child: Icon(
              Icons.chat_bubble_outline_rounded,
              size: 44,
              color: scheme.primary,
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          Text('还没有对话', style: theme.textTheme.titleLarge),
          const SizedBox(height: AppSpacing.xs),
          Text(
            '选一个角色，跟你的助理打个招呼吧',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          FilledButton.icon(
            onPressed: onStart,
            icon: const Icon(Icons.add),
            label: const Text('开始新对话'),
          ),
        ],
      ),
    );
  }
}

class _PrivateChatItem {
  final Role role;
  final String lastMessage;
  final int lastTime;
  _PrivateChatItem(
      {required this.role,
      required this.lastMessage,
      required this.lastTime});
}

class _GroupChatItem {
  final Group group;
  final List<Role> roles;
  final String lastMessage;
  final int lastTime;
  _GroupChatItem({
    required this.group,
    required this.roles,
    required this.lastMessage,
    required this.lastTime,
  });
}
