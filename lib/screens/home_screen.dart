import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/app_state_provider.dart';
import '../widgets/message_bubble.dart';
import '../widgets/role_selector_sheet.dart';
import '../widgets/role_chip.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
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

  void _onTextChanged(String text) {
    if (text.endsWith('@') || text.endsWith('＠')) {
      _showRoleSelector();
    }
  }

  void _showRoleSelector() {
    final appState = ref.read(appStateProvider);
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) => RoleSelectorSheet(
        roles: appState.roles,
        currentRoleId: appState.currentRoleId,
        onSelect: (role) {
          ref.read(appStateProvider.notifier).switchRole(role.id);
          // Clear input and set @roleName prefix
          _controller.text = '@${role.name} ';
          _controller.selection = TextSelection.collapsed(
            offset: _controller.text.length,
          );
          Navigator.pop(context);
          _focusNode.requestFocus();
        },
      ),
    );
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

    // Scroll again after AI response arrives
    Future.delayed(const Duration(milliseconds: 500), _scrollToBottom);
  }

  void _onAskButler(String selectedText) {
    final question = '请解释一下：$selectedText';
    ref.read(appStateProvider.notifier).sendMessage(question);
    _scrollToBottom();
    Future.delayed(const Duration(milliseconds: 500), _scrollToBottom);
  }

  void _showModelSwitcher() {
    final appState = ref.read(appStateProvider);
    // If no model configured, show hint
    if (appState.currentModel.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先在设置中连接本地模型服务')),
      );
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('当前模型：${appState.currentModel}')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final appState = ref.watch(appStateProvider);
    final messages = appState.allMessages;
    final currentRole = appState.currentRole;
    final theme = Theme.of(context);

    _scrollToBottom();

    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            Text('Butler',
                style: theme.textTheme.titleLarge
                    ?.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(width: 8),
            RoleChip(role: currentRole, selected: true),
          ],
        ),
        actions: [
          TextButton.icon(
            onPressed: _showModelSwitcher,
            icon: const Icon(Icons.smart_toy_outlined, size: 18),
            label: Text(
              appState.currentModel.isEmpty ? '未连接' : appState.currentModel,
              style: theme.textTheme.labelSmall,
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: messages.isEmpty
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(currentRole.icon,
                            style: const TextStyle(fontSize: 48)),
                        const SizedBox(height: 12),
                        Text('开始和你的助理们对话吧',
                            style: theme.textTheme.bodyLarge?.copyWith(
                                color: theme.colorScheme.onSurface
                                    .withValues(alpha: 0.5))),
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
                        return ThinkingBubble(role: currentRole);
                      }
                      final msg = messages[index];
                      final msgRole = appState.getRoleById(msg.roleId) ?? currentRole;
                      return MessageBubble(
                        message: msg,
                        role: msgRole,
                        onAskButler: _onAskButler,
                      );
                    },
                  ),
          ),
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
                    color: theme.colorScheme.outlineVariant.withValues(alpha: 0.3)),
              ),
            ),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _controller,
                    focusNode: _focusNode,
                    onChanged: _onTextChanged,
                    onSubmitted: (_) => _sendMessage(),
                    textInputAction: TextInputAction.send,
                    decoration: InputDecoration(
                      hintText: '输入或 @ 切换角色…',
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
                          child:
                              CircularProgressIndicator(strokeWidth: 2),
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
}
