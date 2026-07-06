import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/calendar_event.dart';
import '../providers/app_state_provider.dart';
import '../providers/calendar_repository_provider.dart';
import '../theme/design_tokens.dart';
import 'exchange_screen.dart';
import 'knowledge_cards_screen.dart';

/// 应用入口页。每个卡片对应一个可独立打开的子页面。日历是 Phase 1 的本地化
/// 域，未来加 notes / inbox / etc. 时往 `_apps` 追加即可。
class AppsScreen extends ConsumerWidget {
  const AppsScreen({super.key});

  static final _apps = <_AppItem>[
    _AppItem(
      icon: Icons.calendar_month,
      name: '日历',
      color: const Color(0xFF3B82F6),
      category: '效率',
      builder: (_) => const _CalendarPage(),
    ),
    _AppItem(
      icon: Icons.currency_exchange,
      name: '汇率',
      color: const Color(0xFF10B981),
      category: '工具',
      builder: (_) => const ExchangeScreen(),
    ),
    _AppItem(
      icon: Icons.bookmarks_rounded,
      name: '知识卡片',
      color: const Color(0xFF8B5CF6),
      category: '效率',
      builder: (_) => const KnowledgeCardsScreen(),
    ),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final byCategory = <String, List<_AppItem>>{};
    for (final a in _apps) {
      byCategory.putIfAbsent(a.category, () => []).add(a);
    }
    final categoryOrder = ['效率', '工具', '生活']
        .where(byCategory.containsKey)
        .toList();

    return Scaffold(
      appBar: AppBar(title: const Text('应用')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.md,
          AppSpacing.xs,
          AppSpacing.md,
          AppSpacing.xl,
        ),
        children: [
          for (final cat in categoryOrder) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(
                  4, AppSpacing.md, 4, AppSpacing.sm),
              child: Text(
                cat,
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                      color: Theme.of(context)
                          .colorScheme
                          .onSurfaceVariant,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.4,
                    ),
              ),
            ),
            GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate:
                  const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                mainAxisSpacing: AppSpacing.sm,
                crossAxisSpacing: AppSpacing.sm,
                childAspectRatio: 0.95,
              ),
              itemCount: byCategory[cat]!.length,
              itemBuilder: (context, index) =>
                  _AppCard(app: byCategory[cat]![index]),
            ),
          ],
        ],
      ),
    );
  }
}

class _AppItem {
  final IconData icon;
  final String name;
  final Color color;
  final String category;
  final WidgetBuilder builder;

  const _AppItem({
    required this.icon,
    required this.name,
    required this.color,
    required this.category,
    required this.builder,
  });
}

class _AppCard extends StatelessWidget {
  final _AppItem app;
  const _AppCard({required this.app});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Material(
      color: scheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(AppRadius.lg),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.lg),
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(builder: app.builder),
        ),
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.sm),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      app.color.withValues(alpha: 0.22),
                      app.color.withValues(alpha: 0.10),
                    ],
                  ),
                  borderRadius: BorderRadius.circular(AppRadius.md),
                  border: Border.all(
                      color: app.color.withValues(alpha: 0.25), width: 0.5),
                ),
                child: Icon(app.icon, color: app.color, size: 28),
              ),
              const SizedBox(height: AppSpacing.sm),
              Text(
                app.name,
                style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: scheme.onSurface),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---- Calendar Page ----

class _CalendarPage extends ConsumerStatefulWidget {
  const _CalendarPage();

  @override
  ConsumerState<_CalendarPage> createState() => _CalendarPageState();
}

class _CalendarPageState extends ConsumerState<_CalendarPage> {
  DateTime _selectedDate = DateTime.now();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // 订阅本地 30 天事件流——drift 自动通知，无需手动 refresh。
    final asyncEvents = ref.watch(upcomingCalendarEventsProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('日历')),
      body: Column(
        children: [
          CalendarDatePicker(
            initialDate: _selectedDate,
            firstDate: DateTime(2024),
            lastDate: DateTime(2030),
            onDateChanged: (date) {
              setState(() => _selectedDate = date);
            },
          ),
          Expanded(
            child: asyncEvents.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (err, _) => Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text('日历加载失败：$err',
                      style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.error)),
                ),
              ),
              data: (events) {
                final dayEvents = _eventsForDay(events, _selectedDate);
                return Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 20, vertical: 8),
                      child: Row(
                        children: [
                          Text(
                            '${_selectedDate.month}月${_selectedDate.day}日',
                            style: theme.textTheme.titleMedium
                                ?.copyWith(fontWeight: FontWeight.bold),
                          ),
                          const Spacer(),
                          Text('${dayEvents.length}个日程',
                              style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.onSurface
                                      .withValues(alpha: 0.5))),
                        ],
                      ),
                    ),
                    Expanded(
                      child: dayEvents.isEmpty
                          ? Center(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(Icons.event_available,
                                      size: 48,
                                      color: theme.colorScheme.onSurface
                                          .withValues(alpha: 0.15)),
                                  const SizedBox(height: 8),
                                  Text('当日无日程',
                                      style: theme.textTheme.bodyMedium
                                          ?.copyWith(
                                              color: theme.colorScheme.onSurface
                                                  .withValues(alpha: 0.3))),
                                ],
                              ),
                            )
                          : ListView.builder(
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 16),
                              itemCount: dayEvents.length,
                              itemBuilder: (context, index) {
                                final event = dayEvents[index];
                                return _EventCard(
                                  event: event,
                                  onTap: () =>
                                      _showEventSheet(context, event),
                                  onDelete: () => _delete(context, event.id),
                                );
                              },
                            ),
                    ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _showEventSheet(context, null),
        child: const Icon(Icons.add),
      ),
    );
  }

  /// 客户端按本地日期归属过滤——服务端流是 UTC，UI 视角应该按"本地哪一天"。
  List<CalendarEvent> _eventsForDay(
      List<CalendarEvent> events, DateTime day) {
    final target = DateTime(day.year, day.month, day.day);
    return events.where((e) => e.localDate == target).toList();
  }

  Future<void> _delete(BuildContext context, String id) async {
    try {
      await ref.read(appStateProvider.notifier).deleteCalendarEvent(id);
    } catch (e) {
      if (!context.mounted) return;
      _showError(context, '删除失败：$e');
    }
  }

  void _showError(BuildContext context, String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  void _showEventSheet(BuildContext context, CalendarEvent? existing) {
    final isEdit = existing != null;
    final titleCtrl = TextEditingController(text: existing?.title ?? '');
    final descCtrl =
        TextEditingController(text: existing?.description ?? '');
    DateTime pickedDate = existing?.localDate ??
        DateTime(_selectedDate.year, _selectedDate.month, _selectedDate.day);
    TimeOfDay? pickedTime = existing != null && !existing.allDay
        ? TimeOfDay(
            hour: existing.localStart.hour,
            minute: existing.localStart.minute,
          )
        : null;
    int? reminderMinutes = existing?.reminderMinutes;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => StatefulBuilder(
        builder: (context, setSheetState) {
          final theme = Theme.of(context);
          return Padding(
            padding: EdgeInsets.only(
              bottom: MediaQuery.of(context).viewInsets.bottom,
            ),
            child: Container(
              padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Container(
                      width: 36,
                      height: 4,
                      decoration: BoxDecoration(
                        color: theme.colorScheme.outlineVariant,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: Text(isEdit ? '编辑日程' : '添加日程',
                            style: theme.textTheme.titleLarge
                                ?.copyWith(fontWeight: FontWeight.bold)),
                      ),
                      if (isEdit)
                        IconButton(
                          onPressed: () async {
                            await _delete(context, existing.id);
                            if (context.mounted) Navigator.pop(context);
                          },
                          icon: Icon(Icons.delete_outline,
                              color: theme.colorScheme.error),
                          tooltip: '删除',
                        ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  TextField(
                    controller: titleCtrl,
                    autofocus: !isEdit,
                    decoration: InputDecoration(
                      labelText: '日程标题',
                      hintText: '如：团队周会',
                      border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12)),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: InkWell(
                          borderRadius: BorderRadius.circular(12),
                          onTap: () async {
                            final d = await showDatePicker(
                              context: context,
                              initialDate: pickedDate,
                              firstDate: DateTime(2024),
                              lastDate: DateTime(2030),
                            );
                            if (d != null) {
                              setSheetState(() => pickedDate = d);
                            }
                          },
                          child: InputDecorator(
                            decoration: InputDecoration(
                              labelText: '日期',
                              border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(12)),
                              suffixIcon:
                                  const Icon(Icons.calendar_today, size: 20),
                            ),
                            child: Text(
                              '${pickedDate.year}/${pickedDate.month.toString().padLeft(2, '0')}/${pickedDate.day.toString().padLeft(2, '0')}',
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: InkWell(
                          borderRadius: BorderRadius.circular(12),
                          onTap: () async {
                            final t = await showTimePicker(
                              context: context,
                              initialTime: pickedTime ?? TimeOfDay.now(),
                            );
                            if (t != null) {
                              setSheetState(() => pickedTime = t);
                            }
                          },
                          child: InputDecorator(
                            decoration: InputDecoration(
                              labelText: '时间',
                              border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(12)),
                              suffixIcon: pickedTime != null
                                  ? IconButton(
                                      icon: const Icon(Icons.clear, size: 18),
                                      onPressed: () => setSheetState(
                                          () => pickedTime = null),
                                    )
                                  : const Icon(Icons.access_time, size: 20),
                            ),
                            child: Text(
                              pickedTime != null
                                  ? '${pickedTime!.hour.toString().padLeft(2, '0')}:${pickedTime!.minute.toString().padLeft(2, '0')}'
                                  : '全天',
                              style: pickedTime == null
                                  ? TextStyle(
                                      color: theme.colorScheme.onSurface
                                          .withValues(alpha: 0.4))
                                  : null,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: descCtrl,
                    maxLines: 3,
                    minLines: 1,
                    decoration: InputDecoration(
                      labelText: '备注（选填）',
                      hintText: '如：会议号、地点、链接等',
                      border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12)),
                    ),
                  ),
                  const SizedBox(height: 16),
                  InkWell(
                    borderRadius: BorderRadius.circular(12),
                    onTap: () {
                      showModalBottomSheet(
                        context: context,
                        builder: (ctx) {
                          final options = <MapEntry<String, int?>>[
                            const MapEntry('不提醒', null),
                            const MapEntry('5分钟前', 5),
                            const MapEntry('10分钟前', 10),
                            const MapEntry('15分钟前', 15),
                            const MapEntry('30分钟前', 30),
                            const MapEntry('1小时前', 60),
                            const MapEntry('2小时前', 120),
                            const MapEntry('1天前', 1440),
                          ];
                          return SafeArea(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Padding(
                                  padding: const EdgeInsets.all(16),
                                  child: Text('选择提醒时间',
                                      style: Theme.of(ctx)
                                          .textTheme
                                          .titleMedium
                                          ?.copyWith(
                                              fontWeight: FontWeight.bold)),
                                ),
                                ...options.map((o) => ListTile(
                                      title: Text(o.key),
                                      trailing: reminderMinutes == o.value
                                          ? Icon(Icons.check,
                                              color: Theme.of(ctx)
                                                  .colorScheme
                                                  .primary)
                                          : null,
                                      onTap: () {
                                        setSheetState(
                                            () => reminderMinutes = o.value);
                                        Navigator.pop(ctx);
                                      },
                                    )),
                              ],
                            ),
                          );
                        },
                      );
                    },
                    child: InputDecorator(
                      decoration: InputDecoration(
                        labelText: '提醒',
                        border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12)),
                        suffixIcon:
                            const Icon(Icons.notifications_none, size: 20),
                      ),
                      child: Text(
                        reminderMinutes != null
                            ? _reminderLabel(reminderMinutes!)
                            : '不提醒',
                        style: reminderMinutes == null
                            ? TextStyle(
                                color: theme.colorScheme.onSurface
                                    .withValues(alpha: 0.4))
                            : null,
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  SizedBox(
                    width: double.infinity,
                    height: 48,
                    child: FilledButton(
                      onPressed: () async {
                        final title = titleCtrl.text.trim();
                        if (title.isEmpty) return;
                        final desc = descCtrl.text.trim();
                        final allDay = pickedTime == null;
                        // 本地零点 / 本地 HH:mm —— Repository 入库前转 UTC。
                        final startLocal = allDay
                            ? DateTime(
                                pickedDate.year,
                                pickedDate.month,
                                pickedDate.day,
                              )
                            : DateTime(
                                pickedDate.year,
                                pickedDate.month,
                                pickedDate.day,
                                pickedTime!.hour,
                                pickedTime!.minute,
                              );

                        final notifier =
                            ref.read(appStateProvider.notifier);
                        try {
                          if (isEdit) {
                            await notifier.updateCalendarEvent(
                              existing.id,
                              CalendarEventPatch(
                                title: title,
                                description: desc,
                                startTime: startLocal,
                                allDay: allDay,
                                reminderMinutes: reminderMinutes,
                                clearReminderMinutes:
                                    reminderMinutes == null,
                              ),
                            );
                          } else {
                            await notifier.addCalendarEvent(
                              CalendarEventDraft(
                                title: title,
                                description: desc,
                                startTime: startLocal,
                                allDay: allDay,
                                reminderMinutes: reminderMinutes,
                              ),
                            );
                          }
                        } catch (e) {
                          if (!context.mounted) return;
                          _showError(context, '保存失败：$e');
                          return;
                        }
                        if (context.mounted) Navigator.pop(context);
                      },
                      child: Text(isEdit ? '保存修改' : '添加日程'),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

String _reminderLabel(int minutes) {
  if (minutes >= 1440) return '提前${minutes ~/ 1440}天';
  if (minutes >= 60) return '提前${minutes ~/ 60}小时';
  return '提前$minutes分钟';
}

class _EventCard extends StatelessWidget {
  final CalendarEvent event;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  const _EventCard({
    required this.event,
    required this.onTap,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Dismissible(
      key: Key(event.id),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        margin: const EdgeInsets.only(bottom: 8),
        decoration: BoxDecoration(
          color: theme.colorScheme.error,
          borderRadius: BorderRadius.circular(12),
        ),
        child: const Icon(Icons.delete, color: Colors.white),
      ),
      onDismissed: (_) => onDelete(),
      child: Card(
        margin: const EdgeInsets.only(bottom: 8),
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 52,
                  child: event.localTimeLabel != null
                      ? Column(
                          children: [
                            Text(event.localTimeLabel!,
                                style: theme.textTheme.titleSmall?.copyWith(
                                    fontWeight: FontWeight.bold,
                                    color: theme.colorScheme.primary)),
                          ],
                        )
                      : Icon(Icons.schedule,
                          size: 20,
                          color: theme.colorScheme.onSurface
                              .withValues(alpha: 0.25)),
                ),
                Container(
                  width: 3,
                  height: event.description.isNotEmpty ? 44 : 24,
                  margin: const EdgeInsets.only(right: 12),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primary,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(event.title,
                          style: theme.textTheme.bodyLarge
                              ?.copyWith(fontWeight: FontWeight.w600)),
                      if (event.description.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Text(event.description,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurface
                                    .withValues(alpha: 0.5))),
                      ],
                      if (event.reminderMinutes != null) ...[
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            Icon(Icons.notifications_active,
                                size: 13, color: theme.colorScheme.tertiary),
                            const SizedBox(width: 4),
                            Text(
                              _reminderLabel(event.reminderMinutes!),
                              style: theme.textTheme.labelSmall
                                  ?.copyWith(color: theme.colorScheme.tertiary),
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
                Icon(Icons.chevron_right,
                    size: 20,
                    color:
                        theme.colorScheme.onSurface.withValues(alpha: 0.2)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
