import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../db/database.dart';
import '../db/db_key.dart';
import 'model_service_provider.dart' show secureStorageProvider;

/// 当前活跃账号 id。Phase 1 永远是 `'local'`（匿名）；Phase 2 引入登录后由账户
/// 系统驱动切换，作用是参数化 [databaseProvider]——每账号一个独立 SQLite 文件，
/// 隔离由文件系统而非 `where user_id` 谓词保证。
final activeAccountIdProvider = StateProvider<String>((_) => 'local');

/// 当前活跃账号对应的数据库。`activeAccountIdProvider` 变化时自动重建——
/// drift 实例随账号切换关闭/重开，避免上个账号的句柄继续写入新账号的库。
final databaseProvider = FutureProvider<PikppoDatabase>((ref) async {
  final storage = ref.read(secureStorageProvider);
  final key = await getOrCreateDbKey(storage);
  final accountId = ref.watch(activeAccountIdProvider);
  final db = await openPikppoDatabase(key: key, accountId: accountId);
  ref.onDispose(() async {
    await db.close();
  });
  return db;
});
