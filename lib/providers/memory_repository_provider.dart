import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../repositories/memory_repository.dart';
import 'database_provider.dart';

/// 记忆 Repository——读 [databaseProvider]。所有 UI / LLM 工具 / Notifier 写
/// 记忆都必须通过这里，禁止直接调 DAO（同 calendar 纪律）。
///
/// 与 [calendarRepositoryProvider] 不同的是：MemoryRepository 不依赖
/// ReminderScheduler——记忆的写副作用只有 P2 的备份请求，本身不产生用户可见的
/// 实时调度。
final memoryRepositoryProvider =
    FutureProvider<MemoryRepository>((ref) async {
  final db = await ref.watch(databaseProvider.future);
  return MemoryRepository(db);
});
