import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/calendar_event.dart';
import '../repositories/calendar_repository.dart';
import 'database_provider.dart';
import 'reminder_scheduler_provider.dart';

/// 日历 Repository——读 [databaseProvider]（FutureProvider，库打开是 async）
/// 和 [reminderSchedulerProvider]。任何 UI / LLM 工具 / Notifier 写日历都必须
/// 通过这里，禁止直接调 DAO。
final calendarRepositoryProvider =
    FutureProvider<CalendarRepository>((ref) async {
  final db = await ref.watch(databaseProvider.future);
  final scheduler = ref.watch(reminderSchedulerProvider);
  return CalendarRepository(db, scheduler);
});

/// 30 天内的日程实时流——apps_screen 日历页 / `_buildCalendarContext` 都订阅
/// 这一份，DAO 写后 drift 自动通知。
final upcomingCalendarEventsProvider =
    StreamProvider<List<CalendarEvent>>((ref) async* {
  final repo = await ref.watch(calendarRepositoryProvider.future);
  yield* repo.watchUpcoming();
});
