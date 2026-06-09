import 'dart:convert';
import 'package:drift/drift.dart';
import '../models/group.dart';
import '../models/memory.dart';
import '../models/message.dart';
import '../models/role.dart';
import 'database.dart';

/// 数据库 row ↔ 业务 model 适配。drift 生成的 RowClass 字段近似 model，但
/// 需要在 List ↔ JSON 字符串、可空字段等处做一次小转换，集中在此处避免散播。

// ---- Message ----

Message messageFromRow(MessageRow r) => Message(
      id: r.id,
      roleId: r.roleId,
      content: r.content,
      isUser: r.isUser,
      timestamp: r.timestamp,
      groupId: r.groupId,
      kind: r.kind,
    );

MessageRowsCompanion messageToCompanion(Message m) => MessageRowsCompanion(
      id: Value(m.id),
      roleId: Value(m.roleId),
      content: Value(m.content),
      isUser: Value(m.isUser),
      timestamp: Value(m.timestamp),
      kind: Value(m.kind),
      groupId: Value(m.groupId),
    );

// ---- Memory ----

Memory memoryFromRow(MemoryRow r) {
  final tags = (jsonDecode(r.tagsJson) as List).cast<String>();
  return Memory(
    id: r.id,
    type: r.type,
    content: r.content,
    roleId: r.roleId,
    timestamp: r.timestamp,
    tags: tags,
  );
}

MemoryRowsCompanion memoryToCompanion(Memory m) => MemoryRowsCompanion(
      id: Value(m.id),
      type: Value(m.type),
      content: Value(m.content),
      roleId: Value(m.roleId),
      timestamp: Value(m.timestamp),
      tagsJson: Value(jsonEncode(m.tags)),
    );

// ---- Group ----

Group groupFromRow(GroupRow r) {
  final ids = (jsonDecode(r.roleIdsJson) as List).cast<String>();
  return Group(id: r.id, name: r.name, roleIds: ids);
}

/// 新建群聊时调用——`createdAt` 由当前时间填入，model 不暴露该字段。
GroupRowsCompanion groupToCompanion(Group g, {int? createdAt}) =>
    GroupRowsCompanion(
      id: Value(g.id),
      name: Value(g.name),
      roleIdsJson: Value(jsonEncode(g.roleIds)),
      createdAt: Value(createdAt ?? DateTime.now().millisecondsSinceEpoch),
    );

// ---- Custom Role ----

Role customRoleFromRow(CustomRoleRow r) => Role(
      id: r.id,
      name: r.name,
      icon: r.icon,
      description: r.description,
      color: r.color,
      systemPrompt: r.systemPrompt,
    );

CustomRoleRowsCompanion customRoleToCompanion(Role role) =>
    CustomRoleRowsCompanion(
      id: Value(role.id),
      name: Value(role.name),
      icon: Value(role.icon),
      description: Value(role.description),
      color: Value(role.color),
      systemPrompt: Value(role.systemPrompt),
    );
