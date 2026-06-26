import 'dart:io';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
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
  // v5：附件（'image' | 'video' | 'file'），纯文本消息全为 NULL。
  TextColumn get attachmentType => text().nullable()();
  TextColumn get attachmentPath => text().nullable()();
  TextColumn get attachmentName => text().nullable()();
  IntColumn get attachmentSize => integer().nullable()();
  // v6：富图表卡片，JSON 数组 `[{type,data}, ...]`，挂在 AI 文字消息上同气泡渲染。
  // content 保持纯文本（进 LLM 历史、可复制/转发），图表数据独立于此列、不进历史。
  TextColumn get chartData => text().nullable()();

  @override
  Set<Column> get primaryKey => {id};

  @override
  String get tableName => 'messages';
}

/// 记忆表——semantic（稳定特征）/ episodic（具体事件）两类；[roleId] 为空表
/// 示用户画像级记忆，所有角色共享；非空则只对该角色可见。
///
/// 同步元数据 [updatedAt] / [deleted] 按 data-architecture v3.1 §3.1 脊柱补齐——
/// 即使 Phase 1 单机也持续维护，Phase 2 启用加密备份时存量数据无需迁移。
/// 没有 [dirty] / [serverVersion] 是因为 v2 走快照备份不依赖行级变更追踪。
@DataClassName('MemoryRow')
class MemoryRows extends Table {
  TextColumn get id => text()();
  TextColumn get type => text()();
  TextColumn get content => text()();
  TextColumn get roleId => text().nullable()();
  IntColumn get timestamp => integer()();
  TextColumn get tagsJson => text().withDefault(const Constant('[]'))();

  // ---- 同步元数据（v3 schema 新增） ----
  /// 最后一次写入时间（UTC）。Repository 写路径统一盖戳——LWW 跨设备合并依赖
  /// 单调性。读层无业务需要时不暴露。
  DateTimeColumn get updatedAt =>
      dateTime().withDefault(Constant(DateTime.fromMillisecondsSinceEpoch(0)))();

  /// 软删墓碑。DAO 读层统一过滤；让删除事实能穿越备份/导入而不被"复活"。
  BoolColumn get deleted => boolean().withDefault(const Constant(false))();

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

/// 日历事件表——local-first，按 §3.2 的同步协议形态建好全量字段。
///
/// 同步元数据（updatedAt / deleted / dirty / serverVersion）即使 Phase 1 单机
/// 也持续维护，Phase 2 上线时存量数据自带 dirty=true 自动进入"待推送"，零迁移。
///
/// 时间字段一律 UTC 入库，UI 展示时再转本地时区——LWW 跨设备比较需要绝对时间。
@DataClassName('CalendarEventRow')
class CalendarEventRows extends Table {
  // ---- 身份 ----
  TextColumn get id => text()();

  // ---- 业务字段 ----
  TextColumn get title => text()();
  TextColumn get description => text().withDefault(const Constant(''))();
  DateTimeColumn get startTime => dateTime()();
  DateTimeColumn get endTime => dateTime().nullable()();
  BoolColumn get allDay => boolean().withDefault(const Constant(false))();
  TextColumn get recurrenceRule => text().nullable()();
  IntColumn get reminderMinutes => integer().nullable()();

  /// 提醒归属（v3.2 / schema v4）——事件写入时由 ReminderRouter 决定，nullable
  /// 是因为：① v3 老行迁移上来时为 null；② 路由失败时不写入。触发时若为 null
  /// 由 dispatcher 即时兜底。
  TextColumn get routedRoleId => text().nullable()();

  // ---- 同步元数据 ----
  DateTimeColumn get updatedAt => dateTime()();
  BoolColumn get deleted => boolean().withDefault(const Constant(false))();
  BoolColumn get dirty => boolean().withDefault(const Constant(true))();
  IntColumn get serverVersion => integer().nullable()();

  @override
  Set<Column> get primaryKey => {id};

  @override
  String get tableName => 'calendar_events';
}

/// 同步游标——一行（key='calendar'）保存上次成功拉取的 server_version。
/// Phase 1 仅建表，Phase 2 由 SyncEngine 读写。
@DataClassName('SyncStateRow')
class SyncStateRows extends Table {
  TextColumn get key => text()();
  IntColumn get cursor => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {key};

  @override
  String get tableName => 'sync_state';
}

@DriftDatabase(tables: [
  MessageRows,
  MemoryRows,
  GroupRows,
  CustomRoleRows,
  CalendarEventRows,
  SyncStateRows,
])
class PikppoDatabase extends _$PikppoDatabase {
  PikppoDatabase(super.executor);

  @override
  int get schemaVersion => 6;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) async {
          await m.createAll();
          // 热路径索引：currentRoleMessages、groupMessages、按时间排序。
          await customStatement(
              'CREATE INDEX IF NOT EXISTS msg_role_time ON messages(role_id, timestamp)');
          await customStatement(
              'CREATE INDEX IF NOT EXISTS msg_group_time ON messages(group_id, timestamp)');
          await customStatement(
              'CREATE INDEX IF NOT EXISTS mem_role_type ON memories(role_id, type)');
          await customStatement(
              'CREATE INDEX IF NOT EXISTS mem_alive ON memories(timestamp) WHERE deleted = 0');
          // 日历范围查询热路径：按 start_time 区间扫描，过滤墓碑。
          await customStatement(
              'CREATE INDEX IF NOT EXISTS cal_start_alive ON calendar_events(start_time) WHERE deleted = 0');
          // 同步推送热路径：扫描 dirty 行。
          await customStatement(
              'CREATE INDEX IF NOT EXISTS cal_dirty ON calendar_events(dirty) WHERE dirty = 1');
        },
        onUpgrade: (m, from, to) async {
          if (from < 2) {
            await m.createTable(calendarEventRows);
            await m.createTable(syncStateRows);
            await customStatement(
                'CREATE INDEX IF NOT EXISTS cal_start_alive ON calendar_events(start_time) WHERE deleted = 0');
            await customStatement(
                'CREATE INDEX IF NOT EXISTS cal_dirty ON calendar_events(dirty) WHERE dirty = 1');
          }
          if (from < 3) {
            // v3：memories 表补脊柱字段（v3.1 §3.1）。
            // 存量行 updated_at = 0（epoch）— LWW 合并时让来自新设备的备份始终
            // 胜出；deleted = false 不动语义。新写入由 MemoryRepository 盖戳。
            await m.addColumn(memoryRows, memoryRows.updatedAt);
            await m.addColumn(memoryRows, memoryRows.deleted);
            // 读热路径仅过滤墓碑——按 role_id 的旧索引保留即可。
            await customStatement(
                'CREATE INDEX IF NOT EXISTS mem_alive ON memories(timestamp) WHERE deleted = 0');
          }
          if (from < 4) {
            // v4：calendar_events 补 routed_role_id（v3.2 §4）。
            // 存量行 routedRoleId = NULL —— 下次 update 或触发时 dispatcher
            // 兜底走 ReminderRouter。NotificationService 在加列后会批量 reschedule
            // 未来事件（应用启动时延迟执行，见 lib/services/notification_service）。
            await m.addColumn(
                calendarEventRows, calendarEventRows.routedRoleId);
          }
          if (from < 5) {
            // v5：messages 补附件四列，存量行全 NULL（纯文本）。
            await m.addColumn(messageRows, messageRows.attachmentType);
            await m.addColumn(messageRows, messageRows.attachmentPath);
            await m.addColumn(messageRows, messageRows.attachmentName);
            await m.addColumn(messageRows, messageRows.attachmentSize);
          }
          if (from < 6) {
            // v6：messages 补 chart_data（富图表卡片 JSON），存量行全 NULL。
            await m.addColumn(messageRows, messageRows.chartData);
          }
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

  /// 私聊分页：最新的 [limit] 条（按时间升序返回——方便直接拼接到 UI 列表
  /// 末尾）。
  Future<List<MessageRow>> messagesForRoleLatest(String roleId,
      {required int limit}) async {
    final rows = await (select(messageRows)
          ..where((t) => t.roleId.equals(roleId) & t.groupId.isNull())
          ..orderBy([(t) => OrderingTerm.desc(t.timestamp)])
          ..limit(limit))
        .get();
    return rows.reversed.toList();
  }

  /// 私聊分页：早于 [beforeTimestamp] 的 [limit] 条（向上翻页时用）。
  Future<List<MessageRow>> messagesForRoleBefore(
    String roleId, {
    required int beforeTimestamp,
    required int limit,
  }) async {
    final rows = await (select(messageRows)
          ..where((t) =>
              t.roleId.equals(roleId) &
              t.groupId.isNull() &
              t.timestamp.isSmallerThanValue(beforeTimestamp))
          ..orderBy([(t) => OrderingTerm.desc(t.timestamp)])
          ..limit(limit))
        .get();
    return rows.reversed.toList();
  }

  /// 群聊：指定 groupId。
  Future<List<MessageRow>> messagesForGroup(String groupId) =>
      (select(messageRows)
            ..where((t) => t.groupId.equals(groupId))
            ..orderBy([(t) => OrderingTerm.asc(t.timestamp)]))
          .get();

  /// 群聊分页：最新的 [limit] 条（升序返回）。
  Future<List<MessageRow>> messagesForGroupLatest(String groupId,
      {required int limit}) async {
    final rows = await (select(messageRows)
          ..where((t) => t.groupId.equals(groupId))
          ..orderBy([(t) => OrderingTerm.desc(t.timestamp)])
          ..limit(limit))
        .get();
    return rows.reversed.toList();
  }

  /// 群聊分页：早于 [beforeTimestamp] 的 [limit] 条。
  Future<List<MessageRow>> messagesForGroupBefore(
    String groupId, {
    required int beforeTimestamp,
    required int limit,
  }) async {
    final rows = await (select(messageRows)
          ..where((t) =>
              t.groupId.equals(groupId) &
              t.timestamp.isSmallerThanValue(beforeTimestamp))
          ..orderBy([(t) => OrderingTerm.desc(t.timestamp)])
          ..limit(limit))
        .get();
    return rows.reversed.toList();
  }

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

  /// 某会话内的非空附件路径——删除会话前先取出，用于清理私有副本文件。
  Future<List<String>> attachmentPathsForRole(String roleId) async {
    final rows = await (selectOnly(messageRows)
          ..addColumns([messageRows.attachmentPath])
          ..where(messageRows.roleId.equals(roleId) &
              messageRows.groupId.isNull() &
              messageRows.attachmentPath.isNotNull()))
        .get();
    return rows
        .map((r) => r.read(messageRows.attachmentPath))
        .whereType<String>()
        .toList();
  }

  Future<List<String>> attachmentPathsForGroup(String groupId) async {
    final rows = await (selectOnly(messageRows)
          ..addColumns([messageRows.attachmentPath])
          ..where(messageRows.groupId.equals(groupId) &
              messageRows.attachmentPath.isNotNull()))
        .get();
    return rows
        .map((r) => r.read(messageRows.attachmentPath))
        .whereType<String>()
        .toList();
  }

  /// 仍引用某附件路径的消息条数——转发会共享同一副本，0 才能安全删文件。
  Future<int> countMessagesWithAttachment(String path) async {
    final count = messageRows.id.count();
    final row = await (selectOnly(messageRows)
          ..addColumns([count])
          ..where(messageRows.attachmentPath.equals(path)))
        .getSingle();
    return row.read(count) ?? 0;
  }

  // ---- Memories ----
  //
  // 写方法已迁移到 [MemoryDao]，由 [MemoryRepository] 唯一持有；此处仅保留启
  // 动时全量加载的读方法（统一过滤墓碑——data-architecture v3.1 §3.1 脊柱）。

  Future<List<MemoryRow>> allMemories() =>
      (select(memoryRows)
            ..where((t) => t.deleted.equals(false))
            ..orderBy([(t) => OrderingTerm.desc(t.timestamp)]))
          .get();

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
///
/// [accountId] 决定库文件落位：`<appSupport>/accounts/<accountId>/pikppo.db`。
/// Phase 1 恒传 `'local'`；将来登录后切到 `u_xxx` 即多账号硬隔离（文件系统级，
/// 不靠 DAO 漏写 `where user_id` 这条易错路径）。
///
/// 启动时若检测到旧路径（`<appSupport>/pikppo.db`），且新路径不存在，则一次性
/// 重命名——老用户升级到本版本数据自动归属 `local` 账号，无丢数据风险。
Future<PikppoDatabase> openPikppoDatabase({
  required String key,
  required String accountId,
}) async {
  // SQLCipher 在某些旧 Android 版本上需要这步；其它平台无副作用。
  await applyWorkaroundToOpenSqlCipherOnOldAndroidVersions();

  final root = await getApplicationSupportDirectory();
  final accountDir = Directory(p.join(root.path, 'accounts', accountId));
  if (!accountDir.existsSync()) {
    accountDir.createSync(recursive: true);
  }
  final file = File(p.join(accountDir.path, 'pikppo.db'));

  // 一次性迁移：旧版本数据放在 <appSupport>/pikppo.db，归属到 accounts/local/。
  // 仅在新路径还没库 + 旧路径有库时触发；之后不再走这条分支。
  if (accountId == 'local' && !file.existsSync()) {
    final legacy = File(p.join(root.path, 'pikppo.db'));
    if (legacy.existsSync()) {
      try {
        legacy.renameSync(file.path);
        debugPrint('migrated legacy db → accounts/local/pikppo.db');
      } catch (e) {
        // rename 失败（少见——跨文件系统等）退化为 copy + 保留旧文件，避免数据丢失。
        legacy.copySync(file.path);
        debugPrint(
            'legacy db copied (rename failed, original kept as backup): $e');
      }
    }
  }

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
