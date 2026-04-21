import 'package:flutter/material.dart';
import '../models/message.dart';
import '../models/role.dart';

Color _parseColor(String hex) {
  return Color(int.parse(hex.replaceFirst('#', '0xFF')));
}

class MessageBubble extends StatelessWidget {
  final Message message;
  final Role role;
  final void Function(String selectedText)? onAskButler;

  const MessageBubble({
    super.key,
    required this.message,
    required this.role,
    this.onAskButler,
  });

  @override
  Widget build(BuildContext context) {
    final isUser = message.isUser;
    final theme = Theme.of(context);
    final roleColor = _parseColor(role.color);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Row(
        mainAxisAlignment:
            isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!isUser) ...[
            CircleAvatar(
              radius: 18,
              backgroundColor: roleColor.withValues(alpha: 0.15),
              child: Text(role.icon, style: const TextStyle(fontSize: 18)),
            ),
            const SizedBox(width: 8),
          ],
          Flexible(
            child: Column(
              crossAxisAlignment:
                  isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
              children: [
                if (!isUser)
                  Padding(
                    padding: const EdgeInsets.only(left: 4, bottom: 2),
                    child: Text(
                      role.name,
                      style: theme.textTheme.labelSmall
                          ?.copyWith(color: roleColor),
                    ),
                  ),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  decoration: BoxDecoration(
                    color: isUser
                        ? theme.colorScheme.primary
                        : theme.colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.only(
                      topLeft: const Radius.circular(16),
                      topRight: const Radius.circular(16),
                      bottomLeft: Radius.circular(isUser ? 16 : 4),
                      bottomRight: Radius.circular(isUser ? 4 : 16),
                    ),
                  ),
                  child: SelectableText(
                    message.content,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: isUser
                          ? theme.colorScheme.onPrimary
                          : theme.colorScheme.onSurface,
                    ),
                    contextMenuBuilder: (context, editableTextState) {
                      final anchor = editableTextState.contextMenuAnchors;
                      final selectedText = editableTextState
                          .textEditingValue.selection
                          .textInside(
                              editableTextState.textEditingValue.text);
                      final buttonItems = [
                        ...editableTextState.contextMenuButtonItems,
                        if (selectedText.isNotEmpty && onAskButler != null)
                          ContextMenuButtonItem(
                            label: '问Butler',
                            onPressed: () {
                              editableTextState.hideToolbar();
                              onAskButler!(selectedText);
                            },
                          ),
                      ];
                      return AdaptiveTextSelectionToolbar.buttonItems(
                        anchors: anchor,
                        buttonItems: buttonItems,
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
          if (isUser) const SizedBox(width: 44),
        ],
      ),
    );
  }
}

class ThinkingBubble extends StatefulWidget {
  final Role role;

  const ThinkingBubble({super.key, required this.role});

  @override
  State<ThinkingBubble> createState() => _ThinkingBubbleState();
}

class _ThinkingBubbleState extends State<ThinkingBubble>
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
    final roleColor = _parseColor(widget.role.color);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            radius: 18,
            backgroundColor: roleColor.withValues(alpha: 0.15),
            child: Text(widget.role.icon, style: const TextStyle(fontSize: 18)),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(16),
                topRight: Radius.circular(16),
                bottomLeft: Radius.circular(4),
                bottomRight: Radius.circular(16),
              ),
            ),
            child: AnimatedBuilder(
              animation: _controller,
              builder: (context, _) {
                final dots = '.' * ((_controller.value * 3).floor() % 3 + 1);
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
