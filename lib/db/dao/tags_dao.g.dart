// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'tags_dao.dart';

// ignore_for_file: type=lint
mixin _$TagsDaoMixin on DatabaseAccessor<PikppoDatabase> {
  $TagRowsTable get tagRows => attachedDatabase.tagRows;
  $CardTagRowsTable get cardTagRows => attachedDatabase.cardTagRows;
  TagsDaoManager get managers => TagsDaoManager(this);
}

class TagsDaoManager {
  final _$TagsDaoMixin _db;
  TagsDaoManager(this._db);
  $$TagRowsTableTableManager get tagRows =>
      $$TagRowsTableTableManager(_db.attachedDatabase, _db.tagRows);
  $$CardTagRowsTableTableManager get cardTagRows =>
      $$CardTagRowsTableTableManager(_db.attachedDatabase, _db.cardTagRows);
}
