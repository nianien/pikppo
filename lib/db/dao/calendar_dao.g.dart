// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'calendar_dao.dart';

// ignore_for_file: type=lint
mixin _$CalendarDaoMixin on DatabaseAccessor<PikppoDatabase> {
  $CalendarEventRowsTable get calendarEventRows =>
      attachedDatabase.calendarEventRows;
  CalendarDaoManager get managers => CalendarDaoManager(this);
}

class CalendarDaoManager {
  final _$CalendarDaoMixin _db;
  CalendarDaoManager(this._db);
  $$CalendarEventRowsTableTableManager get calendarEventRows =>
      $$CalendarEventRowsTableTableManager(
        _db.attachedDatabase,
        _db.calendarEventRows,
      );
}
