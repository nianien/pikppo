// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'database.dart';

// ignore_for_file: type=lint
class $MessageRowsTable extends MessageRows
    with TableInfo<$MessageRowsTable, MessageRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $MessageRowsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _roleIdMeta = const VerificationMeta('roleId');
  @override
  late final GeneratedColumn<String> roleId = GeneratedColumn<String>(
    'role_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _contentMeta = const VerificationMeta(
    'content',
  );
  @override
  late final GeneratedColumn<String> content = GeneratedColumn<String>(
    'content',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _isUserMeta = const VerificationMeta('isUser');
  @override
  late final GeneratedColumn<bool> isUser = GeneratedColumn<bool>(
    'is_user',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("is_user" IN (0, 1))',
    ),
  );
  static const VerificationMeta _timestampMeta = const VerificationMeta(
    'timestamp',
  );
  @override
  late final GeneratedColumn<int> timestamp = GeneratedColumn<int>(
    'timestamp',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _kindMeta = const VerificationMeta('kind');
  @override
  late final GeneratedColumn<String> kind = GeneratedColumn<String>(
    'kind',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('chat'),
  );
  static const VerificationMeta _groupIdMeta = const VerificationMeta(
    'groupId',
  );
  @override
  late final GeneratedColumn<String> groupId = GeneratedColumn<String>(
    'group_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    roleId,
    content,
    isUser,
    timestamp,
    kind,
    groupId,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'messages';
  @override
  VerificationContext validateIntegrity(
    Insertable<MessageRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('role_id')) {
      context.handle(
        _roleIdMeta,
        roleId.isAcceptableOrUnknown(data['role_id']!, _roleIdMeta),
      );
    } else if (isInserting) {
      context.missing(_roleIdMeta);
    }
    if (data.containsKey('content')) {
      context.handle(
        _contentMeta,
        content.isAcceptableOrUnknown(data['content']!, _contentMeta),
      );
    } else if (isInserting) {
      context.missing(_contentMeta);
    }
    if (data.containsKey('is_user')) {
      context.handle(
        _isUserMeta,
        isUser.isAcceptableOrUnknown(data['is_user']!, _isUserMeta),
      );
    } else if (isInserting) {
      context.missing(_isUserMeta);
    }
    if (data.containsKey('timestamp')) {
      context.handle(
        _timestampMeta,
        timestamp.isAcceptableOrUnknown(data['timestamp']!, _timestampMeta),
      );
    } else if (isInserting) {
      context.missing(_timestampMeta);
    }
    if (data.containsKey('kind')) {
      context.handle(
        _kindMeta,
        kind.isAcceptableOrUnknown(data['kind']!, _kindMeta),
      );
    }
    if (data.containsKey('group_id')) {
      context.handle(
        _groupIdMeta,
        groupId.isAcceptableOrUnknown(data['group_id']!, _groupIdMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  MessageRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return MessageRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      roleId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}role_id'],
      )!,
      content: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}content'],
      )!,
      isUser: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}is_user'],
      )!,
      timestamp: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}timestamp'],
      )!,
      kind: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}kind'],
      )!,
      groupId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}group_id'],
      ),
    );
  }

  @override
  $MessageRowsTable createAlias(String alias) {
    return $MessageRowsTable(attachedDatabase, alias);
  }
}

class MessageRow extends DataClass implements Insertable<MessageRow> {
  final String id;
  final String roleId;
  final String content;
  final bool isUser;
  final int timestamp;
  final String kind;
  final String? groupId;
  const MessageRow({
    required this.id,
    required this.roleId,
    required this.content,
    required this.isUser,
    required this.timestamp,
    required this.kind,
    this.groupId,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['role_id'] = Variable<String>(roleId);
    map['content'] = Variable<String>(content);
    map['is_user'] = Variable<bool>(isUser);
    map['timestamp'] = Variable<int>(timestamp);
    map['kind'] = Variable<String>(kind);
    if (!nullToAbsent || groupId != null) {
      map['group_id'] = Variable<String>(groupId);
    }
    return map;
  }

  MessageRowsCompanion toCompanion(bool nullToAbsent) {
    return MessageRowsCompanion(
      id: Value(id),
      roleId: Value(roleId),
      content: Value(content),
      isUser: Value(isUser),
      timestamp: Value(timestamp),
      kind: Value(kind),
      groupId: groupId == null && nullToAbsent
          ? const Value.absent()
          : Value(groupId),
    );
  }

  factory MessageRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return MessageRow(
      id: serializer.fromJson<String>(json['id']),
      roleId: serializer.fromJson<String>(json['roleId']),
      content: serializer.fromJson<String>(json['content']),
      isUser: serializer.fromJson<bool>(json['isUser']),
      timestamp: serializer.fromJson<int>(json['timestamp']),
      kind: serializer.fromJson<String>(json['kind']),
      groupId: serializer.fromJson<String?>(json['groupId']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'roleId': serializer.toJson<String>(roleId),
      'content': serializer.toJson<String>(content),
      'isUser': serializer.toJson<bool>(isUser),
      'timestamp': serializer.toJson<int>(timestamp),
      'kind': serializer.toJson<String>(kind),
      'groupId': serializer.toJson<String?>(groupId),
    };
  }

  MessageRow copyWith({
    String? id,
    String? roleId,
    String? content,
    bool? isUser,
    int? timestamp,
    String? kind,
    Value<String?> groupId = const Value.absent(),
  }) => MessageRow(
    id: id ?? this.id,
    roleId: roleId ?? this.roleId,
    content: content ?? this.content,
    isUser: isUser ?? this.isUser,
    timestamp: timestamp ?? this.timestamp,
    kind: kind ?? this.kind,
    groupId: groupId.present ? groupId.value : this.groupId,
  );
  MessageRow copyWithCompanion(MessageRowsCompanion data) {
    return MessageRow(
      id: data.id.present ? data.id.value : this.id,
      roleId: data.roleId.present ? data.roleId.value : this.roleId,
      content: data.content.present ? data.content.value : this.content,
      isUser: data.isUser.present ? data.isUser.value : this.isUser,
      timestamp: data.timestamp.present ? data.timestamp.value : this.timestamp,
      kind: data.kind.present ? data.kind.value : this.kind,
      groupId: data.groupId.present ? data.groupId.value : this.groupId,
    );
  }

  @override
  String toString() {
    return (StringBuffer('MessageRow(')
          ..write('id: $id, ')
          ..write('roleId: $roleId, ')
          ..write('content: $content, ')
          ..write('isUser: $isUser, ')
          ..write('timestamp: $timestamp, ')
          ..write('kind: $kind, ')
          ..write('groupId: $groupId')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode =>
      Object.hash(id, roleId, content, isUser, timestamp, kind, groupId);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is MessageRow &&
          other.id == this.id &&
          other.roleId == this.roleId &&
          other.content == this.content &&
          other.isUser == this.isUser &&
          other.timestamp == this.timestamp &&
          other.kind == this.kind &&
          other.groupId == this.groupId);
}

class MessageRowsCompanion extends UpdateCompanion<MessageRow> {
  final Value<String> id;
  final Value<String> roleId;
  final Value<String> content;
  final Value<bool> isUser;
  final Value<int> timestamp;
  final Value<String> kind;
  final Value<String?> groupId;
  final Value<int> rowid;
  const MessageRowsCompanion({
    this.id = const Value.absent(),
    this.roleId = const Value.absent(),
    this.content = const Value.absent(),
    this.isUser = const Value.absent(),
    this.timestamp = const Value.absent(),
    this.kind = const Value.absent(),
    this.groupId = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  MessageRowsCompanion.insert({
    required String id,
    required String roleId,
    required String content,
    required bool isUser,
    required int timestamp,
    this.kind = const Value.absent(),
    this.groupId = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       roleId = Value(roleId),
       content = Value(content),
       isUser = Value(isUser),
       timestamp = Value(timestamp);
  static Insertable<MessageRow> custom({
    Expression<String>? id,
    Expression<String>? roleId,
    Expression<String>? content,
    Expression<bool>? isUser,
    Expression<int>? timestamp,
    Expression<String>? kind,
    Expression<String>? groupId,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (roleId != null) 'role_id': roleId,
      if (content != null) 'content': content,
      if (isUser != null) 'is_user': isUser,
      if (timestamp != null) 'timestamp': timestamp,
      if (kind != null) 'kind': kind,
      if (groupId != null) 'group_id': groupId,
      if (rowid != null) 'rowid': rowid,
    });
  }

  MessageRowsCompanion copyWith({
    Value<String>? id,
    Value<String>? roleId,
    Value<String>? content,
    Value<bool>? isUser,
    Value<int>? timestamp,
    Value<String>? kind,
    Value<String?>? groupId,
    Value<int>? rowid,
  }) {
    return MessageRowsCompanion(
      id: id ?? this.id,
      roleId: roleId ?? this.roleId,
      content: content ?? this.content,
      isUser: isUser ?? this.isUser,
      timestamp: timestamp ?? this.timestamp,
      kind: kind ?? this.kind,
      groupId: groupId ?? this.groupId,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (roleId.present) {
      map['role_id'] = Variable<String>(roleId.value);
    }
    if (content.present) {
      map['content'] = Variable<String>(content.value);
    }
    if (isUser.present) {
      map['is_user'] = Variable<bool>(isUser.value);
    }
    if (timestamp.present) {
      map['timestamp'] = Variable<int>(timestamp.value);
    }
    if (kind.present) {
      map['kind'] = Variable<String>(kind.value);
    }
    if (groupId.present) {
      map['group_id'] = Variable<String>(groupId.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('MessageRowsCompanion(')
          ..write('id: $id, ')
          ..write('roleId: $roleId, ')
          ..write('content: $content, ')
          ..write('isUser: $isUser, ')
          ..write('timestamp: $timestamp, ')
          ..write('kind: $kind, ')
          ..write('groupId: $groupId, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $MemoryRowsTable extends MemoryRows
    with TableInfo<$MemoryRowsTable, MemoryRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $MemoryRowsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _typeMeta = const VerificationMeta('type');
  @override
  late final GeneratedColumn<String> type = GeneratedColumn<String>(
    'type',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _contentMeta = const VerificationMeta(
    'content',
  );
  @override
  late final GeneratedColumn<String> content = GeneratedColumn<String>(
    'content',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _roleIdMeta = const VerificationMeta('roleId');
  @override
  late final GeneratedColumn<String> roleId = GeneratedColumn<String>(
    'role_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _timestampMeta = const VerificationMeta(
    'timestamp',
  );
  @override
  late final GeneratedColumn<int> timestamp = GeneratedColumn<int>(
    'timestamp',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _tagsJsonMeta = const VerificationMeta(
    'tagsJson',
  );
  @override
  late final GeneratedColumn<String> tagsJson = GeneratedColumn<String>(
    'tags_json',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('[]'),
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    type,
    content,
    roleId,
    timestamp,
    tagsJson,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'memories';
  @override
  VerificationContext validateIntegrity(
    Insertable<MemoryRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('type')) {
      context.handle(
        _typeMeta,
        type.isAcceptableOrUnknown(data['type']!, _typeMeta),
      );
    } else if (isInserting) {
      context.missing(_typeMeta);
    }
    if (data.containsKey('content')) {
      context.handle(
        _contentMeta,
        content.isAcceptableOrUnknown(data['content']!, _contentMeta),
      );
    } else if (isInserting) {
      context.missing(_contentMeta);
    }
    if (data.containsKey('role_id')) {
      context.handle(
        _roleIdMeta,
        roleId.isAcceptableOrUnknown(data['role_id']!, _roleIdMeta),
      );
    }
    if (data.containsKey('timestamp')) {
      context.handle(
        _timestampMeta,
        timestamp.isAcceptableOrUnknown(data['timestamp']!, _timestampMeta),
      );
    } else if (isInserting) {
      context.missing(_timestampMeta);
    }
    if (data.containsKey('tags_json')) {
      context.handle(
        _tagsJsonMeta,
        tagsJson.isAcceptableOrUnknown(data['tags_json']!, _tagsJsonMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  MemoryRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return MemoryRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      type: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}type'],
      )!,
      content: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}content'],
      )!,
      roleId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}role_id'],
      ),
      timestamp: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}timestamp'],
      )!,
      tagsJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}tags_json'],
      )!,
    );
  }

  @override
  $MemoryRowsTable createAlias(String alias) {
    return $MemoryRowsTable(attachedDatabase, alias);
  }
}

class MemoryRow extends DataClass implements Insertable<MemoryRow> {
  final String id;
  final String type;
  final String content;
  final String? roleId;
  final int timestamp;
  final String tagsJson;
  const MemoryRow({
    required this.id,
    required this.type,
    required this.content,
    this.roleId,
    required this.timestamp,
    required this.tagsJson,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['type'] = Variable<String>(type);
    map['content'] = Variable<String>(content);
    if (!nullToAbsent || roleId != null) {
      map['role_id'] = Variable<String>(roleId);
    }
    map['timestamp'] = Variable<int>(timestamp);
    map['tags_json'] = Variable<String>(tagsJson);
    return map;
  }

  MemoryRowsCompanion toCompanion(bool nullToAbsent) {
    return MemoryRowsCompanion(
      id: Value(id),
      type: Value(type),
      content: Value(content),
      roleId: roleId == null && nullToAbsent
          ? const Value.absent()
          : Value(roleId),
      timestamp: Value(timestamp),
      tagsJson: Value(tagsJson),
    );
  }

  factory MemoryRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return MemoryRow(
      id: serializer.fromJson<String>(json['id']),
      type: serializer.fromJson<String>(json['type']),
      content: serializer.fromJson<String>(json['content']),
      roleId: serializer.fromJson<String?>(json['roleId']),
      timestamp: serializer.fromJson<int>(json['timestamp']),
      tagsJson: serializer.fromJson<String>(json['tagsJson']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'type': serializer.toJson<String>(type),
      'content': serializer.toJson<String>(content),
      'roleId': serializer.toJson<String?>(roleId),
      'timestamp': serializer.toJson<int>(timestamp),
      'tagsJson': serializer.toJson<String>(tagsJson),
    };
  }

  MemoryRow copyWith({
    String? id,
    String? type,
    String? content,
    Value<String?> roleId = const Value.absent(),
    int? timestamp,
    String? tagsJson,
  }) => MemoryRow(
    id: id ?? this.id,
    type: type ?? this.type,
    content: content ?? this.content,
    roleId: roleId.present ? roleId.value : this.roleId,
    timestamp: timestamp ?? this.timestamp,
    tagsJson: tagsJson ?? this.tagsJson,
  );
  MemoryRow copyWithCompanion(MemoryRowsCompanion data) {
    return MemoryRow(
      id: data.id.present ? data.id.value : this.id,
      type: data.type.present ? data.type.value : this.type,
      content: data.content.present ? data.content.value : this.content,
      roleId: data.roleId.present ? data.roleId.value : this.roleId,
      timestamp: data.timestamp.present ? data.timestamp.value : this.timestamp,
      tagsJson: data.tagsJson.present ? data.tagsJson.value : this.tagsJson,
    );
  }

  @override
  String toString() {
    return (StringBuffer('MemoryRow(')
          ..write('id: $id, ')
          ..write('type: $type, ')
          ..write('content: $content, ')
          ..write('roleId: $roleId, ')
          ..write('timestamp: $timestamp, ')
          ..write('tagsJson: $tagsJson')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode =>
      Object.hash(id, type, content, roleId, timestamp, tagsJson);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is MemoryRow &&
          other.id == this.id &&
          other.type == this.type &&
          other.content == this.content &&
          other.roleId == this.roleId &&
          other.timestamp == this.timestamp &&
          other.tagsJson == this.tagsJson);
}

class MemoryRowsCompanion extends UpdateCompanion<MemoryRow> {
  final Value<String> id;
  final Value<String> type;
  final Value<String> content;
  final Value<String?> roleId;
  final Value<int> timestamp;
  final Value<String> tagsJson;
  final Value<int> rowid;
  const MemoryRowsCompanion({
    this.id = const Value.absent(),
    this.type = const Value.absent(),
    this.content = const Value.absent(),
    this.roleId = const Value.absent(),
    this.timestamp = const Value.absent(),
    this.tagsJson = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  MemoryRowsCompanion.insert({
    required String id,
    required String type,
    required String content,
    this.roleId = const Value.absent(),
    required int timestamp,
    this.tagsJson = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       type = Value(type),
       content = Value(content),
       timestamp = Value(timestamp);
  static Insertable<MemoryRow> custom({
    Expression<String>? id,
    Expression<String>? type,
    Expression<String>? content,
    Expression<String>? roleId,
    Expression<int>? timestamp,
    Expression<String>? tagsJson,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (type != null) 'type': type,
      if (content != null) 'content': content,
      if (roleId != null) 'role_id': roleId,
      if (timestamp != null) 'timestamp': timestamp,
      if (tagsJson != null) 'tags_json': tagsJson,
      if (rowid != null) 'rowid': rowid,
    });
  }

  MemoryRowsCompanion copyWith({
    Value<String>? id,
    Value<String>? type,
    Value<String>? content,
    Value<String?>? roleId,
    Value<int>? timestamp,
    Value<String>? tagsJson,
    Value<int>? rowid,
  }) {
    return MemoryRowsCompanion(
      id: id ?? this.id,
      type: type ?? this.type,
      content: content ?? this.content,
      roleId: roleId ?? this.roleId,
      timestamp: timestamp ?? this.timestamp,
      tagsJson: tagsJson ?? this.tagsJson,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (type.present) {
      map['type'] = Variable<String>(type.value);
    }
    if (content.present) {
      map['content'] = Variable<String>(content.value);
    }
    if (roleId.present) {
      map['role_id'] = Variable<String>(roleId.value);
    }
    if (timestamp.present) {
      map['timestamp'] = Variable<int>(timestamp.value);
    }
    if (tagsJson.present) {
      map['tags_json'] = Variable<String>(tagsJson.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('MemoryRowsCompanion(')
          ..write('id: $id, ')
          ..write('type: $type, ')
          ..write('content: $content, ')
          ..write('roleId: $roleId, ')
          ..write('timestamp: $timestamp, ')
          ..write('tagsJson: $tagsJson, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $GroupRowsTable extends GroupRows
    with TableInfo<$GroupRowsTable, GroupRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $GroupRowsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _nameMeta = const VerificationMeta('name');
  @override
  late final GeneratedColumn<String> name = GeneratedColumn<String>(
    'name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _roleIdsJsonMeta = const VerificationMeta(
    'roleIdsJson',
  );
  @override
  late final GeneratedColumn<String> roleIdsJson = GeneratedColumn<String>(
    'role_ids_json',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<int> createdAt = GeneratedColumn<int>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [id, name, roleIdsJson, createdAt];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'groups';
  @override
  VerificationContext validateIntegrity(
    Insertable<GroupRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('name')) {
      context.handle(
        _nameMeta,
        name.isAcceptableOrUnknown(data['name']!, _nameMeta),
      );
    } else if (isInserting) {
      context.missing(_nameMeta);
    }
    if (data.containsKey('role_ids_json')) {
      context.handle(
        _roleIdsJsonMeta,
        roleIdsJson.isAcceptableOrUnknown(
          data['role_ids_json']!,
          _roleIdsJsonMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_roleIdsJsonMeta);
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  GroupRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return GroupRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      name: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}name'],
      )!,
      roleIdsJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}role_ids_json'],
      )!,
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}created_at'],
      )!,
    );
  }

  @override
  $GroupRowsTable createAlias(String alias) {
    return $GroupRowsTable(attachedDatabase, alias);
  }
}

class GroupRow extends DataClass implements Insertable<GroupRow> {
  final String id;
  final String name;
  final String roleIdsJson;
  final int createdAt;
  const GroupRow({
    required this.id,
    required this.name,
    required this.roleIdsJson,
    required this.createdAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['name'] = Variable<String>(name);
    map['role_ids_json'] = Variable<String>(roleIdsJson);
    map['created_at'] = Variable<int>(createdAt);
    return map;
  }

  GroupRowsCompanion toCompanion(bool nullToAbsent) {
    return GroupRowsCompanion(
      id: Value(id),
      name: Value(name),
      roleIdsJson: Value(roleIdsJson),
      createdAt: Value(createdAt),
    );
  }

  factory GroupRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return GroupRow(
      id: serializer.fromJson<String>(json['id']),
      name: serializer.fromJson<String>(json['name']),
      roleIdsJson: serializer.fromJson<String>(json['roleIdsJson']),
      createdAt: serializer.fromJson<int>(json['createdAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'name': serializer.toJson<String>(name),
      'roleIdsJson': serializer.toJson<String>(roleIdsJson),
      'createdAt': serializer.toJson<int>(createdAt),
    };
  }

  GroupRow copyWith({
    String? id,
    String? name,
    String? roleIdsJson,
    int? createdAt,
  }) => GroupRow(
    id: id ?? this.id,
    name: name ?? this.name,
    roleIdsJson: roleIdsJson ?? this.roleIdsJson,
    createdAt: createdAt ?? this.createdAt,
  );
  GroupRow copyWithCompanion(GroupRowsCompanion data) {
    return GroupRow(
      id: data.id.present ? data.id.value : this.id,
      name: data.name.present ? data.name.value : this.name,
      roleIdsJson: data.roleIdsJson.present
          ? data.roleIdsJson.value
          : this.roleIdsJson,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('GroupRow(')
          ..write('id: $id, ')
          ..write('name: $name, ')
          ..write('roleIdsJson: $roleIdsJson, ')
          ..write('createdAt: $createdAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(id, name, roleIdsJson, createdAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is GroupRow &&
          other.id == this.id &&
          other.name == this.name &&
          other.roleIdsJson == this.roleIdsJson &&
          other.createdAt == this.createdAt);
}

class GroupRowsCompanion extends UpdateCompanion<GroupRow> {
  final Value<String> id;
  final Value<String> name;
  final Value<String> roleIdsJson;
  final Value<int> createdAt;
  final Value<int> rowid;
  const GroupRowsCompanion({
    this.id = const Value.absent(),
    this.name = const Value.absent(),
    this.roleIdsJson = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  GroupRowsCompanion.insert({
    required String id,
    required String name,
    required String roleIdsJson,
    required int createdAt,
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       name = Value(name),
       roleIdsJson = Value(roleIdsJson),
       createdAt = Value(createdAt);
  static Insertable<GroupRow> custom({
    Expression<String>? id,
    Expression<String>? name,
    Expression<String>? roleIdsJson,
    Expression<int>? createdAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (name != null) 'name': name,
      if (roleIdsJson != null) 'role_ids_json': roleIdsJson,
      if (createdAt != null) 'created_at': createdAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  GroupRowsCompanion copyWith({
    Value<String>? id,
    Value<String>? name,
    Value<String>? roleIdsJson,
    Value<int>? createdAt,
    Value<int>? rowid,
  }) {
    return GroupRowsCompanion(
      id: id ?? this.id,
      name: name ?? this.name,
      roleIdsJson: roleIdsJson ?? this.roleIdsJson,
      createdAt: createdAt ?? this.createdAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (name.present) {
      map['name'] = Variable<String>(name.value);
    }
    if (roleIdsJson.present) {
      map['role_ids_json'] = Variable<String>(roleIdsJson.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<int>(createdAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('GroupRowsCompanion(')
          ..write('id: $id, ')
          ..write('name: $name, ')
          ..write('roleIdsJson: $roleIdsJson, ')
          ..write('createdAt: $createdAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $CustomRoleRowsTable extends CustomRoleRows
    with TableInfo<$CustomRoleRowsTable, CustomRoleRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $CustomRoleRowsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _nameMeta = const VerificationMeta('name');
  @override
  late final GeneratedColumn<String> name = GeneratedColumn<String>(
    'name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _iconMeta = const VerificationMeta('icon');
  @override
  late final GeneratedColumn<String> icon = GeneratedColumn<String>(
    'icon',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _descriptionMeta = const VerificationMeta(
    'description',
  );
  @override
  late final GeneratedColumn<String> description = GeneratedColumn<String>(
    'description',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _colorMeta = const VerificationMeta('color');
  @override
  late final GeneratedColumn<String> color = GeneratedColumn<String>(
    'color',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _systemPromptMeta = const VerificationMeta(
    'systemPrompt',
  );
  @override
  late final GeneratedColumn<String> systemPrompt = GeneratedColumn<String>(
    'system_prompt',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    name,
    icon,
    description,
    color,
    systemPrompt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'custom_roles';
  @override
  VerificationContext validateIntegrity(
    Insertable<CustomRoleRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('name')) {
      context.handle(
        _nameMeta,
        name.isAcceptableOrUnknown(data['name']!, _nameMeta),
      );
    } else if (isInserting) {
      context.missing(_nameMeta);
    }
    if (data.containsKey('icon')) {
      context.handle(
        _iconMeta,
        icon.isAcceptableOrUnknown(data['icon']!, _iconMeta),
      );
    } else if (isInserting) {
      context.missing(_iconMeta);
    }
    if (data.containsKey('description')) {
      context.handle(
        _descriptionMeta,
        description.isAcceptableOrUnknown(
          data['description']!,
          _descriptionMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_descriptionMeta);
    }
    if (data.containsKey('color')) {
      context.handle(
        _colorMeta,
        color.isAcceptableOrUnknown(data['color']!, _colorMeta),
      );
    } else if (isInserting) {
      context.missing(_colorMeta);
    }
    if (data.containsKey('system_prompt')) {
      context.handle(
        _systemPromptMeta,
        systemPrompt.isAcceptableOrUnknown(
          data['system_prompt']!,
          _systemPromptMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_systemPromptMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  CustomRoleRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return CustomRoleRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      name: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}name'],
      )!,
      icon: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}icon'],
      )!,
      description: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}description'],
      )!,
      color: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}color'],
      )!,
      systemPrompt: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}system_prompt'],
      )!,
    );
  }

  @override
  $CustomRoleRowsTable createAlias(String alias) {
    return $CustomRoleRowsTable(attachedDatabase, alias);
  }
}

class CustomRoleRow extends DataClass implements Insertable<CustomRoleRow> {
  final String id;
  final String name;
  final String icon;
  final String description;
  final String color;
  final String systemPrompt;
  const CustomRoleRow({
    required this.id,
    required this.name,
    required this.icon,
    required this.description,
    required this.color,
    required this.systemPrompt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['name'] = Variable<String>(name);
    map['icon'] = Variable<String>(icon);
    map['description'] = Variable<String>(description);
    map['color'] = Variable<String>(color);
    map['system_prompt'] = Variable<String>(systemPrompt);
    return map;
  }

  CustomRoleRowsCompanion toCompanion(bool nullToAbsent) {
    return CustomRoleRowsCompanion(
      id: Value(id),
      name: Value(name),
      icon: Value(icon),
      description: Value(description),
      color: Value(color),
      systemPrompt: Value(systemPrompt),
    );
  }

  factory CustomRoleRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return CustomRoleRow(
      id: serializer.fromJson<String>(json['id']),
      name: serializer.fromJson<String>(json['name']),
      icon: serializer.fromJson<String>(json['icon']),
      description: serializer.fromJson<String>(json['description']),
      color: serializer.fromJson<String>(json['color']),
      systemPrompt: serializer.fromJson<String>(json['systemPrompt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'name': serializer.toJson<String>(name),
      'icon': serializer.toJson<String>(icon),
      'description': serializer.toJson<String>(description),
      'color': serializer.toJson<String>(color),
      'systemPrompt': serializer.toJson<String>(systemPrompt),
    };
  }

  CustomRoleRow copyWith({
    String? id,
    String? name,
    String? icon,
    String? description,
    String? color,
    String? systemPrompt,
  }) => CustomRoleRow(
    id: id ?? this.id,
    name: name ?? this.name,
    icon: icon ?? this.icon,
    description: description ?? this.description,
    color: color ?? this.color,
    systemPrompt: systemPrompt ?? this.systemPrompt,
  );
  CustomRoleRow copyWithCompanion(CustomRoleRowsCompanion data) {
    return CustomRoleRow(
      id: data.id.present ? data.id.value : this.id,
      name: data.name.present ? data.name.value : this.name,
      icon: data.icon.present ? data.icon.value : this.icon,
      description: data.description.present
          ? data.description.value
          : this.description,
      color: data.color.present ? data.color.value : this.color,
      systemPrompt: data.systemPrompt.present
          ? data.systemPrompt.value
          : this.systemPrompt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('CustomRoleRow(')
          ..write('id: $id, ')
          ..write('name: $name, ')
          ..write('icon: $icon, ')
          ..write('description: $description, ')
          ..write('color: $color, ')
          ..write('systemPrompt: $systemPrompt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode =>
      Object.hash(id, name, icon, description, color, systemPrompt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is CustomRoleRow &&
          other.id == this.id &&
          other.name == this.name &&
          other.icon == this.icon &&
          other.description == this.description &&
          other.color == this.color &&
          other.systemPrompt == this.systemPrompt);
}

class CustomRoleRowsCompanion extends UpdateCompanion<CustomRoleRow> {
  final Value<String> id;
  final Value<String> name;
  final Value<String> icon;
  final Value<String> description;
  final Value<String> color;
  final Value<String> systemPrompt;
  final Value<int> rowid;
  const CustomRoleRowsCompanion({
    this.id = const Value.absent(),
    this.name = const Value.absent(),
    this.icon = const Value.absent(),
    this.description = const Value.absent(),
    this.color = const Value.absent(),
    this.systemPrompt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  CustomRoleRowsCompanion.insert({
    required String id,
    required String name,
    required String icon,
    required String description,
    required String color,
    required String systemPrompt,
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       name = Value(name),
       icon = Value(icon),
       description = Value(description),
       color = Value(color),
       systemPrompt = Value(systemPrompt);
  static Insertable<CustomRoleRow> custom({
    Expression<String>? id,
    Expression<String>? name,
    Expression<String>? icon,
    Expression<String>? description,
    Expression<String>? color,
    Expression<String>? systemPrompt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (name != null) 'name': name,
      if (icon != null) 'icon': icon,
      if (description != null) 'description': description,
      if (color != null) 'color': color,
      if (systemPrompt != null) 'system_prompt': systemPrompt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  CustomRoleRowsCompanion copyWith({
    Value<String>? id,
    Value<String>? name,
    Value<String>? icon,
    Value<String>? description,
    Value<String>? color,
    Value<String>? systemPrompt,
    Value<int>? rowid,
  }) {
    return CustomRoleRowsCompanion(
      id: id ?? this.id,
      name: name ?? this.name,
      icon: icon ?? this.icon,
      description: description ?? this.description,
      color: color ?? this.color,
      systemPrompt: systemPrompt ?? this.systemPrompt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (name.present) {
      map['name'] = Variable<String>(name.value);
    }
    if (icon.present) {
      map['icon'] = Variable<String>(icon.value);
    }
    if (description.present) {
      map['description'] = Variable<String>(description.value);
    }
    if (color.present) {
      map['color'] = Variable<String>(color.value);
    }
    if (systemPrompt.present) {
      map['system_prompt'] = Variable<String>(systemPrompt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('CustomRoleRowsCompanion(')
          ..write('id: $id, ')
          ..write('name: $name, ')
          ..write('icon: $icon, ')
          ..write('description: $description, ')
          ..write('color: $color, ')
          ..write('systemPrompt: $systemPrompt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

abstract class _$PikppoDatabase extends GeneratedDatabase {
  _$PikppoDatabase(QueryExecutor e) : super(e);
  $PikppoDatabaseManager get managers => $PikppoDatabaseManager(this);
  late final $MessageRowsTable messageRows = $MessageRowsTable(this);
  late final $MemoryRowsTable memoryRows = $MemoryRowsTable(this);
  late final $GroupRowsTable groupRows = $GroupRowsTable(this);
  late final $CustomRoleRowsTable customRoleRows = $CustomRoleRowsTable(this);
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [
    messageRows,
    memoryRows,
    groupRows,
    customRoleRows,
  ];
}

typedef $$MessageRowsTableCreateCompanionBuilder =
    MessageRowsCompanion Function({
      required String id,
      required String roleId,
      required String content,
      required bool isUser,
      required int timestamp,
      Value<String> kind,
      Value<String?> groupId,
      Value<int> rowid,
    });
typedef $$MessageRowsTableUpdateCompanionBuilder =
    MessageRowsCompanion Function({
      Value<String> id,
      Value<String> roleId,
      Value<String> content,
      Value<bool> isUser,
      Value<int> timestamp,
      Value<String> kind,
      Value<String?> groupId,
      Value<int> rowid,
    });

class $$MessageRowsTableFilterComposer
    extends Composer<_$PikppoDatabase, $MessageRowsTable> {
  $$MessageRowsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get roleId => $composableBuilder(
    column: $table.roleId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get content => $composableBuilder(
    column: $table.content,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get isUser => $composableBuilder(
    column: $table.isUser,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get timestamp => $composableBuilder(
    column: $table.timestamp,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get kind => $composableBuilder(
    column: $table.kind,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get groupId => $composableBuilder(
    column: $table.groupId,
    builder: (column) => ColumnFilters(column),
  );
}

class $$MessageRowsTableOrderingComposer
    extends Composer<_$PikppoDatabase, $MessageRowsTable> {
  $$MessageRowsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get roleId => $composableBuilder(
    column: $table.roleId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get content => $composableBuilder(
    column: $table.content,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get isUser => $composableBuilder(
    column: $table.isUser,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get timestamp => $composableBuilder(
    column: $table.timestamp,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get kind => $composableBuilder(
    column: $table.kind,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get groupId => $composableBuilder(
    column: $table.groupId,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$MessageRowsTableAnnotationComposer
    extends Composer<_$PikppoDatabase, $MessageRowsTable> {
  $$MessageRowsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get roleId =>
      $composableBuilder(column: $table.roleId, builder: (column) => column);

  GeneratedColumn<String> get content =>
      $composableBuilder(column: $table.content, builder: (column) => column);

  GeneratedColumn<bool> get isUser =>
      $composableBuilder(column: $table.isUser, builder: (column) => column);

  GeneratedColumn<int> get timestamp =>
      $composableBuilder(column: $table.timestamp, builder: (column) => column);

  GeneratedColumn<String> get kind =>
      $composableBuilder(column: $table.kind, builder: (column) => column);

  GeneratedColumn<String> get groupId =>
      $composableBuilder(column: $table.groupId, builder: (column) => column);
}

class $$MessageRowsTableTableManager
    extends
        RootTableManager<
          _$PikppoDatabase,
          $MessageRowsTable,
          MessageRow,
          $$MessageRowsTableFilterComposer,
          $$MessageRowsTableOrderingComposer,
          $$MessageRowsTableAnnotationComposer,
          $$MessageRowsTableCreateCompanionBuilder,
          $$MessageRowsTableUpdateCompanionBuilder,
          (
            MessageRow,
            BaseReferences<_$PikppoDatabase, $MessageRowsTable, MessageRow>,
          ),
          MessageRow,
          PrefetchHooks Function()
        > {
  $$MessageRowsTableTableManager(_$PikppoDatabase db, $MessageRowsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$MessageRowsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$MessageRowsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$MessageRowsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> roleId = const Value.absent(),
                Value<String> content = const Value.absent(),
                Value<bool> isUser = const Value.absent(),
                Value<int> timestamp = const Value.absent(),
                Value<String> kind = const Value.absent(),
                Value<String?> groupId = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => MessageRowsCompanion(
                id: id,
                roleId: roleId,
                content: content,
                isUser: isUser,
                timestamp: timestamp,
                kind: kind,
                groupId: groupId,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String roleId,
                required String content,
                required bool isUser,
                required int timestamp,
                Value<String> kind = const Value.absent(),
                Value<String?> groupId = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => MessageRowsCompanion.insert(
                id: id,
                roleId: roleId,
                content: content,
                isUser: isUser,
                timestamp: timestamp,
                kind: kind,
                groupId: groupId,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$MessageRowsTableProcessedTableManager =
    ProcessedTableManager<
      _$PikppoDatabase,
      $MessageRowsTable,
      MessageRow,
      $$MessageRowsTableFilterComposer,
      $$MessageRowsTableOrderingComposer,
      $$MessageRowsTableAnnotationComposer,
      $$MessageRowsTableCreateCompanionBuilder,
      $$MessageRowsTableUpdateCompanionBuilder,
      (
        MessageRow,
        BaseReferences<_$PikppoDatabase, $MessageRowsTable, MessageRow>,
      ),
      MessageRow,
      PrefetchHooks Function()
    >;
typedef $$MemoryRowsTableCreateCompanionBuilder =
    MemoryRowsCompanion Function({
      required String id,
      required String type,
      required String content,
      Value<String?> roleId,
      required int timestamp,
      Value<String> tagsJson,
      Value<int> rowid,
    });
typedef $$MemoryRowsTableUpdateCompanionBuilder =
    MemoryRowsCompanion Function({
      Value<String> id,
      Value<String> type,
      Value<String> content,
      Value<String?> roleId,
      Value<int> timestamp,
      Value<String> tagsJson,
      Value<int> rowid,
    });

class $$MemoryRowsTableFilterComposer
    extends Composer<_$PikppoDatabase, $MemoryRowsTable> {
  $$MemoryRowsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get type => $composableBuilder(
    column: $table.type,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get content => $composableBuilder(
    column: $table.content,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get roleId => $composableBuilder(
    column: $table.roleId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get timestamp => $composableBuilder(
    column: $table.timestamp,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get tagsJson => $composableBuilder(
    column: $table.tagsJson,
    builder: (column) => ColumnFilters(column),
  );
}

class $$MemoryRowsTableOrderingComposer
    extends Composer<_$PikppoDatabase, $MemoryRowsTable> {
  $$MemoryRowsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get type => $composableBuilder(
    column: $table.type,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get content => $composableBuilder(
    column: $table.content,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get roleId => $composableBuilder(
    column: $table.roleId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get timestamp => $composableBuilder(
    column: $table.timestamp,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get tagsJson => $composableBuilder(
    column: $table.tagsJson,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$MemoryRowsTableAnnotationComposer
    extends Composer<_$PikppoDatabase, $MemoryRowsTable> {
  $$MemoryRowsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get type =>
      $composableBuilder(column: $table.type, builder: (column) => column);

  GeneratedColumn<String> get content =>
      $composableBuilder(column: $table.content, builder: (column) => column);

  GeneratedColumn<String> get roleId =>
      $composableBuilder(column: $table.roleId, builder: (column) => column);

  GeneratedColumn<int> get timestamp =>
      $composableBuilder(column: $table.timestamp, builder: (column) => column);

  GeneratedColumn<String> get tagsJson =>
      $composableBuilder(column: $table.tagsJson, builder: (column) => column);
}

class $$MemoryRowsTableTableManager
    extends
        RootTableManager<
          _$PikppoDatabase,
          $MemoryRowsTable,
          MemoryRow,
          $$MemoryRowsTableFilterComposer,
          $$MemoryRowsTableOrderingComposer,
          $$MemoryRowsTableAnnotationComposer,
          $$MemoryRowsTableCreateCompanionBuilder,
          $$MemoryRowsTableUpdateCompanionBuilder,
          (
            MemoryRow,
            BaseReferences<_$PikppoDatabase, $MemoryRowsTable, MemoryRow>,
          ),
          MemoryRow,
          PrefetchHooks Function()
        > {
  $$MemoryRowsTableTableManager(_$PikppoDatabase db, $MemoryRowsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$MemoryRowsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$MemoryRowsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$MemoryRowsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> type = const Value.absent(),
                Value<String> content = const Value.absent(),
                Value<String?> roleId = const Value.absent(),
                Value<int> timestamp = const Value.absent(),
                Value<String> tagsJson = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => MemoryRowsCompanion(
                id: id,
                type: type,
                content: content,
                roleId: roleId,
                timestamp: timestamp,
                tagsJson: tagsJson,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String type,
                required String content,
                Value<String?> roleId = const Value.absent(),
                required int timestamp,
                Value<String> tagsJson = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => MemoryRowsCompanion.insert(
                id: id,
                type: type,
                content: content,
                roleId: roleId,
                timestamp: timestamp,
                tagsJson: tagsJson,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$MemoryRowsTableProcessedTableManager =
    ProcessedTableManager<
      _$PikppoDatabase,
      $MemoryRowsTable,
      MemoryRow,
      $$MemoryRowsTableFilterComposer,
      $$MemoryRowsTableOrderingComposer,
      $$MemoryRowsTableAnnotationComposer,
      $$MemoryRowsTableCreateCompanionBuilder,
      $$MemoryRowsTableUpdateCompanionBuilder,
      (
        MemoryRow,
        BaseReferences<_$PikppoDatabase, $MemoryRowsTable, MemoryRow>,
      ),
      MemoryRow,
      PrefetchHooks Function()
    >;
typedef $$GroupRowsTableCreateCompanionBuilder =
    GroupRowsCompanion Function({
      required String id,
      required String name,
      required String roleIdsJson,
      required int createdAt,
      Value<int> rowid,
    });
typedef $$GroupRowsTableUpdateCompanionBuilder =
    GroupRowsCompanion Function({
      Value<String> id,
      Value<String> name,
      Value<String> roleIdsJson,
      Value<int> createdAt,
      Value<int> rowid,
    });

class $$GroupRowsTableFilterComposer
    extends Composer<_$PikppoDatabase, $GroupRowsTable> {
  $$GroupRowsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get roleIdsJson => $composableBuilder(
    column: $table.roleIdsJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$GroupRowsTableOrderingComposer
    extends Composer<_$PikppoDatabase, $GroupRowsTable> {
  $$GroupRowsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get roleIdsJson => $composableBuilder(
    column: $table.roleIdsJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$GroupRowsTableAnnotationComposer
    extends Composer<_$PikppoDatabase, $GroupRowsTable> {
  $$GroupRowsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get name =>
      $composableBuilder(column: $table.name, builder: (column) => column);

  GeneratedColumn<String> get roleIdsJson => $composableBuilder(
    column: $table.roleIdsJson,
    builder: (column) => column,
  );

  GeneratedColumn<int> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);
}

class $$GroupRowsTableTableManager
    extends
        RootTableManager<
          _$PikppoDatabase,
          $GroupRowsTable,
          GroupRow,
          $$GroupRowsTableFilterComposer,
          $$GroupRowsTableOrderingComposer,
          $$GroupRowsTableAnnotationComposer,
          $$GroupRowsTableCreateCompanionBuilder,
          $$GroupRowsTableUpdateCompanionBuilder,
          (
            GroupRow,
            BaseReferences<_$PikppoDatabase, $GroupRowsTable, GroupRow>,
          ),
          GroupRow,
          PrefetchHooks Function()
        > {
  $$GroupRowsTableTableManager(_$PikppoDatabase db, $GroupRowsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$GroupRowsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$GroupRowsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$GroupRowsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> name = const Value.absent(),
                Value<String> roleIdsJson = const Value.absent(),
                Value<int> createdAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => GroupRowsCompanion(
                id: id,
                name: name,
                roleIdsJson: roleIdsJson,
                createdAt: createdAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String name,
                required String roleIdsJson,
                required int createdAt,
                Value<int> rowid = const Value.absent(),
              }) => GroupRowsCompanion.insert(
                id: id,
                name: name,
                roleIdsJson: roleIdsJson,
                createdAt: createdAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$GroupRowsTableProcessedTableManager =
    ProcessedTableManager<
      _$PikppoDatabase,
      $GroupRowsTable,
      GroupRow,
      $$GroupRowsTableFilterComposer,
      $$GroupRowsTableOrderingComposer,
      $$GroupRowsTableAnnotationComposer,
      $$GroupRowsTableCreateCompanionBuilder,
      $$GroupRowsTableUpdateCompanionBuilder,
      (GroupRow, BaseReferences<_$PikppoDatabase, $GroupRowsTable, GroupRow>),
      GroupRow,
      PrefetchHooks Function()
    >;
typedef $$CustomRoleRowsTableCreateCompanionBuilder =
    CustomRoleRowsCompanion Function({
      required String id,
      required String name,
      required String icon,
      required String description,
      required String color,
      required String systemPrompt,
      Value<int> rowid,
    });
typedef $$CustomRoleRowsTableUpdateCompanionBuilder =
    CustomRoleRowsCompanion Function({
      Value<String> id,
      Value<String> name,
      Value<String> icon,
      Value<String> description,
      Value<String> color,
      Value<String> systemPrompt,
      Value<int> rowid,
    });

class $$CustomRoleRowsTableFilterComposer
    extends Composer<_$PikppoDatabase, $CustomRoleRowsTable> {
  $$CustomRoleRowsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get icon => $composableBuilder(
    column: $table.icon,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get description => $composableBuilder(
    column: $table.description,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get color => $composableBuilder(
    column: $table.color,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get systemPrompt => $composableBuilder(
    column: $table.systemPrompt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$CustomRoleRowsTableOrderingComposer
    extends Composer<_$PikppoDatabase, $CustomRoleRowsTable> {
  $$CustomRoleRowsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get icon => $composableBuilder(
    column: $table.icon,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get description => $composableBuilder(
    column: $table.description,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get color => $composableBuilder(
    column: $table.color,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get systemPrompt => $composableBuilder(
    column: $table.systemPrompt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$CustomRoleRowsTableAnnotationComposer
    extends Composer<_$PikppoDatabase, $CustomRoleRowsTable> {
  $$CustomRoleRowsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get name =>
      $composableBuilder(column: $table.name, builder: (column) => column);

  GeneratedColumn<String> get icon =>
      $composableBuilder(column: $table.icon, builder: (column) => column);

  GeneratedColumn<String> get description => $composableBuilder(
    column: $table.description,
    builder: (column) => column,
  );

  GeneratedColumn<String> get color =>
      $composableBuilder(column: $table.color, builder: (column) => column);

  GeneratedColumn<String> get systemPrompt => $composableBuilder(
    column: $table.systemPrompt,
    builder: (column) => column,
  );
}

class $$CustomRoleRowsTableTableManager
    extends
        RootTableManager<
          _$PikppoDatabase,
          $CustomRoleRowsTable,
          CustomRoleRow,
          $$CustomRoleRowsTableFilterComposer,
          $$CustomRoleRowsTableOrderingComposer,
          $$CustomRoleRowsTableAnnotationComposer,
          $$CustomRoleRowsTableCreateCompanionBuilder,
          $$CustomRoleRowsTableUpdateCompanionBuilder,
          (
            CustomRoleRow,
            BaseReferences<
              _$PikppoDatabase,
              $CustomRoleRowsTable,
              CustomRoleRow
            >,
          ),
          CustomRoleRow,
          PrefetchHooks Function()
        > {
  $$CustomRoleRowsTableTableManager(
    _$PikppoDatabase db,
    $CustomRoleRowsTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$CustomRoleRowsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$CustomRoleRowsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$CustomRoleRowsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> name = const Value.absent(),
                Value<String> icon = const Value.absent(),
                Value<String> description = const Value.absent(),
                Value<String> color = const Value.absent(),
                Value<String> systemPrompt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => CustomRoleRowsCompanion(
                id: id,
                name: name,
                icon: icon,
                description: description,
                color: color,
                systemPrompt: systemPrompt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String name,
                required String icon,
                required String description,
                required String color,
                required String systemPrompt,
                Value<int> rowid = const Value.absent(),
              }) => CustomRoleRowsCompanion.insert(
                id: id,
                name: name,
                icon: icon,
                description: description,
                color: color,
                systemPrompt: systemPrompt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$CustomRoleRowsTableProcessedTableManager =
    ProcessedTableManager<
      _$PikppoDatabase,
      $CustomRoleRowsTable,
      CustomRoleRow,
      $$CustomRoleRowsTableFilterComposer,
      $$CustomRoleRowsTableOrderingComposer,
      $$CustomRoleRowsTableAnnotationComposer,
      $$CustomRoleRowsTableCreateCompanionBuilder,
      $$CustomRoleRowsTableUpdateCompanionBuilder,
      (
        CustomRoleRow,
        BaseReferences<_$PikppoDatabase, $CustomRoleRowsTable, CustomRoleRow>,
      ),
      CustomRoleRow,
      PrefetchHooks Function()
    >;

class $PikppoDatabaseManager {
  final _$PikppoDatabase _db;
  $PikppoDatabaseManager(this._db);
  $$MessageRowsTableTableManager get messageRows =>
      $$MessageRowsTableTableManager(_db, _db.messageRows);
  $$MemoryRowsTableTableManager get memoryRows =>
      $$MemoryRowsTableTableManager(_db, _db.memoryRows);
  $$GroupRowsTableTableManager get groupRows =>
      $$GroupRowsTableTableManager(_db, _db.groupRows);
  $$CustomRoleRowsTableTableManager get customRoleRows =>
      $$CustomRoleRowsTableTableManager(_db, _db.customRoleRows);
}
