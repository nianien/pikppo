import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/message.dart';
import '../models/role.dart';
import '../services/tts_service.dart';
import '../theme/design_tokens.dart';
import '../utils/color_hex.dart';
import '../utils/time_format.dart';
import 'attachment_bubble.dart';
import 'exchange_trend_chart.dart';
import 'message_actions.dart';

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

  /// 分隔条上的简短日期：今年内省略年份。
  static String formatDate(DateTime dt) {
    final now = DateTime.now();
    if (dt.year == now.year) return '${dt.month}月${dt.day}日';
    return '${dt.year}年${dt.month}月${dt.day}日';
  }

  /// 完整时间戳（tooltip 用）：委托给 [fmtMessageStamp]——单一来源。
  static String formatFull(DateTime dt) => fmtMessageStamp(dt);

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

class MessageBubble extends ConsumerWidget {
  final Message message;
  final Role role;

  /// 多选模式：true 时点气泡 = 勾选/取消（[onSelectToggle]），长按选词/操作面板
  /// 全部禁用，气泡前显示勾选圈。
  final bool selectionMode;
  final bool selected;
  final VoidCallback? onSelectToggle;

  /// 进入多选模式（长按面板"多选"触发）——非选择态时由 [showMessageActions] 调。
  final void Function(Message seed)? onEnterSelection;

  /// 失败气泡（kind=='error'）的"重试"回调。
  final VoidCallback? onRetry;

  const MessageBubble({
    super.key,
    required this.message,
    required this.role,
    this.selectionMode = false,
    this.selected = false,
    this.onSelectToggle,
    this.onEnterSelection,
    this.onRetry,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isUser = message.isUser;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final roleColor = parseHexColor(role.color);

    // 失败气泡：错误色 + 下方"重试"。不可多选（未落库的瞬时态）。
    if (message.kind == 'error') {
      return _ErrorBubble(role: role, message: message, onRetry: onRetry);
    }

    // 富图表卡片：按 content 里的 {type,data} 选图表渲染（汇率走势等）。
    // 是落库的正经消息——同样接入多选删除（勾选 + 长按进多选）。
    if (message.kind == 'chart') {
      return _ChartCard(
        role: role,
        message: message,
        selectionMode: selectionMode,
        selected: selected,
        onSelectToggle: onSelectToggle,
        onEnterSelection: onEnterSelection,
      );
    }

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
    // 图片附件不要彩底厚 padding（图自带边界），文件/视频卡片保留气泡底。
    final isBareImage = message.attachmentType == 'image';
    final bubbleInner = Container(
      padding: isBareImage
          ? EdgeInsets.zero
          : const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: isBareImage
            ? null
            : (isUser ? scheme.primary : scheme.primaryContainer),
        borderRadius: radius,
      ),
      child: message.hasAttachment
          ? Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          AttachmentContent(message: message, isUser: isUser),
          if (message.content.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                message.content,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: isUser
                      ? scheme.onPrimary
                      : scheme.onPrimaryContainer,
                  height: 1.5,
                ),
              ),
            ),
        ],
      )
          : selectionMode
      // 多选模式下用普通 Text——SelectableText 会抢走点按手势导致勾选失效。
          ? Text(
        message.content,
        style: theme.textTheme.bodyMedium?.copyWith(
          color: isUser
              ? scheme.onPrimary
              : scheme.onPrimaryContainer,
          height: 1.5,
        ),
      )
          : _SelectableMessageText(
        message: message,
        baseStyle: theme.textTheme.bodyMedium?.copyWith(
          color:
          isUser ? scheme.onPrimary : scheme.onPrimaryContainer,
          height: 1.5,
        ),
        onEnterSelection: onEnterSelection,
      ),
    );

    // 长按气泡（文字选区之外的区域）弹出 复制/转发 面板；桌面 hover 的完整
    // 时间戳 Tooltip 保留，面板头部也带时间戳，移动端不丢信息。
    final bubble = Tooltip(
      message: tooltipMessage,
      preferBelow: false,
      triggerMode: TooltipTriggerMode.manual,
      waitDuration: const Duration(milliseconds: 400),
      child: GestureDetector(
        onTap: selectionMode ? onSelectToggle : null,
        onLongPress: selectionMode
            ? null
            : () => showMessageActions(context, ref, message,
            onEnterSelection: onEnterSelection),
        child: bubbleInner,
      ),
    );

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Row(
        mainAxisAlignment: selectionMode
            ? MainAxisAlignment.start
            : (isUser ? MainAxisAlignment.end : MainAxisAlignment.start),
        crossAxisAlignment: selectionMode
            ? CrossAxisAlignment.center
            : CrossAxisAlignment.start,
        children: [
          if (selectionMode) ...[
            GestureDetector(
              onTap: onSelectToggle,
              child: Icon(
                selected
                    ? Icons.check_circle_rounded
                    : Icons.radio_button_unchecked,
                color: selected ? scheme.primary : scheme.outline,
                size: 22,
              ),
            ),
            const SizedBox(width: AppSpacing.xs),
          ],
          if (!isUser) ...[
            _Avatar(roleColor: roleColor, icon: role.icon),
            const SizedBox(width: AppSpacing.xs),
          ],
          Flexible(
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: MediaQuery.of(context).size.width * 0.78,
              ),
              child: Builder(builder: (context) {
                // 挂在本条消息上的图表卡片（与文字同气泡、同头像；图在上文字在下）。
                final charts = _buildAttachedCharts(context, message.chartData);
                final showBubble = charts.isEmpty || message.content.isNotEmpty;
                return Column(
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
                    ...charts,
                    if (showBubble) bubble,
                  ],
                );
              }),
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

/// 失败回复气泡：错误色底 + 文案 + 下方"重试"。kind=='error' 的消息走这里，
/// 不落库、不进 LLM 历史（[MessagingController] 只把 kind=='chat' 喂模型）。
class _ErrorBubble extends StatelessWidget {
  final Role role;
  final Message message;
  final VoidCallback? onRetry;
  const _ErrorBubble({
    required this.role,
    required this.message,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final roleColor = parseHexColor(role.color);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Avatar(roleColor: roleColor, icon: role.icon),
          const SizedBox(width: AppSpacing.xs),
          Flexible(
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: MediaQuery.of(context).size.width * 0.78,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 12),
                    decoration: BoxDecoration(
                      color: scheme.errorContainer,
                      borderRadius: const BorderRadius.only(
                        topLeft: Radius.circular(AppRadius.bubble),
                        topRight: Radius.circular(AppRadius.bubble),
                        bottomLeft: Radius.circular(AppRadius.bubbleTail),
                        bottomRight: Radius.circular(AppRadius.bubble),
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(Icons.error_outline_rounded,
                            size: 18, color: scheme.onErrorContainer),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            message.content,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: scheme.onErrorContainer,
                              height: 1.5,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (onRetry != null)
                    TextButton.icon(
                      onPressed: onRetry,
                      style: TextButton.styleFrom(
                        foregroundColor: scheme.error,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 0),
                        minimumSize: const Size(0, 32),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      icon: const Icon(Icons.refresh_rounded, size: 16),
                      label: const Text('重试'),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 44),
        ],
      ),
    );
  }
}

/// 富图表卡片气泡：解析 `kind=='chart'` 消息的 `{type,data}`，按 type 选图表。
/// 未知 type / 解析失败 → 不渲染（SizedBox.shrink），不报错。
class _ChartCard extends StatelessWidget {
  final Role role;
  final Message message;
  final bool selectionMode;
  final bool selected;
  final VoidCallback? onSelectToggle;
  final void Function(Message seed)? onEnterSelection;
  const _ChartCard({
    required this.role,
    required this.message,
    this.selectionMode = false,
    this.selected = false,
    this.onSelectToggle,
    this.onEnterSelection,
  });

  @override
  Widget build(BuildContext context) {
    Map<String, dynamic>? decoded;
    try {
      final d = jsonDecode(message.content);
      if (d is Map) decoded = d.cast<String, dynamic>();
    } catch (_) {}
    final body = decoded == null ? null : _chartBodyFor(decoded);
    if (body == null) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final roleColor = parseHexColor(role.color);
    final card = ConstrainedBox(
      constraints: BoxConstraints(
        maxWidth: MediaQuery.of(context).size.width * 0.82,
      ),
      child: GestureDetector(
        onTap: selectionMode ? onSelectToggle : null,
        // 卡片 content 是 JSON，复制/转发/翻译都不适用——长按直接进多选，
        // 让用户能勾选删除这张图。
        onLongPress: selectionMode
            ? null
            : () => onEnterSelection?.call(message),
        child: Container(
          padding: const EdgeInsets.all(AppSpacing.md),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(AppRadius.lg),
          ),
          child: body,
        ),
      ),
    );

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Row(
        crossAxisAlignment: selectionMode
            ? CrossAxisAlignment.center
            : CrossAxisAlignment.start,
        children: [
          if (selectionMode) ...[
            GestureDetector(
              onTap: onSelectToggle,
              child: Icon(
                selected
                    ? Icons.check_circle_rounded
                    : Icons.radio_button_unchecked,
                color: selected ? scheme.primary : scheme.outline,
                size: 22,
              ),
            ),
            const SizedBox(width: AppSpacing.xs),
          ],
          _Avatar(roleColor: roleColor, icon: role.icon),
          const SizedBox(width: AppSpacing.xs),
          Flexible(child: card),
        ],
      ),
    );
  }
}

/// 解析消息的 `chartData`（JSON 数组 `[{type,data},...]`），构造图表卡片 widget
/// 列表，挂在文字消息上方同气泡渲染。失败 / 为空 → 空列表。
List<Widget> _buildAttachedCharts(BuildContext context, String? chartData) {
  if (chartData == null || chartData.isEmpty) return const [];
  List<dynamic> list;
  try {
    final d = jsonDecode(chartData);
    if (d is! List) return const [];
    list = d;
  } catch (_) {
    return const [];
  }
  final scheme = Theme.of(context).colorScheme;
  final out = <Widget>[];
  for (final c in list) {
    if (c is! Map) continue;
    final body = _chartBodyFor(c.cast<String, dynamic>());
    if (body == null) continue;
    out.add(Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Container(
        padding: const EdgeInsets.all(AppSpacing.md),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(AppRadius.lg),
        ),
        child: body,
      ),
    ));
  }
  return out;
}

/// `{type,data}` → 对应图表 body widget；未知 type / 数据无效 → null。
Widget? _chartBodyFor(Map<String, dynamic> card) {
  final type = card['type'];
  final data = card['data'];
  if (type == 'exchange_trend' && data is Map) {
    return _ExchangeTrendCardBody(data: data.cast<String, dynamic>());
  }
  return null;
}

class _ExchangeTrendCardBody extends StatelessWidget {
  final Map<String, dynamic> data;
  const _ExchangeTrendCardBody({required this.data});

  static double _d(Object? v) => (v as num?)?.toDouble() ?? 0;
  static String _fmtRate(double v) =>
      v == v.roundToDouble() ? v.toStringAsFixed(2) : v.toStringAsFixed(4);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final from = data['from']?.toString() ?? '';
    final to = data['to']?.toString() ?? '';
    final rates = <double>[];
    final dates = <String>[];
    for (final p in (data['points'] as List? ?? const [])) {
      if (p is Map) {
        rates.add(_d(p['rate']));
        dates.add(p['date']?.toString() ?? '');
      }
    }
    if (rates.length < 2) return const SizedBox.shrink();
    final changePct = _d(data['change_pct']);
    final minRate = _d(data['min_rate']);
    final maxRate = _d(data['max_rate']);
    final startRate = _d(data['start_rate'] ?? rates.first);
    final up = changePct >= 0;
    final color = up ? AppPalette.success : AppPalette.danger;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('$from/$to 走势',
            style: theme.textTheme.titleSmall
                ?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: 4),
        Row(
          children: [
            Icon(up ? Icons.trending_up : Icons.trending_down,
                size: 16, color: color),
            const SizedBox(width: 4),
            Text('${up ? '+' : ''}${changePct.toStringAsFixed(2)}%',
                style: theme.textTheme.labelMedium
                    ?.copyWith(color: color, fontWeight: FontWeight.w700)),
            const Spacer(),
            Flexible(
              child: Text(
                '低 ${_fmtRate(minRate)} · 高 ${_fmtRate(maxRate)}',
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.end,
                style: theme.textTheme.labelSmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.sm),
        SizedBox(
          height: 150,
          child: ExchangeTrendChart(
            rates: rates,
            dates: dates,
            minRate: minRate,
            maxRate: maxRate,
            startRate: startRate,
            changePct: changePct,
          ),
        ),
      ],
    );
  }
}

class ThinkingBubble extends StatefulWidget {
  final Role role;

  /// agent loop 工具执行期间显示的瞬时状态文案（如"正在调用工具：货币换算"）。
  /// null = 普通"思考中"圆点动画。
  final String? statusText;
  const ThinkingBubble({super.key, required this.role, this.statusText});

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
    final roleColor = parseHexColor(widget.role.color);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Avatar(roleColor: roleColor, icon: widget.role.icon),
          const SizedBox(width: AppSpacing.xs),
          Container(
            padding: const EdgeInsets.symmetric(
                horizontal: 16, vertical: 14),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHigh,
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(AppRadius.lg),
                topRight: Radius.circular(AppRadius.lg),
                bottomLeft: Radius.circular(AppRadius.xs),
                bottomRight: Radius.circular(AppRadius.lg),
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
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                Text(
                  widget.statusText!,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            )
                : SizedBox(
              width: 36,
              height: 14,
              child: AnimatedBuilder(
                animation: _controller,
                builder: (context, _) => CustomPaint(
                  painter: _DotsPainter(
                    progress: _controller.value,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
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

// ---- 微信式文字选择菜单：深色圆角气泡 + 横排多行，避免系统溢出竖排 ----

/// 可选中的消息文字 + 微信式自建选择菜单。用会话级标志实现"默认整条选中，但用户
/// 拖手柄缩小后不回弹"：长按本次会话只在第一次扩成全选，选区收起后复位。
class _SelectableMessageText extends ConsumerStatefulWidget {
  final Message message;
  final TextStyle? baseStyle;
  final void Function(Message seed)? onEnterSelection;
  const _SelectableMessageText({
    required this.message,
    required this.baseStyle,
    required this.onEnterSelection,
  });

  @override
  ConsumerState<_SelectableMessageText> createState() =>
      _SelectableMessageTextState();
}

class _SelectableMessageTextState
    extends ConsumerState<_SelectableMessageText> {
  // 本次选择会话是否已默认全选过。true 后不再强制全选（让拖手柄缩小生效）；
  // 选区收起时复位，下次长按重新默认全选。
  bool _didAutoSelectAll = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final message = widget.message;
    final isUser = message.isUser;
    return DefaultSelectionStyle(
      // 选区高亮色：绿底用户气泡用白色高亮、浅底 AI 气泡用主色高亮，两种底都看得清。
      selectionColor: isUser
          ? scheme.onPrimary.withValues(alpha: 0.45)
          : scheme.primary.withValues(alpha: 0.30),
      child: SelectableText(
        message.content,
        style: widget.baseStyle,
        onSelectionChanged: (selection, cause) {
          // 选区收起（点别处）→ 复位，下次长按重新默认全选。
          if (selection.isCollapsed) _didAutoSelectAll = false;
        },
        contextMenuBuilder: (context, editableTextState) {
          final value = editableTextState.textEditingValue;
          final text = value.text;
          final sel = value.selection;
          final selectedText = sel.textInside(text);
          final isAll =
              text.isNotEmpty && sel.start == 0 && sel.end == text.length;
          // 默认整条选中：本次会话**仅第一次**把长按选中的那个词扩成全选；之后用户
          // 拖手柄缩小不再回弹（contextMenuBuilder 每次选区变化都重建，无标志位就会
          // 反复强制全选 = bug）。已是全选态也置位，覆盖"单词=整条"的短消息。
          if (isAll) {
            _didAutoSelectAll = true;
          } else if (!sel.isCollapsed && !_didAutoSelectAll) {
            _didAutoSelectAll = true;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (editableTextState.mounted) {
                editableTextState.selectAll(SelectionChangedCause.toolbar);
              }
            });
          }
          // 完全自建菜单（像微信）：固定中文标签 + 图标，不取系统注入项。
          final actions = <_ToolbarAction>[
            _ToolbarAction('复制', Icons.copy_rounded, () {
              editableTextState.copySelection(SelectionChangedCause.toolbar);
              editableTextState.hideToolbar();
            }),
            _ToolbarAction('全选', Icons.select_all_rounded, () {
              editableTextState.selectAll(SelectionChangedCause.toolbar);
            }),
            _ToolbarAction('朗读', Icons.volume_up_rounded, () {
              editableTextState.hideToolbar();
              TtsService.instance.speak(
                  selectedText.isNotEmpty ? selectedText : message.content);
            }),
            if (selectedText.isNotEmpty)
              _ToolbarAction('释义', Icons.menu_book_rounded, () {
                editableTextState.hideToolbar();
                showExplainDialog(context, ref, selectedText, message.content);
              }),
            _ToolbarAction('翻译', Icons.translate_rounded, () {
              editableTextState.hideToolbar();
              showTranslateDialog(context, ref, message.content);
            }),
            _ToolbarAction('转发', Icons.forward_rounded, () {
              editableTextState.hideToolbar();
              showForwardPicker(context, ref, message);
            }),
            _ToolbarAction('分享', Icons.ios_share_rounded, () {
              editableTextState.hideToolbar();
              shareText(message.content);
            }),
            if (widget.onEnterSelection != null)
              _ToolbarAction('多选', Icons.checklist_rounded, () {
                editableTextState.hideToolbar();
                widget.onEnterSelection!(message);
              }),
          ];
          return _SelectionToolbar(
            anchors: editableTextState.contextMenuAnchors,
            actions: actions,
          );
        },
      ),
    );
  }
}

class _ToolbarAction {
  final String label;
  final IconData icon;
  final VoidCallback onPressed;
  const _ToolbarAction(this.label, this.icon, this.onPressed);
}

class _SelectionToolbar extends StatelessWidget {
  final TextSelectionToolbarAnchors anchors;
  final List<_ToolbarAction> actions;
  const _SelectionToolbar({required this.anchors, required this.actions});

  @override
  Widget build(BuildContext context) {
    return CustomSingleChildLayout(
      delegate: _SelectionToolbarLayout(
        anchorAbove: anchors.primaryAnchor,
        anchorBelow: anchors.secondaryAnchor ?? anchors.primaryAnchor,
        padding: MediaQuery.of(context).padding,
      ),
      child: _SelectionToolbarBubble(actions: actions),
    );
  }
}

/// 微信式网格菜单：每项「图标 + 中文标签」竖排，横向铺开自动换行；**明亮底**。
class _SelectionToolbarBubble extends StatelessWidget {
  final List<_ToolbarAction> actions;
  const _SelectionToolbarBubble({required this.actions});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final onColor = theme.colorScheme.onSurface;
    return Material(
      color: theme.colorScheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(12),
      elevation: 8,
      shadowColor: Colors.black.withValues(alpha: 0.18),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
        child: Wrap(
          children: [
            for (final a in actions)
              InkWell(
                onTap: a.onPressed,
                borderRadius: BorderRadius.circular(8),
                child: SizedBox(
                  width: 60,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        vertical: 10, horizontal: 2),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(a.icon, size: 22, color: onColor),
                        const SizedBox(height: 6),
                        Text(
                          a.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.labelSmall
                              ?.copyWith(color: onColor),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 把菜单气泡定位到选区上方（不够则放下方），并夹在安全区内、限制最大宽度以
/// 触发 Wrap 多行——模仿微信的横排多行布局。
class _SelectionToolbarLayout extends SingleChildLayoutDelegate {
  final Offset anchorAbove;
  final Offset anchorBelow;
  final EdgeInsets padding;
  const _SelectionToolbarLayout({
    required this.anchorAbove,
    required this.anchorBelow,
    required this.padding,
  });

  static const double _margin = 8;
  // 容 5 个 60px 单元一行（5×60 + 容器内边距）——微信式 5 列网格。
  static const double _maxWidth = 320;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    final avail = constraints.maxWidth - padding.left - padding.right - _margin * 2;
    final maxW = math.max(0.0, math.min(_maxWidth, avail));
    return BoxConstraints(maxWidth: maxW, maxHeight: constraints.maxHeight);
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    double x = anchorAbove.dx - childSize.width / 2;
    final minX = padding.left + _margin;
    final maxX = size.width - padding.right - _margin - childSize.width;
    x = maxX >= minX ? x.clamp(minX, maxX) : minX;

    double y = anchorAbove.dy - childSize.height - _margin;
    if (y < padding.top + _margin) {
      y = anchorBelow.dy + _margin; // 上方放不下 → 放选区下方
    }
    final minY = padding.top + _margin;
    final maxY = size.height - padding.bottom - _margin - childSize.height;
    y = maxY >= minY ? y.clamp(minY, maxY) : minY;
    return Offset(x, y);
  }

  @override
  bool shouldRelayout(_SelectionToolbarLayout old) =>
      anchorAbove != old.anchorAbove ||
          anchorBelow != old.anchorBelow ||
          padding != old.padding;
}
