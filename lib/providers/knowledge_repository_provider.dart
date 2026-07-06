import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/knowledge_card.dart';
import '../repositories/knowledge_repository.dart';
import 'database_provider.dart';

/// 知识卡片 Repository——读 [databaseProvider]。所有 UI / Notifier 写卡片都必须
/// 通过这里，禁止直接调 DAO（同 calendar/memory 纪律）。
final knowledgeRepositoryProvider =
    FutureProvider<KnowledgeRepository>((ref) async {
  final db = await ref.watch(databaseProvider.future);
  return KnowledgeRepository(db);
});

/// 全部知识卡片实时流——卡片页订阅，写后 drift watch 自动通知。新→旧。
final knowledgeCardsProvider =
    StreamProvider<List<KnowledgeCard>>((ref) async* {
  final repo = await ref.watch(knowledgeRepositoryProvider.future);
  yield* repo.watchAll();
});
