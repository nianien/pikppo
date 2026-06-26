import 'package:flutter/material.dart';
import '../models/message.dart';
import '../models/role.dart';
import '../theme/design_tokens.dart';
import 'message_bubble.dart';

/// 私聊 / 群聊共用的消息列表——统一渲染：跨天分隔条、气泡、末尾"思考中/工具中"
/// 气泡、多选勾选、失败重试。两屏差异通过参数注入（[thinkingBubble] 用哪种、
/// [roleForMessage] 怎么解析发言人、[emptyState] 空态长啥样）。
///
/// 调用方负责：滚动控制（[scrollController]）、消息过滤（如剔除旧 tool_status）、
/// 多选状态（[selectionMode]/[selectedIds]）、各回调的具体落点。
class ChatMessageList extends StatelessWidget {
  final ScrollController scrollController;

  /// 已过滤、已按时间升序的可见消息。
  final List<Message> messages;
  final bool isLoading;

  /// 末尾"思考中"气泡——私聊传带工具状态的 [ThinkingBubble]，群聊传群头像版本。
  final Widget thinkingBubble;

  /// 解析某条消息渲染用的角色。群聊里未知角色返回 null → 该条跳过渲染。
  final Role? Function(Message) roleForMessage;

  /// 没有任何消息时展示的空态。
  final Widget emptyState;

  // ---- 多选 ----
  final bool selectionMode;
  final Set<String> selectedIds;
  final void Function(String id) onToggleSelect;
  final void Function(Message seed) onEnterSelection;

  // ---- 失败重试 ----
  /// 点击某条 error 气泡的"重试"——回传那条消息（群聊需要它的 roleId/groupId）。
  final void Function(Message errorMsg) onRetry;

  const ChatMessageList({
    super.key,
    required this.scrollController,
    required this.messages,
    required this.isLoading,
    required this.thinkingBubble,
    required this.roleForMessage,
    required this.emptyState,
    required this.selectionMode,
    required this.selectedIds,
    required this.onToggleSelect,
    required this.onEnterSelection,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    if (messages.isEmpty) return emptyState;

    return ListView.builder(
      controller: scrollController,
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
      itemCount: messages.length + (isLoading ? 1 : 0),
      itemBuilder: (context, index) {
        if (index == messages.length && isLoading) {
          return thinkingBubble;
        }
        final msg = messages[index];
        final role = roleForMessage(msg);
        if (role == null) return const SizedBox.shrink();

        final prev = index == 0 ? null : messages[index - 1];
        final showSeparator =
            MessageTimeSeparator.shouldInsertBefore(msg, prev);

        final bubble = MessageBubble(
          message: msg,
          role: role,
          selectionMode: selectionMode,
          selected: selectedIds.contains(msg.id),
          onSelectToggle: () => onToggleSelect(msg.id),
          onEnterSelection: onEnterSelection,
          onRetry: msg.kind == 'error' ? () => onRetry(msg) : null,
        );
        if (!showSeparator) return bubble;
        return Column(
          children: [
            MessageTimeSeparator(timestamp: msg.timestamp),
            bubble,
          ],
        );
      },
    );
  }
}
