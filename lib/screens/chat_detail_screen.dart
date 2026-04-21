import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/role.dart';
import '../providers/app_state_provider.dart';
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
          curve: Curves.easeOut,
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
    _scrollToBottom();

    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            Text(widget.role.icon, style: const TextStyle(fontSize: 22)),
            const SizedBox(width: 8),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(widget.role.name,
                    style: theme.textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.w600)),
                if (appState.currentModel.isNotEmpty)
                  Text(appState.currentModel,
                      style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onSurface
                              .withValues(alpha: 0.4))),
              ],
            ),
          ],
        ),
        actions: [
          IconButton(
            onPressed: () => _showChatInfo(context),
            icon: const Icon(Icons.more_horiz),
          ),
        ],
      ),
      body: Column(
        children: [
          if (appState.currentModel.isEmpty)
            MaterialBanner(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              content: const Text('请先在设置中配置并选择模型'),
              actions: [
                TextButton(
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const SettingsScreen()),
                  ),
                  child: const Text('去设置'),
                ),
              ],
            ),
          Expanded(
            child: messages.isEmpty
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(widget.role.icon,
                            style: const TextStyle(fontSize: 48)),
                        const SizedBox(height: 12),
                        Text(widget.role.description,
                            style: theme.textTheme.bodyMedium?.copyWith(
                                color: theme.colorScheme.onSurface
                                    .withValues(alpha: 0.4))),
                        const SizedBox(height: 4),
                        Text('发送消息开始对话',
                            style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurface
                                    .withValues(alpha: 0.3))),
                      ],
                    ),
                  )
                : ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.only(top: 8, bottom: 8),
                    itemCount:
                        messages.length + (appState.isLoading ? 1 : 0),
                    itemBuilder: (context, index) {
                      if (index == messages.length && appState.isLoading) {
                        return ThinkingBubble(role: widget.role);
                      }
                      final msg = messages[index];
                      return MessageBubble(
                        message: msg,
                        role: widget.role,
                        onAskButler: _onAskButler,
                      );
                    },
                  ),
          ),
          // Input bar
          Container(
            padding: EdgeInsets.only(
              left: 12,
              right: 8,
              top: 8,
              bottom: MediaQuery.of(context).padding.bottom + 8,
            ),
            decoration: BoxDecoration(
              color: theme.colorScheme.surface,
              border: Border(
                top: BorderSide(
                    color:
                        theme.colorScheme.outlineVariant.withValues(alpha: 0.3)),
              ),
            ),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _controller,
                    focusNode: _focusNode,
                    onSubmitted: (_) => _sendMessage(),
                    textInputAction: TextInputAction.send,
                    decoration: InputDecoration(
                      hintText: '输入消息...',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(24),
                        borderSide: BorderSide.none,
                      ),
                      filled: true,
                      fillColor: theme.colorScheme.surfaceContainerHighest,
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 10),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                appState.isLoading
                    ? const SizedBox(
                        width: 40,
                        height: 40,
                        child: Padding(
                          padding: EdgeInsets.all(8),
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      )
                    : IconButton.filled(
                        onPressed: _sendMessage,
                        icon: const Icon(Icons.send_rounded),
                      ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _showChatInfo(BuildContext context) {
    final theme = Theme.of(context);
    showModalBottomSheet(
      context: context,
      builder: (_) => Container(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(widget.role.icon, style: const TextStyle(fontSize: 48)),
            const SizedBox(height: 12),
            Text(widget.role.name,
                style: theme.textTheme.titleLarge
                    ?.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Text(widget.role.description,
                style: theme.textTheme.bodyMedium?.copyWith(
                    color:
                        theme.colorScheme.onSurface.withValues(alpha: 0.5))),
            const SizedBox(height: 24),
            ListTile(
              leading: const Icon(Icons.delete_outline, color: Colors.red),
              title: const Text('清空聊天记录',
                  style: TextStyle(color: Colors.red)),
              onTap: () {
                Navigator.pop(context);
                _confirmClearChat(context);
              },
            ),
          ],
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
