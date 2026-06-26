import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/group.dart';
import '../models/role.dart';
import '../providers/app_state_provider.dart';
import '../utils/color_hex.dart';
import '../widgets/chat_input_buttons.dart';
import '../widgets/chat_message_list.dart';
import '../widgets/info_banner.dart';
import '../widgets/model_switcher_sheet.dart';
import 'chat_selection_mixin.dart';

class GroupChatScreen extends ConsumerStatefulWidget {
  final Group group;

  const GroupChatScreen({super.key, required this.group});

  @override
  ConsumerState<GroupChatScreen> createState() => _GroupChatScreenState();
}

class _GroupChatScreenState extends ConsumerState<GroupChatScreen>
    with ChatSelectionMixin {
  final _controller = TextEditingController();
  final _scrollController = ScrollController();
  final _focusNode = FocusNode();
  bool _showMentionList = false;

  @override
  void initState() {
    super.initState();
    // 懒加载：进入群聊页拉首屏（最新 N 条）。幂等。
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await ref
          .read(appStateProvider.notifier)
          .ensureGroupMessagesLoaded(widget.group.id);
      if (!mounted) return;
      if (_scrollController.hasClients) {
        _scrollController.jumpTo(
            _scrollController.position.maxScrollExtent);
      }
    });
    _scrollController.addListener(_maybeLoadOlder);
  }

  static const _kLoadMoreThreshold = 240.0;
  bool _loadingMoreOlder = false;

  /// 向上接近顶部时分页加载；用 maxScrollExtent 增量补偿像素位置避免视觉跳动。
  void _maybeLoadOlder() {
    if (_loadingMoreOlder) return;
    if (!_scrollController.hasClients) return;
    final pos = _scrollController.position;
    if (pos.pixels - pos.minScrollExtent >= _kLoadMoreThreshold) return;
    _loadingMoreOlder = true;
    final oldMax = pos.maxScrollExtent;
    ref
        .read(appStateProvider.notifier)
        .loadMoreGroupMessages(widget.group.id)
        .then((loaded) {
      _loadingMoreOlder = false;
      if (!loaded || !mounted) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_scrollController.hasClients) return;
        final delta = _scrollController.position.maxScrollExtent - oldMax;
        if (delta > 0) {
          _scrollController.jumpTo(_scrollController.position.pixels + delta);
        }
      });
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _scrollController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  /// Find last '@' or '＠' (fullwidth) index before cursor
  int _lastAtIndex(String text) {
    final half = text.lastIndexOf('@');
    final full = text.lastIndexOf('＠');
    return half > full ? half : full;
  }

  void _onTextChanged(String text) {
    if (text.isEmpty) {
      if (_showMentionList) setState(() => _showMentionList = false);
      return;
    }
    int cursor = text.length;
    final selection = _controller.selection;
    if (selection.isValid && selection.baseOffset > 0) {
      cursor = selection.baseOffset;
    }
    final before = text.substring(0, cursor);
    final atIndex = _lastAtIndex(before);
    if (atIndex == -1) {
      if (_showMentionList) setState(() => _showMentionList = false);
      return;
    }
    // '@' must be at start or preceded by a space
    if (atIndex > 0 && before[atIndex - 1] != ' ' && before[atIndex - 1] != '\u3000') {
      if (_showMentionList) setState(() => _showMentionList = false);
      return;
    }
    // Text between '@' and cursor should have no spaces (still typing the mention)
    final mentionQuery = before.substring(atIndex + 1);
    if (mentionQuery.contains(' ') || mentionQuery.contains('\u3000')) {
      if (_showMentionList) setState(() => _showMentionList = false);
      return;
    }
    if (!_showMentionList) setState(() => _showMentionList = true);
  }

  void _insertMention(Role role) {
    final text = _controller.text;
    int cursor = text.length;
    final sel = _controller.selection;
    if (sel.isValid && sel.baseOffset > 0) cursor = sel.baseOffset;
    final before = text.substring(0, cursor);
    final atIndex = _lastAtIndex(before);
    if (atIndex == -1) return;
    final after = text.substring(cursor);
    final newText = '${text.substring(0, atIndex)}@${role.name} $after';
    _controller.text = newText;
    final newCursor = atIndex + role.name.length + 2; // @name + space
    _controller.selection = TextSelection.collapsed(offset: newCursor);
    setState(() => _showMentionList = false);
    _focusNode.requestFocus();
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
    if (appState.loadingGroupId == widget.group.id) return;

    ref
        .read(appStateProvider.notifier)
        .sendGroupMessage(widget.group.id, text);
    _controller.clear();
    _focusNode.requestFocus();
    _scrollToBottom();
    Future.delayed(const Duration(milliseconds: 500), _scrollToBottom);
  }

  @override
  Widget build(BuildContext context) {
    final appState = ref.watch(appStateProvider);
    // 与私聊一致：剔除旧版本残留的 tool_status 气泡（群聊不跑 agent，正常不会有）。
    final messages = appState
        .groupMessages(widget.group.id)
        .where((m) => m.kind != 'tool_status')
        .toList();
    final isLoading = appState.loadingGroupId == widget.group.id;
    final theme = Theme.of(context);

    // Get current group (may have been updated)
    final group = appState.getGroupById(widget.group.id) ?? widget.group;
    final roles = group.roleIds
        .map((id) => appState.getRoleById(id))
        .whereType<Role>()
        .toList();

    // 新消息进来才滚到底；用户回看历史时不打扰。
    ref.listen<int>(
      appStateProvider.select((s) =>
          s.messages.where((m) => m.groupId == widget.group.id).length),
      (prev, next) {
        if (prev != null && next > prev) _scrollToBottom();
      },
    );

    return Scaffold(
      appBar: selectionMode
          ? buildSelectionAppBar(context)
          : AppBar(
        title: Row(
          children: [
            _GroupAvatar(roles: roles, size: 36),
            const SizedBox(width: 10),
            Expanded(
              child: InkWell(
                onTap: () => showModelSwitcherSheet(context, ref),
                borderRadius: BorderRadius.circular(8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(group.name,
                        overflow: TextOverflow.ellipsis,
                        maxLines: 1,
                        style: theme.textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w600)),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text('${roles.length}人',
                            style: theme.textTheme.labelSmall?.copyWith(
                                color: theme.colorScheme.onSurface
                                    .withValues(alpha: 0.4))),
                        const SizedBox(width: 6),
                        Flexible(
                            child:
                                ModelChip(model: appState.currentModel)),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.more_horiz),
            onPressed: () => _showGroupInfo(context, group, roles),
          ),
        ],
      ),
      body: Column(
        children: [
          if (appState.currentModel.isEmpty)
            const InfoBanner(
              message: '模型加载中…若长时间无响应，请检查网络后重启应用',
              icon: Icons.cloud_off_outlined,
            ),
          Expanded(
            child: ChatMessageList(
              scrollController: _scrollController,
              messages: messages,
              isLoading: isLoading,
              thinkingBubble: _GroupThinkingBubble(
                roles: roles,
                statusText: appState.toolStatus,
              ),
              // 用户气泡取群里任一成员占位；角色气泡按发言人 roleId 解析。
              roleForMessage: (msg) => msg.isUser
                  ? (roles.isNotEmpty ? roles.first : null)
                  : appState.getRoleById(msg.roleId),
              emptyState: _buildEmptyState(theme, roles),
              selectionMode: selectionMode,
              selectedIds: selectedIds,
              onToggleSelect: toggleSelect,
              onEnterSelection: (seed) => enterSelection(seed.id),
              onRetry: (m) => ref
                  .read(appStateProvider.notifier)
                  .retryGroupReply(m.groupId!, m.roleId, m.id),
            ),
          ),
          if (!selectionMode)
            _buildInputBar(context, appState, isLoading, theme, roles),
        ],
      ),
    );
  }

  Widget _buildEmptyState(ThemeData theme, List<Role> roles) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _GroupAvatar(roles: roles, size: 64),
          const SizedBox(height: 16),
          Text('群聊已创建',
              style: theme.textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          Text(
            roles.map((r) => r.name).join('、'),
            style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.4)),
          ),
          const SizedBox(height: 4),
          Text('发消息，所有成员都会回复',
              style: theme.textTheme.bodySmall?.copyWith(
                  color:
                      theme.colorScheme.onSurface.withValues(alpha: 0.3))),
        ],
      ),
    );
  }

  Widget _buildInputBar(BuildContext context, appState, bool isLoading,
      ThemeData theme, List<Role> roles) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // @ mention list
        if (_showMentionList)
          Container(
            constraints: const BoxConstraints(maxHeight: 200),
            decoration: BoxDecoration(
              color: theme.scaffoldBackgroundColor,
              border: Border(
                top: BorderSide(
                    color: theme.colorScheme.outlineVariant.withValues(alpha: 0.3)),
              ),
            ),
            child: ListView(
              shrinkWrap: true,
              padding: EdgeInsets.zero,
              children: roles.map((role) {
                final color = parseHexColor(role.color);
                return ListTile(
                  dense: true,
                  leading: CircleAvatar(
                    radius: 16,
                    backgroundColor: color.withValues(alpha: 0.15),
                    child: Text(role.icon, style: const TextStyle(fontSize: 16)),
                  ),
                  title: Text(role.name),
                  onTap: () => _insertMention(role),
                );
              }).toList(),
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
            color: theme.scaffoldBackgroundColor,
            border: Border(
              top: BorderSide(
                  color:
                      theme.colorScheme.outlineVariant.withValues(alpha: 0.3)),
            ),
          ),
          child: Row(
            children: [
              VoiceInputButton(controller: _controller),
              Expanded(
                child: TextField(
                  controller: _controller,
                  focusNode: _focusNode,
                  onChanged: _onTextChanged,
                  onSubmitted: (_) => _sendMessage(),
                  textInputAction: TextInputAction.send,
                  decoration: InputDecoration(
                    hintText: '发消息给群组，输入@提及...',
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
              AttachmentButton(groupId: widget.group.id),
              isLoading
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
    );
  }

  void _showGroupInfo(
      BuildContext context, Group group, List<Role> roles) {
    final theme = Theme.of(context);
    showModalBottomSheet(
      context: context,
      builder: (_) => Container(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _GroupAvatar(roles: roles, size: 56),
            const SizedBox(height: 12),
            Text(group.name,
                style: theme.textTheme.titleLarge
                    ?.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Text('${roles.length}个成员：${roles.map((r) => r.name).join("、")}',
                style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurface
                        .withValues(alpha: 0.5))),
            const SizedBox(height: 24),
            ListTile(
              leading: const Icon(Icons.delete_outline, color: Colors.red),
              title: const Text('清空聊天记录',
                  style: TextStyle(color: Colors.red)),
              onTap: () {
                Navigator.pop(context);
                ref
                    .read(appStateProvider.notifier)
                    .clearGroupMessages(group.id);
              },
            ),
            ListTile(
              leading:
                  const Icon(Icons.group_remove_outlined, color: Colors.red),
              title: const Text('解散群聊', style: TextStyle(color: Colors.red)),
              onTap: () {
                Navigator.pop(context);
                showDialog(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: const Text('确认解散'),
                    content: Text('确定解散「${group.name}」吗？'),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(ctx),
                        child: const Text('取消'),
                      ),
                      FilledButton(
                        onPressed: () {
                          ref
                              .read(appStateProvider.notifier)
                              .deleteGroup(group.id);
                          Navigator.pop(ctx);
                          Navigator.pop(context);
                        },
                        style: FilledButton.styleFrom(
                            backgroundColor:
                                Theme.of(context).colorScheme.error),
                        child: const Text('解散'),
                      ),
                    ],
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

// ---- Widgets ----

class _GroupAvatar extends StatelessWidget {
  final List<Role> roles;
  final double size;

  const _GroupAvatar({required this.roles, required this.size});

  @override
  Widget build(BuildContext context) {
    final display = roles.take(4).toList();

    return SizedBox(
      width: size,
      height: size,
      child: GridView.count(
        crossAxisCount: 2,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        mainAxisSpacing: 2,
        crossAxisSpacing: 2,
        children: display.map((role) {
          final color = parseHexColor(role.color);
          return Container(
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Center(
              child: Text(role.icon,
                  style: TextStyle(fontSize: size * 0.22)),
            ),
          );
        }).toList(),
      ),
    );
  }
}

class _GroupThinkingBubble extends StatefulWidget {
  final List<Role> roles;

  /// agent loop 工具执行期间的瞬时状态（如"正在调用工具：货币换算"）。
  /// null = 普通圆点动画。
  final String? statusText;

  const _GroupThinkingBubble({required this.roles, this.statusText});

  @override
  State<_GroupThinkingBubble> createState() => _GroupThinkingBubbleState();
}

class _GroupThinkingBubbleState extends State<_GroupThinkingBubble>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final role = widget.roles.isNotEmpty ? widget.roles.first : null;
    final color =
        role != null ? parseHexColor(role.color) : theme.colorScheme.primary;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            radius: 18,
            backgroundColor: color.withValues(alpha: 0.15),
            child: Text(role?.icon ?? '🤖',
                style: const TextStyle(fontSize: 18)),
          ),
          const SizedBox(width: 8),
          Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(4),
                topRight: Radius.circular(16),
                bottomLeft: Radius.circular(16),
                bottomRight: Radius.circular(16),
              ),
            ),
            child: widget.statusText != null
                ? Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: theme.colorScheme.onSurface
                              .withValues(alpha: 0.5),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        widget.statusText!,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurface
                              .withValues(alpha: 0.7),
                        ),
                      ),
                    ],
                  )
                : AnimatedBuilder(
              animation: _controller,
              builder: (context, _) {
                final dots =
                    '.' * ((_controller.value * 3).floor() % 3 + 1);
                return Text(
                  dots.padRight(3),
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                    letterSpacing: 4,
                    fontSize: 20,
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
