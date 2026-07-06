// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'knowledge_dao.dart';

// ignore_for_file: type=lint
mixin _$KnowledgeDaoMixin on DatabaseAccessor<PikppoDatabase> {
  $KnowledgeCardRowsTable get knowledgeCardRows =>
      attachedDatabase.knowledgeCardRows;
  $CardTagRowsTable get cardTagRows => attachedDatabase.cardTagRows;
  $TagRowsTable get tagRows => attachedDatabase.tagRows;
  KnowledgeDaoManager get managers => KnowledgeDaoManager(this);
}

class KnowledgeDaoManager {
  final _$KnowledgeDaoMixin _db;
  KnowledgeDaoManager(this._db);
  $$KnowledgeCardRowsTableTableManager get knowledgeCardRows =>
      $$KnowledgeCardRowsTableTableManager(
        _db.attachedDatabase,
        _db.knowledgeCardRows,
      );
  $$CardTagRowsTableTableManager get cardTagRows =>
      $$CardTagRowsTableTableManager(_db.attachedDatabase, _db.cardTagRows);
  $$TagRowsTableTableManager get tagRows =>
      $$TagRowsTableTableManager(_db.attachedDatabase, _db.tagRows);
}
