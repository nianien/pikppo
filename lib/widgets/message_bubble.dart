import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../models/message.dart';
import '../models/role.dart';
import '../theme/design_tokens.dart';

/// 跨天日期分隔条：仅在相邻消息分别属于不同日期时插入。
/// 每条消息的精确时间由 [MessageBubble] 的 tooltip 提供，这里只解决"日期跨越
/// 没有锚点会让人迷失"的唯一硬边界。同一天内不显示任何常驻时间。
class MessageTimeSeparator extends StatelessWidget {
  final int timestamp;
  const MessageTimeSeparator({super.key, required this.timestamp});

  /// 是否在 [current] 之前插入分隔条；[previous] 为 null（首条）或与 current
  /// 不在同一日历日时插入。
  static bool shouldInsertBefore(Message current, Message? previous) {
    final c = DateTime.fromMillisecondsSinceEpoch(current.timestamp);
    if (previous == null) return true;
    final p = DateTime.fromMillisecondsSinceEpoch(previous.timestamp);
    return c.year != p.year || c.month != p.month || c.day != p.day;
  }

  static String formatDate(DateTime dt) {
    final now = DateTime.now();
    if (dt.year == now.year) return '${dt.month}月${dt.day}日';
    return '${dt.year}年${dt.month}月${dt.day}日';
  }

  /// 精确到分钟的完整时间戳，用于 tooltip。
  static String formatFull(DateTime dt) {
    final hh = dt.hour.toString().padLeft(2, '0');
    final mm = dt.minute.toString().padLeft(2, '0');
    return '${dt.year}年${dt.month.toString().padLeft(2, '0')}月'
        '${dt.day.toString().padLeft(2, '0')}日 $hh:$mm';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dt = DateTime.fromMillisecondsSinceEpoch(timestamp);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
      child: Center(
        child: Text(
          formatDate(dt),
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
            fontSize: 11,
          ),
        ),
      ),
    );
  }
}

Color _parseColor(String hex) =>
    Color(int.parse(hex.replaceFirst('#', '0xFF')));

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
    final scheme = theme.colorScheme;
    final roleColor = _parseColor(role.color);

    // 气泡圆角：主体 18 + 尾角 5（设计稿明确尺寸）。
    final radius = isUser
        ? const BorderRadius.only(
            topLeft: Radius.circular(AppRadius.bubble),
            topRight: Radius.circular(AppRadius.bubble),
            bottomLeft: Radius.circular(AppRadius.bubble),
            bottomRight: Radius.circular(AppRadius.bubbleTail),
          )
        : const BorderRadius.only(
            topLeft: Radius.circular(AppRadius.bubble),
            topRight: Radius.circular(AppRadius.bubble),
            bottomLeft: Radius.circular(AppRadius.bubbleTail),
            bottomRight: Radius.circular(AppRadius.bubble),
          );

    // 用 Tooltip 包裹气泡：桌面 hover、移动端长按（在气泡内边距区域，不与
    // SelectableText 的长按选词冲突）都会浮出完整时间，且不占用布局。
    final tooltipMessage = MessageTimeSeparator.formatFull(
      DateTime.fromMillisecondsSinceEpoch(message.timestamp),
    );

    // 用户气泡用 scheme.primary，跟 FAB / Send 键 / 其它 Material 主操作色统一。
    // AI 气泡用 primaryContainer（= 浅容器底）。
    final bubbleInner = Container(
      padding:
          const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: isUser ? scheme.primary : scheme.primaryContainer,
        borderRadius: radius,
      ),
      child: SelectableText(
        message.content,
        style: theme.textTheme.bodyMedium?.copyWith(
          color: isUser ? scheme.onPrimary : scheme.onPrimaryContainer,
          height: 1.5,
        ),
        contextMenuBuilder: (context, editableTextState) {
          final anchor = editableTextState.contextMenuAnchors;
          final selectedText = editableTextState
              .textEditingValue.selection
              .textInside(editableTextState.textEditingValue.text);
          final buttonItems = [
            ...editableTextState.contextMenuButtonItems,
            if (selectedText.isNotEmpty && onAskButler != null)
              ContextMenuButtonItem(
                label: '问 pikppo',
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
    );

    final bubble = Tooltip(
      message: tooltipMessage,
      preferBelow: false,
      waitDuration: const Duration(milliseconds: 400),
      child: bubbleInner,
    );

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Row(
        mainAxisAlignment:
            isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!isUser) ...[
            _Avatar(roleColor: roleColor, icon: role.icon),
            const SizedBox(width: AppSpacing.xs),
          ],
          Flexible(
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: MediaQuery.of(context).size.width * 0.78,
              ),
              child: Column(
                crossAxisAlignment: isUser
                    ? CrossAxisAlignment.end
                    : CrossAxisAlignment.start,
                children: [
                  if (!isUser)
                    Padding(
                      padding: const EdgeInsets.only(left: 6, bottom: 4),
                      child: Text(
                        role.name,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: roleColor,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0.2,
                        ),
                      ),
                    ),
                  bubble,
                ],
              ),
            ),
          ),
          if (isUser) const SizedBox(width: 44),
        ],
      ),
    );
  }
}

class _Avatar extends StatelessWidget {
  final Color roleColor;
  final String icon;
  const _Avatar({required this.roleColor, required this.icon});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 36,
      height: 36,
      decoration: BoxDecoration(
        color: roleColor.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(AppRadius.sm),
        border: Border.all(
          color: roleColor.withValues(alpha: 0.22),
          width: 0.5,
        ),
      ),
      alignment: Alignment.center,
      child: Text(icon, style: const TextStyle(fontSize: 18)),
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
      duration: const Duration(milliseconds: 1100),
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
    final scheme = theme.colorScheme;
    final roleColor = _parseColor(widget.role.color);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Avatar(roleColor: roleColor, icon: widget.role.icon),
          const SizedBox(width: AppSpacing.xs),
          Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHigh,
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(AppRadius.lg),
                topRight: Radius.circular(AppRadius.lg),
                bottomLeft: Radius.circular(AppRadius.xs),
                bottomRight: Radius.circular(AppRadius.lg),
              ),
            ),
            child: SizedBox(
              width: 36,
              height: 14,
              child: AnimatedBuilder(
                animation: _controller,
                builder: (context, _) =>
                    CustomPaint(painter: _DotsPainter(
                  progress: _controller.value,
                  color: scheme.onSurfaceVariant,
                )),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DotsPainter extends CustomPainter {
  final double progress;
  final Color color;
  _DotsPainter({required this.progress, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    const count = 3;
    const radius = 3.5;
    final spacing = (size.width - radius * 2 * count) / (count + 1);

    for (var i = 0; i < count; i++) {
      // Phase per dot, smooth sin pulse.
      final phase = (progress * 2 * math.pi) - (i * 0.6);
      final t = (math.sin(phase) + 1) / 2;
      final paint = Paint()
        ..color = color.withValues(alpha: 0.3 + 0.7 * t)
        ..style = PaintingStyle.fill;
      final dx = spacing * (i + 1) + radius * (i * 2 + 1);
      canvas.drawCircle(
        Offset(dx, size.height / 2 + math.sin(phase) * 1.5),
        radius,
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_DotsPainter old) => old.progress != progress;
}
