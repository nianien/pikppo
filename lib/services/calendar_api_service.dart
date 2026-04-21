import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;
import '../models/calendar_event.dart';

class CalendarApiService {
  static CalendarApiService? _instance;
  static Database? _db;

  CalendarApiService._();

  static CalendarApiService get instance {
    _instance ??= CalendarApiService._();
    return _instance!;
  }

  Future<Database> get db async {
    _db ??= await _initDb();
    return _db!;
  }

  Future<Database> _initDb() async {
    final dbPath = await getDatabasesPath();
    final path = p.join(dbPath, 'pikppo_calendar.db');

    return openDatabase(
      path,
      version: 1,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE calendar_events (
            id TEXT PRIMARY KEY,
            title TEXT NOT NULL,
            date TEXT NOT NULL,
            time TEXT,
            end_time TEXT,
            description TEXT,
            reminder_minutes INTEGER,
            created_at TEXT DEFAULT (datetime('now')),
            updated_at TEXT DEFAULT (datetime('now'))
          )
        ''');
        await db.execute('''
          CREATE INDEX idx_events_date ON calendar_events(date)
        ''');
      },
    );
  }

  // --- CRUD API ---

  /// GET /api/events?start=YYYY-MM-DD&end=YYYY-MM-DD
  Future<List<CalendarEvent>> listEvents({String? startDate, String? endDate}) async {
    final database = await db;
    String where = '1=1';
    final args = <String>[];

    if (startDate != null) {
      where += ' AND date >= ?';
      args.add(startDate);
    }
    if (endDate != null) {
      where += ' AND date <= ?';
      args.add(endDate);
    }

    final rows = await database.query(
      'calendar_events',
      where: where,
      whereArgs: args,
      orderBy: 'date ASC, time ASC',
    );

    return rows.map(_rowToEvent).toList();
  }

  /// GET /api/events/:id
  Future<CalendarEvent?> getEvent(String id) async {
    final database = await db;
    final rows = await database.query(
      'calendar_events',
      where: 'id = ?',
      whereArgs: [id],
    );
    if (rows.isEmpty) return null;
    return _rowToEvent(rows.first);
  }

  /// POST /api/events
  Future<CalendarEvent> createEvent(CalendarEvent event) async {
    final database = await db;
    final now = DateTime.now().toIso8601String();
    await database.insert('calendar_events', {
      'id': event.id,
      'title': event.title,
      'date': _formatDate(event.date),
      'time': event.time,
      'end_time': event.endTime,
      'description': event.description,
      'reminder_minutes': event.reminderMinutes,
      'created_at': now,
      'updated_at': now,
    });
    return event;
  }

  /// PUT /api/events/:id
  Future<CalendarEvent?> updateEvent(CalendarEvent event) async {
    final database = await db;
    final count = await database.update(
      'calendar_events',
      {
        'title': event.title,
        'date': _formatDate(event.date),
        'time': event.time,
        'end_time': event.endTime,
        'description': event.description,
        'reminder_minutes': event.reminderMinutes,
        'updated_at': DateTime.now().toIso8601String(),
      },
      where: 'id = ?',
      whereArgs: [event.id],
    );
    if (count == 0) return null;
    return event;
  }

  /// DELETE /api/events/:id
  Future<bool> deleteEvent(String id) async {
    final database = await db;
    final count = await database.delete(
      'calendar_events',
      where: 'id = ?',
      whereArgs: [id],
    );
    return count > 0;
  }

  // --- Helpers ---

  String _formatDate(DateTime date) {
    return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
  }

  CalendarEvent _rowToEvent(Map<String, dynamic> row) {
    final dateParts = (row['date'] as String).split('-');
    return CalendarEvent(
      id: row['id'] as String,
      title: row['title'] as String,
      date: DateTime(
        int.parse(dateParts[0]),
        int.parse(dateParts[1]),
        int.parse(dateParts[2]),
      ),
      time: row['time'] as String?,
      endTime: row['end_time'] as String?,
      description: row['description'] as String?,
      reminderMinutes: row['reminder_minutes'] as int?,
    );
  }
}
