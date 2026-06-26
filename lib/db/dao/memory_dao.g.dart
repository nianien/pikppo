// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'memory_dao.dart';

// ignore_for_file: type=lint
mixin _$MemoryDaoMixin on DatabaseAccessor<PikppoDatabase> {
  $MemoryRowsTable get memoryRows => attachedDatabase.memoryRows;
  MemoryDaoManager get managers => MemoryDaoManager(this);
}

class MemoryDaoManager {
  final _$MemoryDaoMixin _db;
  MemoryDaoManager(this._db);
  $$MemoryRowsTableTableManager get memoryRows =>
      $$MemoryRowsTableTableManager(_db.attachedDatabase, _db.memoryRows);
}
