import 'dart:io';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqlcipher_flutter_libs/sqlcipher_flutter_libs.dart';

part 'database.g.dart';

/// 消息表——私聊和群聊共用；[groupId] 非空表示群聊条目。
///
/// 设计要点：
/// - 主键用业务 id（UUID）而非自增 int，跟 [Message] 模型保持一致，方便同步/导出。
/// - 按 (role_id, group_id, timestamp) 建索引，覆盖 currentRoleMessages 和
///   groupMessages 两条查询热路径。
/// - kind 默认 'chat'，其它值如 'reminder' / 'tool_status' 表示 UI-only 气泡。
@DataClassName('MessageRow')
class MessageRows extends Table {
  TextColumn get id => text()();
  TextColumn get roleId => text()();
  TextColumn get content => text()();
  BoolColumn get isUser => boolean()();
  IntColumn get timestamp => integer()();
  TextColumn get kind => text().withDefault(const Constant('chat'))();
  TextColumn get groupId => text().nullable()();

  @override
  Set<Column> get primaryKey => {id};

  @override
  String get tableName => 'messages';
}

/// 记忆表——semantic（稳定特征）/ episodic（具体事件）两类；[roleId] 为空表
/// 示用户画像级记忆，所有角色共享；非空则只对该角色可见。
@DataClassName('MemoryRow')
class MemoryRows extends Table {
  TextColumn get id => text()();
  TextColumn get type => text()();
  TextColumn get content => text()();
  TextColumn get roleId => text().nullable()();
  IntColumn get timestamp => integer()();
  TextColumn get tagsJson => text().withDefault(const Constant('[]'))();

  @override
  Set<Column> get primaryKey => {id};

  @override
  String get tableName => 'memories';
}

/// 群聊表——`roleIdsJson` 是 JSON 数组字符串，因为 SQLite 没原生 list 类型，
/// 不值得为这种小数据再起一张关联表。
@DataClassName('GroupRow')
class GroupRows extends Table {
  TextColumn get id => text()();
  TextColumn get name => text()();
  TextColumn get roleIdsJson => text()();
  IntColumn get createdAt => integer()();

  @override
  Set<Column> get primaryKey => {id};

  @override
  String get tableName => 'groups';
}

/// 自定义角色——预置角色不入库（来自代码常量），只存用户自创的。
@DataClassName('CustomRoleRow')
class CustomRoleRows extends Table {
  TextColumn get id => text()();
  TextColumn get name => text()();
  TextColumn get icon => text()();
  TextColumn get description => text()();
  TextColumn get color => text()();
  TextColumn get systemPrompt => text()();

  @override
  Set<Column> get primaryKey => {id};

  @override
  String get tableName => 'custom_roles';
}

@DriftDatabase(tables: [MessageRows, MemoryRows, GroupRows, CustomRoleRows])
class PikppoDatabase extends _$PikppoDatabase {
  PikppoDatabase(super.executor);

  @override
  int get schemaVersion => 1;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) async {
          await m.createAll();
          // 热路径索引：currentRoleMessages、groupMessages、按时间排序。
          await customStatement(
              'CREATE INDEX msg_role_time ON messages(role_id, timestamp)');
          await customStatement(
              'CREATE INDEX msg_group_time ON messages(group_id, timestamp)');
          await customStatement(
              'CREATE INDEX mem_role_type ON memories(role_id, type)');
        },
      );

  // ---- Messages ----

  Future<List<MessageRow>> allMessages() =>
      (select(messageRows)..orderBy([(t) => OrderingTerm.asc(t.timestamp)]))
          .get();

  /// 私聊：指定角色 + groupId 为 NULL。
  Future<List<MessageRow>> messagesForRole(String roleId) =>
      (select(messageRows)
            ..where((t) => t.roleId.equals(roleId) & t.groupId.isNull())
            ..orderBy([(t) => OrderingTerm.asc(t.timestamp)]))
          .get();

  /// 群聊：指定 groupId。
  Future<List<MessageRow>> messagesForGroup(String groupId) =>
      (select(messageRows)
            ..where((t) => t.groupId.equals(groupId))
            ..orderBy([(t) => OrderingTerm.asc(t.timestamp)]))
          .get();

  /// 每条会话（按 scopeKey 分组）的"末条消息"行——给启动时的聊天列表用。
  /// 不读消息全文，只取每个会话最近 1 条；几十行查询即可覆盖。
  Future<List<MessageRow>> latestPerConversation() async {
    // 子查询：取每个 (role_id, group_id) 组合的 max(timestamp)
    final raw = await customSelect(
      '''
SELECT m.* FROM messages m
JOIN (
  SELECT role_id, group_id, MAX(timestamp) AS max_ts
  FROM messages
  GROUP BY role_id, group_id
) latest
  ON m.role_id = latest.role_id
  AND ((m.group_id IS NULL AND latest.group_id IS NULL) OR m.group_id = latest.group_id)
  AND m.timestamp = latest.max_ts
ORDER BY m.timestamp DESC
''',
      readsFrom: {messageRows},
    ).get();
    return raw.map((row) => messageRows.map(row.data)).toList();
  }

  Future<void> insertMessage(MessageRowsCompanion row) =>
      into(messageRows).insertOnConflictUpdate(row);

  Future<int> deleteMessage(String id) =>
      (delete(messageRows)..where((t) => t.id.equals(id))).go();

  Future<int> deleteMessagesForRole(String roleId) =>
      (delete(messageRows)
            ..where((t) => t.roleId.equals(roleId) & t.groupId.isNull()))
          .go();

  Future<int> deleteMessagesForGroup(String groupId) =>
      (delete(messageRows)..where((t) => t.groupId.equals(groupId))).go();

  // ---- Memories ----

  Future<List<MemoryRow>> allMemories() =>
      (select(memoryRows)..orderBy([(t) => OrderingTerm.desc(t.timestamp)]))
          .get();

  Future<void> insertMemory(MemoryRowsCompanion row) =>
      into(memoryRows).insertOnConflictUpdate(row);

  Future<int> deleteMemory(String id) =>
      (delete(memoryRows)..where((t) => t.id.equals(id))).go();

  Future<int> clearAllMemories() => delete(memoryRows).go();

  // ---- Groups ----

  Future<List<GroupRow>> allGroups() =>
      (select(groupRows)..orderBy([(t) => OrderingTerm.asc(t.createdAt)]))
          .get();

  Future<void> insertGroup(GroupRowsCompanion row) =>
      into(groupRows).insertOnConflictUpdate(row);

  Future<int> deleteGroup(String id) =>
      (delete(groupRows)..where((t) => t.id.equals(id))).go();

  // ---- Custom roles ----

  Future<List<CustomRoleRow>> allCustomRoles() =>
      select(customRoleRows).get();

  Future<void> insertCustomRole(CustomRoleRowsCompanion row) =>
      into(customRoleRows).insertOnConflictUpdate(row);

  Future<int> deleteCustomRole(String id) =>
      (delete(customRoleRows)..where((t) => t.id.equals(id))).go();
}

/// 打开数据库：SQLCipher 加密 + 后台 isolate 执行；密钥从 [getOrCreateDbKey]
/// 取，由 `flutter_secure_storage` 托管（首次启动生成、之后复用）。
Future<PikppoDatabase> openPikppoDatabase({required String key}) async {
  // SQLCipher 在某些旧 Android 版本上需要这步；其它平台无副作用。
  await applyWorkaroundToOpenSqlCipherOnOldAndroidVersions();

  final dir = await getApplicationSupportDirectory();
  final file = File(p.join(dir.path, 'pikppo.db'));

  final executor = NativeDatabase.createInBackground(
    file,
    setup: (rawDb) {
      // 必须在第一次查询前设置 key；之后 PRAGMA cipher_version 应该返回非空表示 SQLCipher 生效。
      rawDb.execute("PRAGMA key = '${_escapeKey(key)}'");
      rawDb.execute('PRAGMA cipher_memory_security = ON');
    },
  );
  return PikppoDatabase(executor);
}

/// 转义 PRAGMA key 里的单引号——SQL 字符串里 `'` 用 `''` 表示。生产环境密
/// 钥应由安全存储生成，不会出现引号，但仍做防御处理。
String _escapeKey(String key) => key.replaceAll("'", "''");
