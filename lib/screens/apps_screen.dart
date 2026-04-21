import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/app_state_provider.dart';
import '../models/calendar_event.dart';
import 'package:uuid/uuid.dart';

class AppsScreen extends StatelessWidget {
  const AppsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final apps = [
      _AppItem(
        icon: Icons.calendar_month,
        name: '日历',
        color: const Color(0xFF3B82F6),
        description: '日程管理与提醒',
      ),
      _AppItem(
        icon: Icons.email_outlined,
        name: '邮件',
        color: const Color(0xFFEF4444),
        description: '邮件收发与管理',
      ),
      _AppItem(
        icon: Icons.note_alt_outlined,
        name: '笔记',
        color: const Color(0xFFF97316),
        description: '随手记录与整理',
      ),
      _AppItem(
        icon: Icons.psychology_outlined,
        name: '记忆',
        color: const Color(0xFF8B5CF6),
        description: '语义、情节、工作记忆',
      ),
      _AppItem(
        icon: Icons.checklist,
        name: '待办',
        color: const Color(0xFF22C55E),
        description: '任务清单管理',
      ),
      _AppItem(
        icon: Icons.translate,
        name: '翻译',
        color: const Color(0xFF06B6D4),
        description: '多语言即时翻译',
      ),
    ];

    return Scaffold(
      appBar: AppBar(
        title: const Text('应用'),
      ),
      body: GridView.builder(
        padding: const EdgeInsets.all(20),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 3,
          mainAxisSpacing: 20,
          crossAxisSpacing: 20,
          childAspectRatio: 0.85,
        ),
        itemCount: apps.length,
        itemBuilder: (context, index) {
          final app = apps[index];
          return _AppCard(app: app);
        },
      ),
    );
  }
}

class _AppItem {
  final IconData icon;
  final String name;
  final Color color;
  final String description;

  _AppItem({
    required this.icon,
    required this.name,
    required this.color,
    required this.description,
  });
}

class _AppCard extends StatelessWidget {
  final _AppItem app;

  const _AppCard({required this.app});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: () {
        if (app.name == '日历') {
          Navigator.push(context,
              MaterialPageRoute(builder: (_) => const _CalendarPage()));
        } else if (app.name == '邮件') {
          Navigator.push(context,
              MaterialPageRoute(builder: (_) => const _MailPage()));
        } else if (app.name == '笔记') {
          Navigator.push(context,
              MaterialPageRoute(builder: (_) => const _NotesPage()));
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('${app.name}功能开发中')),
          );
        }
      },
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: app.color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Icon(app.icon, color: app.color, size: 28),
          ),
          const SizedBox(height: 10),
          Text(app.name,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(fontWeight: FontWeight.w500)),
        ],
      ),
    );
  }
}

// ---- Calendar Page ----

const _calUuid = Uuid();

class _CalendarPage extends ConsumerStatefulWidget {
  const _CalendarPage();

  @override
  ConsumerState<_CalendarPage> createState() => _CalendarPageState();
}

class _CalendarPageState extends ConsumerState<_CalendarPage> {
  DateTime _selectedDate = DateTime.now();
  int _refreshKey = 0;

  void _refresh() => setState(() => _refreshKey++);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final notifier = ref.read(appStateProvider.notifier);

    // Watch calendarEvents length to trigger rebuild on external changes
    ref.watch(appStateProvider.select((s) => s.calendarEvents.length));

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
            child: FutureBuilder<List<CalendarEvent>>(
              key: ValueKey('$_selectedDate-$_refreshKey'),
              future: notifier.getEventsForDay(_selectedDate),
              builder: (context, snapshot) {
                final events = snapshot.data ?? [];
                return Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                      child: Row(
                        children: [
                          Text(
                            '${_selectedDate.month}月${_selectedDate.day}日',
                            style: theme.textTheme.titleMedium
                                ?.copyWith(fontWeight: FontWeight.bold),
                          ),
                          const Spacer(),
                          Text('${events.length}个日程',
                              style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.onSurface
                                      .withValues(alpha: 0.5))),
                        ],
                      ),
                    ),
                    Expanded(
                      child: events.isEmpty
                          ? Center(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(Icons.event_available,
                                      size: 48,
                                      color: theme.colorScheme.onSurface
                                          .withValues(alpha: 0.15)),
                                  const SizedBox(height: 8),
                                  Text(snapshot.connectionState == ConnectionState.waiting
                                          ? '加载中...'
                                          : '当日无日程',
                                      style: theme.textTheme.bodyMedium?.copyWith(
                                          color: theme.colorScheme.onSurface
                                              .withValues(alpha: 0.3))),
                                ],
                              ),
                            )
                          : ListView.builder(
                              padding: const EdgeInsets.symmetric(horizontal: 16),
                              itemCount: events.length,
                              itemBuilder: (context, index) {
                                final event = events[index];
                                return _EventCard(
                                  event: event,
                                  onTap: () => _showEventSheet(context, event),
                                  onDelete: () {
                                    notifier.deleteCalendarEvent(event.id);
                                    _refresh();
                                  },
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

  void _showEventSheet(BuildContext context, CalendarEvent? existing) {
    final isEdit = existing != null;
    final titleCtrl = TextEditingController(text: existing?.title ?? '');
    final descCtrl = TextEditingController(text: existing?.description ?? '');
    DateTime pickedDate = existing?.date ??
        DateTime(_selectedDate.year, _selectedDate.month, _selectedDate.day);
    TimeOfDay? pickedTime;
    int? reminderMinutes = existing?.reminderMinutes;
    if (existing?.time != null) {
      final parts = existing!.time!.split(':');
      pickedTime = TimeOfDay(
          hour: int.parse(parts[0]), minute: int.parse(parts[1]));
    }

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
                  // Handle bar
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
                  // Header
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
                            await ref
                                .read(appStateProvider.notifier)
                                .deleteCalendarEvent(existing.id);
                            if (context.mounted) Navigator.pop(context);
                            _refresh();
                          },
                          icon: Icon(Icons.delete_outline,
                              color: theme.colorScheme.error),
                          tooltip: '删除',
                        ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  // Title
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
                  // Date & Time row
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
                              initialTime:
                                  pickedTime ?? TimeOfDay.now(),
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
                                      onPressed: () =>
                                          setSheetState(() => pickedTime = null),
                                    )
                                  : const Icon(Icons.access_time, size: 20),
                            ),
                            child: Text(
                              pickedTime != null
                                  ? '${pickedTime!.hour.toString().padLeft(2, '0')}:${pickedTime!.minute.toString().padLeft(2, '0')}'
                                  : '不设置',
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
                  // Description
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
                  // Reminder
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
                                      style: Theme.of(ctx).textTheme.titleMedium
                                          ?.copyWith(fontWeight: FontWeight.bold)),
                                ),
                                ...options.map((o) => ListTile(
                                      title: Text(o.key),
                                      trailing: reminderMinutes == o.value
                                          ? Icon(Icons.check,
                                              color: Theme.of(ctx).colorScheme.primary)
                                          : null,
                                      onTap: () {
                                        setSheetState(() => reminderMinutes = o.value);
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
                        suffixIcon: const Icon(Icons.notifications_none, size: 20),
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
                  // Save button
                  SizedBox(
                    width: double.infinity,
                    height: 48,
                    child: FilledButton(
                      onPressed: () async {
                        final title = titleCtrl.text.trim();
                        if (title.isEmpty) return;
                        final timeStr = pickedTime != null
                            ? '${pickedTime!.hour.toString().padLeft(2, '0')}:${pickedTime!.minute.toString().padLeft(2, '0')}'
                            : null;
                        final desc = descCtrl.text.trim().isEmpty
                            ? null
                            : descCtrl.text.trim();

                        final notifier =
                            ref.read(appStateProvider.notifier);
                        if (isEdit) {
                          await notifier.updateCalendarEvent(existing.copyWith(
                            title: title,
                            date: pickedDate,
                            time: timeStr,
                            clearTime: timeStr == null,
                            description: desc,
                            clearDescription: desc == null,
                            reminderMinutes: reminderMinutes,
                            clearReminder: reminderMinutes == null,
                          ));
                        } else {
                          await notifier.addCalendarEvent(CalendarEvent(
                            id: _calUuid.v4(),
                            title: title,
                            date: pickedDate,
                            time: timeStr,
                            description: desc,
                            reminderMinutes: reminderMinutes,
                          ));
                        }
                        if (context.mounted) Navigator.pop(context);
                        _refresh();
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
                // Time column
                SizedBox(
                  width: 52,
                  child: event.time != null
                      ? Column(
                          children: [
                            Text(event.time!,
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
                // Divider bar
                Container(
                  width: 3,
                  height: event.description != null ? 44 : 24,
                  margin: const EdgeInsets.only(right: 12),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primary,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                // Content
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(event.title,
                          style: theme.textTheme.bodyLarge
                              ?.copyWith(fontWeight: FontWeight.w600)),
                      if (event.description != null) ...[
                        const SizedBox(height: 4),
                        Text(event.description!,
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
                                size: 13,
                                color: theme.colorScheme.tertiary),
                            const SizedBox(width: 4),
                            Text(
                              _reminderLabel(event.reminderMinutes!),
                              style: theme.textTheme.labelSmall?.copyWith(
                                  color: theme.colorScheme.tertiary),
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

// ---- Mail Page ----

class _MailPage extends StatelessWidget {
  const _MailPage();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final mails = [
      _MailItem('张总', 'Re: Q3预算方案讨论', '方案B看起来可行，我们周五详细讨论...', '2小时前', false),
      _MailItem('HR部门', '年度体检通知', '请各位同事在本月底前完成年度体检预约...', '昨天', true),
      _MailItem('项目组', '周会纪要 - 3月第2周', '本周重点：1. 完成API对接 2. UI走查...', '3天前', true),
      _MailItem('李明', '出差报销单审批', '请审批附件中的出差报销单，金额3,200元...', '5天前', true),
    ];

    return Scaffold(
      appBar: AppBar(title: const Text('邮件')),
      body: ListView.separated(
        itemCount: mails.length,
        separatorBuilder: (_, __) => Divider(
          height: 1,
          indent: 16,
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.3),
        ),
        itemBuilder: (context, index) {
          final mail = mails[index];
          return ListTile(
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            leading: CircleAvatar(
              backgroundColor:
                  theme.colorScheme.primary.withValues(alpha: 0.12),
              child: Text(mail.sender[0],
                  style: TextStyle(color: theme.colorScheme.primary)),
            ),
            title: Row(
              children: [
                if (!mail.read)
                  Container(
                    width: 8,
                    height: 8,
                    margin: const EdgeInsets.only(right: 8),
                    decoration: const BoxDecoration(
                      color: Colors.blue,
                      shape: BoxShape.circle,
                    ),
                  ),
                Expanded(
                  child: Text(mail.sender,
                      style: TextStyle(
                          fontWeight:
                              mail.read ? FontWeight.normal : FontWeight.bold)),
                ),
                Text(mail.time,
                    style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurface
                            .withValues(alpha: 0.4))),
              ],
            ),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(mail.subject,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(fontWeight: FontWeight.w500)),
                Text(mail.preview,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurface
                            .withValues(alpha: 0.4))),
              ],
            ),
            onTap: () {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('打开邮件：${mail.subject}')),
              );
            },
          );
        },
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('写邮件功能开发中')),
          );
        },
        child: const Icon(Icons.edit),
      ),
    );
  }
}

class _MailItem {
  final String sender;
  final String subject;
  final String preview;
  final String time;
  final bool read;

  _MailItem(this.sender, this.subject, this.preview, this.time, this.read);
}

// ---- Notes Page ----

class _NotesPage extends StatefulWidget {
  const _NotesPage();

  @override
  State<_NotesPage> createState() => _NotesPageState();
}

class _NotesPageState extends State<_NotesPage> {
  final _notes = [
    _NoteItem('Q3预算方案要点', '方案A：优化资源配置\n方案B：申请追加预算\n需要和张总确认时间线', '2天前',
        const Color(0xFF3B82F6)),
    _NoteItem('粤菜餐厅推荐', '点都德 - 距离近\n广州酒家 - 评分最高\n记得备注不要香菜', '5天前',
        const Color(0xFF22C55E)),
    _NoteItem('本月支出记录', '房租5500 + 话费128 + 车贷3200 + 健身299 = 9127', '1周前',
        const Color(0xFFF97316)),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('笔记')),
      body: ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: _notes.length,
        itemBuilder: (context, index) {
          final note = _notes[index];
          return Card(
            margin: const EdgeInsets.only(bottom: 12),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: () => _editNote(context, index),
              child: Container(
                decoration: BoxDecoration(
                  border: Border(
                    left: BorderSide(color: note.color, width: 4),
                  ),
                ),
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(note.title,
                              style: theme.textTheme.titleSmall
                                  ?.copyWith(fontWeight: FontWeight.bold)),
                        ),
                        Text(note.time,
                            style: theme.textTheme.labelSmall?.copyWith(
                                color: theme.colorScheme.onSurface
                                    .withValues(alpha: 0.4))),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(note.content,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurface
                                .withValues(alpha: 0.6))),
                  ],
                ),
              ),
            ),
          );
        },
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _addNote(context),
        child: const Icon(Icons.add),
      ),
    );
  }

  void _addNote(BuildContext context) {
    final titleController = TextEditingController();
    final contentController = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('新建笔记'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: titleController,
              decoration: const InputDecoration(
                hintText: '标题',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: contentController,
              maxLines: 5,
              decoration: const InputDecoration(
                hintText: '内容',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              if (titleController.text.trim().isNotEmpty) {
                setState(() {
                  _notes.insert(
                    0,
                    _NoteItem(
                      titleController.text.trim(),
                      contentController.text.trim(),
                      '刚刚',
                      const Color(0xFF8B5CF6),
                    ),
                  );
                });
                Navigator.pop(ctx);
              }
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
  }

  void _editNote(BuildContext context, int index) {
    final note = _notes[index];
    final titleController = TextEditingController(text: note.title);
    final contentController = TextEditingController(text: note.content);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('编辑笔记'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: titleController,
              decoration: const InputDecoration(
                hintText: '标题',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: contentController,
              maxLines: 5,
              decoration: const InputDecoration(
                hintText: '内容',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              setState(() => _notes.removeAt(index));
              Navigator.pop(ctx);
            },
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('删除'),
          ),
          const Spacer(),
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              setState(() {
                _notes[index] = _NoteItem(
                  titleController.text.trim(),
                  contentController.text.trim(),
                  note.time,
                  note.color,
                );
              });
              Navigator.pop(ctx);
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
  }
}

class _NoteItem {
  final String title;
  final String content;
  final String time;
  final Color color;

  _NoteItem(this.title, this.content, this.time, this.color);
}
