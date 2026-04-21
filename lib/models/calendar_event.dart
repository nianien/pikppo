class CalendarEvent {
  final String id;
  final String title;
  final DateTime date;
  final String? time;
  final String? endTime;
  final String? description;
  final int? reminderMinutes;

  const CalendarEvent({
    required this.id,
    required this.title,
    required this.date,
    this.time,
    this.endTime,
    this.description,
    this.reminderMinutes,
  });

  CalendarEvent copyWith({
    String? title,
    DateTime? date,
    String? time,
    String? endTime,
    String? description,
    int? reminderMinutes,
    bool clearTime = false,
    bool clearEndTime = false,
    bool clearDescription = false,
    bool clearReminder = false,
  }) {
    return CalendarEvent(
      id: id,
      title: title ?? this.title,
      date: date ?? this.date,
      time: clearTime ? null : (time ?? this.time),
      endTime: clearEndTime ? null : (endTime ?? this.endTime),
      description: clearDescription ? null : (description ?? this.description),
      reminderMinutes: clearReminder ? null : (reminderMinutes ?? this.reminderMinutes),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'date': '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}',
        'time': time,
        'end_time': endTime,
        'description': description,
        'reminder_minutes': reminderMinutes,
      };

  factory CalendarEvent.fromJson(Map<String, dynamic> json) {
    DateTime date;
    if (json['date'] is int) {
      date = DateTime.fromMillisecondsSinceEpoch(json['date'] as int);
    } else {
      final parts = (json['date'] as String).split('-');
      date = DateTime(int.parse(parts[0]), int.parse(parts[1]), int.parse(parts[2]));
    }
    return CalendarEvent(
      id: json['id'] as String,
      title: json['title'] as String,
      date: date,
      time: json['time'] as String?,
      endTime: (json['end_time'] ?? json['endTime']) as String?,
      description: json['description'] as String?,
      reminderMinutes: (json['reminder_minutes'] ?? json['reminderMinutes']) as int?,
    );
  }

  String? get reminderText {
    if (reminderMinutes == null) return null;
    if (reminderMinutes! >= 1440) return '提前${reminderMinutes! ~/ 1440}天';
    if (reminderMinutes! >= 60) return '提前${reminderMinutes! ~/ 60}小时';
    return '提前$reminderMinutes分钟';
  }
}
