import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/app_state.dart';
import '../providers/app_state_provider.dart';
import '../theme/design_tokens.dart';
import 'memory_screen.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  late TextEditingController _nameController;

  @override
  void initState() {
    super.initState();
    _nameController =
        TextEditingController(text: ref.read(appStateProvider).userName);
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final appState = ref.watch(appStateProvider);
    final notifier = ref.read(appStateProvider.notifier);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.md,
          AppSpacing.xs,
          AppSpacing.md,
          AppSpacing.xxxl,
        ),
        children: [
          _Section(
            title: '个人信息',
            children: [
              _Field(
                label: '姓名',
                child: TextField(
                  controller: _nameController,
                  decoration: const InputDecoration(),
                  onChanged: (val) => notifier.updateUserName(val),
                ),
              ),
              _Field(
                label: '偏好语言',
                child: SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: '中文', label: Text('中文')),
                    ButtonSegment(value: 'English', label: Text('English')),
                  ],
                  selected: {appState.preferredLanguage},
                  onSelectionChanged: (val) =>
                      notifier.updateLanguage(val.first),
                ),
              ),
            ],
          ),
          _Section(
            title: '扩展工具',
            subtitle: '日历等外部工具由 MCP 服务提供',
            children: [
              SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                title: const Text('启用 MCP 工具服务'),
                subtitle: Text(switch (appState.mcpState) {
                  McpConnectionState.connected => '已连接',
                  McpConnectionState.connecting => '连接中…',
                  McpConnectionState.error => '连接失败，对话仍可用（无外部工具）',
                  McpConnectionState.disconnected =>
                    appState.mcpEnabled ? '未连接' : '已关闭，对话不使用外部工具',
                }),
                value: appState.mcpEnabled,
                onChanged: (v) => notifier.setMcpEnabled(v),
              ),
            ],
          ),
          _Section(
            title: '提醒',
            subtitle: '日程到点会在对应角色聊天 + 系统通知里出现',
            children: [
              SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                title: const Text('锁屏显示提醒详情'),
                subtitle: const Text(
                    '关闭后锁屏只显示"角色 · 1 条提醒"，详情进 App 才看。下次调度生效。'),
                value: appState.showReminderDetailsOnLockScreen,
                onChanged: notifier.updateShowReminderDetailsOnLockScreen,
              ),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: () async {
                    final ok = await notifier.requestNotificationPermissions();
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                          content: Text(ok ? '通知权限已就绪' : '通知权限被拒绝')),
                    );
                  },
                  icon: const Icon(Icons.notifications_active_outlined, size: 18),
                  label: const Text('检查 / 请求通知权限'),
                ),
              ),
            ],
          ),
          _Section(
            title: '记忆管理',
            children: [
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) => const MemoryScreen()),
                    );
                  },
                  icon: const Icon(Icons.psychology_outlined, size: 18),
                  label: const Text('查看 / 编辑记忆'),
                ),
              ),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: () async {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('正在归纳，可能需要一会儿')),
                    );
                    await notifier.runMemorySummaryNow();
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('记忆归纳完成')),
                    );
                  },
                  icon: const Icon(Icons.auto_awesome_outlined, size: 18),
                  label: const Text('立即归纳记忆'),
                ),
              ),
              SizedBox(
                width: double.infinity,
                child: FilledButton.tonal(
                  onPressed: () {
                    showDialog(
                      context: context,
                      builder: (ctx) => AlertDialog(
                        title: const Text('确认清除'),
                        content: const Text('确定要清除所有记忆吗？此操作不可撤销。'),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(ctx),
                            child: const Text('取消'),
                          ),
                          FilledButton(
                            onPressed: () {
                              notifier.clearAllMemories();
                              Navigator.pop(ctx);
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('所有记忆已清除')),
                              );
                            },
                            style: FilledButton.styleFrom(
                              backgroundColor: theme.colorScheme.error,
                            ),
                            child: const Text('确认清除'),
                          ),
                        ],
                      ),
                    );
                  },
                  style: FilledButton.styleFrom(
                    backgroundColor: theme.colorScheme.errorContainer,
                    foregroundColor: theme.colorScheme.onErrorContainer,
                  ),
                  child: const Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.delete_forever_outlined, size: 18),
                      SizedBox(width: 8),
                      Text('清除全部记忆'),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  final String title;
  final String? subtitle;
  final List<Widget> children;
  const _Section(
      {required this.title, this.subtitle, required this.children});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
                4, AppSpacing.md, 4, AppSpacing.xs),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  title,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.4,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const Spacer(),
                if (subtitle != null)
                  Text(
                    subtitle!,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant
                          .withValues(alpha: 0.7),
                    ),
                  ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.all(AppSpacing.md),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerLow,
              borderRadius: BorderRadius.circular(AppRadius.lg),
            ),
            child: Column(
              children: [
                for (var i = 0; i < children.length; i++) ...[
                  if (i > 0) const SizedBox(height: AppSpacing.sm),
                  children[i],
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Field extends StatelessWidget {
  final String label;
  final Widget child;
  const _Field({required this.label, required this.child});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 2, bottom: 6),
          child: Text(label,
              style: theme.textTheme.labelMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w500)),
        ),
        child,
      ],
    );
  }
}


