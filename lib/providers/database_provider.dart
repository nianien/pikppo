import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../db/database.dart';
import '../db/db_key.dart';
import 'model_service_provider.dart' show secureStorageProvider;

/// 全 App 单实例数据库。第一次 read 时打开 + 加密 key 自动准备。
final databaseProvider = FutureProvider<PikppoDatabase>((ref) async {
  final storage = ref.read(secureStorageProvider);
  final key = await getOrCreateDbKey(storage);
  final db = await openPikppoDatabase(key: key);
  ref.onDispose(() async {
    await db.close();
  });
  return db;
});
