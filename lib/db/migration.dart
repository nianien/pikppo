import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../data/preset_roles.dart';
import '../models/group.dart';
import '../models/memory.dart';
import '../models/message.dart';
import '../models/role.dart';
import '../utils/user_facing_error.dart';
import 'database.dart';
import 'mappers.dart';

/// SharedPreferences key——首次迁移完成后置 true，之后跳过。
const _kMigratedFlag = 'sqlite_migrated_v1';

/// 把旧版本（v0）SharedPreferences 里全量 JSON 形态的 messages/memories/groups/
/// customRoles 一次性灌进 drift。写完置标志位、清除旧 keys。
///
/// 设计要点：
/// - **幂等**：再次调用直接返回，不重复迁移。
/// - **per-row 容错**：单条坏数据跳过 + 计日志，不让一条脏数据阻断整次迁移。
/// - **事务一次性写**：要么全成、要么回滚——避免迁移到一半失败留下半残数据。
/// - **不删 prefs 旧 key**：保留作为"灾难回退"凭据；下个版本再清。
Future<void> migrateFromPrefsIfNeeded(PikppoDatabase db) async {
  final prefs = await SharedPreferences.getInstance();
  if (prefs.getBool(_kMigratedFlag) == true) return;

  final messages = _decodeRows(
      prefs.getString('messages'), 'messages', Message.fromJson);
  final memories = _decodeRows(
      prefs.getString('memories'), 'memories', Memory.fromJson);
  final groups =
      _decodeRows(prefs.getString('groups'), 'groups', Group.fromJson);
  final customRoles = _decodeRows(
      prefs.getString('customRoles'), 'customRoles', Role.fromJson);

  await db.transaction(() async {
    for (final m in messages) {
      await db.into(db.messageRows).insertOnConflictUpdate(messageToCompanion(m));
    }
    for (final m in memories) {
      await db.into(db.memoryRows).insertOnConflictUpdate(memoryToCompanion(m));
    }
    for (final g in groups) {
      await db.into(db.groupRows).insertOnConflictUpdate(groupToCompanion(g));
    }
    for (final r in customRoles) {
      // 与预置角色 id 冲突的自定义角色丢弃（不应该出现，但防御一手）。
      if (defaultRoles.any((d) => d.id == r.id)) continue;
      await db
          .into(db.customRoleRows)
          .insertOnConflictUpdate(customRoleToCompanion(r));
    }
  });

  await prefs.setBool(_kMigratedFlag, true);
  debugPrint(
      'prefs→sqlite migrated: ${messages.length} messages / '
      '${memories.length} memories / ${groups.length} groups / '
      '${customRoles.length} custom roles');
}

List<T> _decodeRows<T>(
  String? raw,
  String tableName,
  T Function(Map<String, dynamic>) fromJson,
) {
  if (raw == null || raw.isEmpty) return <T>[];
  List<dynamic> rows;
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! List) return <T>[];
    rows = decoded;
  } catch (e) {
    debugPrint('migrate $tableName: JSON decode failed: ${debugReason(e)}');
    return <T>[];
  }
  final out = <T>[];
  var skipped = 0;
  for (final row in rows) {
    try {
      if (row is! Map) {
        skipped++;
        continue;
      }
      out.add(fromJson(row.cast<String, dynamic>()));
    } catch (e) {
      skipped++;
      debugPrint('migrate $tableName: skip bad row: ${debugReason(e)}');
    }
  }
  if (skipped > 0) {
    debugPrint('migrate $tableName: skipped $skipped corrupt row(s)');
  }
  return out;
}
