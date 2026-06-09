import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/role.dart';
import '../providers/app_state_provider.dart';
import '../theme/design_tokens.dart';
import '../utils/color_hex.dart';
import '../widgets/info_banner.dart';
import '../widgets/message_bubble.dart';
import 'settings_screen.dart';

class ChatDetailScreen extends ConsumerStatefulWidget {
  final Role role;
  const ChatDetailScreen({super.key, required this.role});

  @override
  ConsumerState<ChatDetailScreen> createState() => _ChatDetailScreenState();
}

class _ChatDetailScreenState extends ConsumerState<ChatDetailScreen> {
  final _controller = TextEditingController();
  final _scrollController = ScrollController();
  final _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    // 首次进入时把已有历史滚到底（不动画）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.jumpTo(
            _scrollController.position.maxScrollExtent);
      }
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _scrollController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOutCubic,
        );
      }
    });
  }

  void _sendMessage() {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    final appState = ref.read(appStateProvider);
    if (appState.isLoading) return;

    ref.read(appStateProvider.notifier).sendMessage(text);
    _controller.clear();
    _focusNode.requestFocus();
    _scrollToBottom();
    Future.delayed(const Duration(milliseconds: 500), _scrollToBottom);
  }

  void _onAskButler(String selectedText) {
    final question = '请解释一下：$selectedText';
    ref.read(appStateProvider.notifier).sendMessage(question);
    _scrollToBottom();
    Future.delayed(const Duration(milliseconds: 500), _scrollToBottom);
  }

  @override
  Widget build(BuildContext context) {
    final appState = ref.watch(appStateProvider);
    final messages = appState.currentRoleMessages;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final roleColor = parseHexColor(widget.role.color);

    // 新消息（自己发的或 AI 回的）才滚到底；用户主动往上滚回看历史时不打扰。
    ref.listen<int>(
      appStateProvider.select((s) => s.messages
          .where((m) =>
              m.roleId == widget.role.id && m.groupId == null)
          .length),
      (prev, next) {
        if (prev != null && next > prev) _scrollToBottom();
      },
    );

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: roleColor.withValues(alpha: 0.16),
                borderRadius: BorderRadius.circular(AppRadius.sm),
              ),
              alignment: Alignment.center,
              child: Text(widget.role.icon,
                  style: const TextStyle(fontSize: 18)),
            ),
            const SizedBox(width: AppSpacing.sm),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(widget.role.name,
                    style: theme.textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.w700)),
                if (appState.currentModel.isNotEmpty)
                  Text(
                    appState.currentModel,
                    style: theme.textTheme.labelSmall?.copyWith(
                        color: scheme.onSurfaceVariant
                            .withValues(alpha: 0.7)),
                  ),
              ],
            ),
          ],
        ),
        actions: [
          IconButton(
            onPressed: () => _showChatInfo(context),
            icon: const Icon(Icons.more_horiz),
          ),
          const SizedBox(width: AppSpacing.xs),
        ],
      ),
      body: Column(
        children: [
          if (appState.currentModel.isEmpty)
            InfoBanner(
              message: '请先在设置中配置并选择模型',
              actionLabel: '去设置',
              onAction: () => Navigator.push(
                context,
                MaterialPageRoute(
                    builder: (_) => const SettingsScreen()),
              ),
            ),
          Expanded(
            child: messages.isEmpty
                ? _ChatEmptyState(role: widget.role)
                : ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.symmetric(
                        vertical: AppSpacing.sm),
                    itemCount:
                        messages.length + (appState.isLoading ? 1 : 0),
                    itemBuilder: (context, index) {
                      if (index == messages.length && appState.isLoading) {
                        return ThinkingBubble(role: widget.role);
                      }
                      final msg = messages[index];
                      final prev = index == 0 ? null : messages[index - 1];
                      final showSeparator =
                          MessageTimeSeparator.shouldInsertBefore(msg, prev);
                      final bubble = MessageBubble(
                        message: msg,
                        role: widget.role,
                        onAskButler: _onAskButler,
                      );
                      if (!showSeparator) return bubble;
                      return Column(
                        children: [
                          MessageTimeSeparator(timestamp: msg.timestamp),
                          bubble,
                        ],
                      );
                    },
                  ),
          ),
          _InputBar(
            controller: _controller,
            focusNode: _focusNode,
            isLoading: appState.isLoading,
            onSend: _sendMessage,
          ),
        ],
      ),
    );
  }

  void _showChatInfo(BuildContext context) {
    final theme = Theme.of(context);
    final roleColor = parseHexColor(widget.role.color);
    showModalBottomSheet(
      context: context,
      builder: (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
              AppSpacing.xl, 0, AppSpacing.xl, AppSpacing.xl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 80,
                height: 80,
                decoration: BoxDecoration(
                  color: roleColor.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(AppRadius.lg),
                ),
                alignment: Alignment.center,
                child: Text(widget.role.icon,
                    style: const TextStyle(fontSize: 40)),
              ),
              const SizedBox(height: AppSpacing.md),
              Text(widget.role.name, style: theme.textTheme.titleLarge),
              const SizedBox(height: AppSpacing.xxs),
              Text(
                widget.role.description,
                style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: AppSpacing.xl),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: theme.colorScheme.error,
                    side: BorderSide(
                        color: theme.colorScheme.error
                            .withValues(alpha: 0.4)),
                  ),
                  onPressed: () {
                    Navigator.pop(context);
                    _confirmClearChat(context);
                  },
                  icon: const Icon(Icons.delete_outline),
                  label: const Text('清空聊天记录'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _confirmClearChat(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认清空'),
        content: Text('确定清空与${widget.role.name}的聊天记录吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              ref
                  .read(appStateProvider.notifier)
                  .clearMessagesForRole(widget.role.id);
              Navigator.pop(ctx);
            },
            style: FilledButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.error),
            child: const Text('确认清空'),
          ),
        ],
      ),
    );
  }
}

class _InputBar extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final bool isLoading;
  final VoidCallback onSend;

  const _InputBar({
    required this.controller,
    required this.focusNode,
    required this.isLoading,
    required this.onSend,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      padding: EdgeInsets.fromLTRB(
        AppSpacing.sm,
        AppSpacing.xs,
        AppSpacing.xs,
        MediaQuery.of(context).padding.bottom + AppSpacing.xs,
      ),
      decoration: BoxDecoration(
        color: theme.scaffoldBackgroundColor,
        border: Border(
          top: BorderSide(
            color: scheme.outlineVariant.withValues(alpha: 0.4),
            width: 0.6,
          ),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(AppRadius.xl),
              ),
              child: TextField(
                controller: controller,
                focusNode: focusNode,
                onSubmitted: (_) => onSend(),
                textInputAction: TextInputAction.send,
                minLines: 1,
                maxLines: 5,
                style: theme.textTheme.bodyLarge,
                decoration: const InputDecoration(
                  hintText: '说点什么…',
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  filled: false,
                  contentPadding: EdgeInsets.symmetric(
                      horizontal: AppSpacing.md,
                      vertical: AppSpacing.sm + 2),
                ),
              ),
            ),
          ),
          const SizedBox(width: AppSpacing.xs),
          AnimatedSwitcher(
            duration: AppDurations.fast,
            child: isLoading
                ? Padding(
                    key: const ValueKey('loading'),
                    padding: const EdgeInsets.all(AppSpacing.xs),
                    child: SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.4,
                        color: scheme.primary,
                      ),
                    ),
                  )
                // 圆形 Send 键：跟 FAB 同一套色（scheme.primary = brand 春绿）。
                : Material(
                    key: const ValueKey('send'),
                    color: scheme.primary,
                    shape: const CircleBorder(),
                    child: InkWell(
                      onTap: onSend,
                      customBorder: const CircleBorder(),
                      child: SizedBox(
                        width: 40,
                        height: 40,
                        child: Icon(Icons.arrow_upward_rounded,
                            color: scheme.onPrimary, size: 22),
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

class _ChatEmptyState extends StatelessWidget {
  final Role role;
  const _ChatEmptyState({required this.role});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final color = parseHexColor(role.color);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 96,
            height: 96,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  color.withValues(alpha: 0.22),
                  color.withValues(alpha: 0.10),
                ],
              ),
              borderRadius: BorderRadius.circular(AppRadius.xl),
            ),
            alignment: Alignment.center,
            child: Text(role.icon, style: const TextStyle(fontSize: 48)),
          ),
          const SizedBox(height: AppSpacing.lg),
          Text(role.name, style: theme.textTheme.titleLarge),
          const SizedBox(height: AppSpacing.xxs),
          Text(
            role.description,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          Text(
            '发送一条消息开始对话',
            style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant.withValues(alpha: 0.6)),
          ),
        ],
      ),
    );
  }
}
