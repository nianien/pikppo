import 'dart:async';
import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import '../models/app_state.dart';
import '../models/role.dart';
import '../models/message.dart';
import '../models/memory.dart';
import '../models/group.dart';
import '../models/calendar_event.dart';
import '../data/mock_data.dart';
import '../services/model_service.dart';
import '../services/ollama_service.dart';
import '../services/lmstudio_service.dart';
import '../services/calendar_api_service.dart';

const _uuid = Uuid();

final appStateProvider =
    StateNotifierProvider<AppStateNotifier, AppState>((ref) {
  return AppStateNotifier();
});

class AppStateNotifier extends StateNotifier<AppState> {
  Timer? _reminderTimer;
  final Set<String> _remindedEventIds = {};

  AppStateNotifier()
      : super(AppState(
          roles: defaultRoles,
          messages: defaultMessages,
          memories: defaultMemories,
          currentRoleId: 'work',
          currentModel: '',
          serviceType: 'ollama',
          serviceHost: 'http://10.0.2.2:11434',
        )) {
    _loadState();
    _startReminderCheck();
  }

  @override
  void dispose() {
    _reminderTimer?.cancel();
    super.dispose();
  }

  void _startReminderCheck() {
    // Check every 30 seconds for upcoming events
    _reminderTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      _checkUpcomingEvents();
    });
  }

  void _checkUpcomingEvents() {
    final now = DateTime.now();
    for (final event in state.calendarEvents) {
      if (event.time == null) continue;
      if (event.reminderMinutes == null) continue;

      final parts = event.time!.split(':');
      if (parts.length != 2) continue;

      final eventDateTime = DateTime(
        event.date.year,
        event.date.month,
        event.date.day,
        int.parse(parts[0]),
        int.parse(parts[1]),
      );

      final diffMinutes = eventDateTime.difference(now).inMinutes;

      // Trigger reminder when within the reminder window
      if (diffMinutes > 0 &&
          diffMinutes <= event.reminderMinutes! &&
          !_remindedEventIds.contains(event.id)) {
        _remindedEventIds.add(event.id);
        final desc = event.description != null ? '\n${event.description}' : '';
        String timeHint;
        if (diffMinutes >= 60) {
          timeHint = '约${diffMinutes ~/ 60}小时后';
        } else {
          timeHint = '$diffMinutes分钟后';
        }
        _addReminderMessage(
          '⏰ 日程提醒（$timeHint开始）\n'
          '${event.time} ${event.title}$desc',
        );
      }
    }
  }

  void _addReminderMessage(String content) {
    // Add reminder to current role's chat
    final msg = Message(
      id: _uuid.v4(),
      roleId: state.currentRoleId,
      content: content,
      isUser: false,
      timestamp: DateTime.now().millisecondsSinceEpoch,
    );
    state = state.copyWith(messages: [...state.messages, msg]);
    _saveState();
  }

  Future<void> _loadState() async {
    final prefs = await SharedPreferences.getInstance();
    final roleId = prefs.getString('currentRoleId') ?? 'work';
    final model = prefs.getString('currentModel') ?? '';
    final serviceType = prefs.getString('serviceType') ?? 'ollama';
    final serviceHost = prefs.getString('serviceHost') ?? 'http://10.0.2.2:11434';
    final userName = prefs.getString('userName') ?? '';
    final language = prefs.getString('preferredLanguage') ?? '中文';

    // Load custom roles
    final rolesJson = prefs.getString('customRoles');
    List<Role> roles = [...defaultRoles];
    if (rolesJson != null) {
      final customRoles = (jsonDecode(rolesJson) as List)
          .map((e) => Role.fromJson(e as Map<String, dynamic>))
          .toList();
      roles.addAll(customRoles);
    }

    // Load saved messages
    final messagesJson = prefs.getString('messages');
    List<Message> messages = defaultMessages;
    if (messagesJson != null) {
      messages = (jsonDecode(messagesJson) as List)
          .map((e) => Message.fromJson(e as Map<String, dynamic>))
          .toList();
    }

    // Load saved memories
    final memoriesJson = prefs.getString('memories');
    List<Memory> memories = defaultMemories;
    if (memoriesJson != null) {
      memories = (jsonDecode(memoriesJson) as List)
          .map((e) => Memory.fromJson(e as Map<String, dynamic>))
          .toList();
    }

    // Load saved groups
    final groupsJson = prefs.getString('groups');
    List<Group> groups = [];
    if (groupsJson != null) {
      groups = (jsonDecode(groupsJson) as List)
          .map((e) => Group.fromJson(e as Map<String, dynamic>))
          .toList();
    }

    state = state.copyWith(
      roles: roles,
      messages: messages,
      memories: memories,
      groups: groups,
      currentRoleId: roleId,
      currentModel: model,
      serviceType: serviceType,
      serviceHost: serviceHost,
      userName: userName,
      preferredLanguage: language,
    );

    // Load calendar events from SQLite
    await _refreshCalendarCache();
  }

  Future<void> _saveState() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('currentRoleId', state.currentRoleId);
    await prefs.setString('currentModel', state.currentModel);
    await prefs.setString('serviceType', state.serviceType);
    await prefs.setString('serviceHost', state.serviceHost);
    await prefs.setString('userName', state.userName);
    await prefs.setString('preferredLanguage', state.preferredLanguage);

    // Save custom roles (non-default)
    final defaultIds = defaultRoles.map((r) => r.id).toSet();
    final customRoles =
        state.roles.where((r) => !defaultIds.contains(r.id)).toList();
    await prefs.setString(
        'customRoles', jsonEncode(customRoles.map((r) => r.toJson()).toList()));

    await prefs.setString(
        'messages', jsonEncode(state.messages.map((m) => m.toJson()).toList()));
    await prefs.setString('memories',
        jsonEncode(state.memories.map((m) => m.toJson()).toList()));
    await prefs.setString(
        'groups', jsonEncode(state.groups.map((g) => g.toJson()).toList()));
  }

  void switchRole(String roleId) {
    state = state.copyWith(currentRoleId: roleId);
    _saveState();
  }

  void switchModel(String model) {
    state = state.copyWith(currentModel: model);
    _saveState();
  }

  void updateServiceType(String type) {
    final host =
        type == 'ollama' ? 'http://10.0.2.2:11434' : 'http://10.0.2.2:1234';
    state = state.copyWith(serviceType: type, serviceHost: host);
    _saveState();
  }

  void updateServiceHost(String host) {
    state = state.copyWith(serviceHost: host);
    _saveState();
  }

  void updateUserName(String name) {
    state = state.copyWith(userName: name);
    _saveState();
  }

  void updateLanguage(String lang) {
    state = state.copyWith(preferredLanguage: lang);
    _saveState();
  }

  void addRole(Role role) {
    state = state.copyWith(roles: [...state.roles, role]);
    _saveState();
  }

  Future<void> sendMessage(String content) async {
    final userMsg = Message(
      id: _uuid.v4(),
      roleId: state.currentRoleId,
      content: content,
      isUser: true,
      timestamp: DateTime.now().millisecondsSinceEpoch,
    );
    state = state.copyWith(
      messages: [...state.messages, userMsg],
      isLoading: true,
    );
    _saveState();

    try {
      if (state.serviceHost.isEmpty || state.currentModel.isEmpty) {
        state = state.copyWith(isLoading: false);
        return;
      }
      final ModelService service = state.serviceType == 'ollama'
          ? OllamaService(state.serviceHost)
          : LMStudioService(state.serviceHost);

      // Kick off calendar extraction in parallel (doesn't block chat reply)
      _aiExtractCalendarEvents(content).then((events) {
        for (final event in events) {
          addCalendarEvent(event);
        }
        if (events.isNotEmpty) {
          final parts = <String>[];
          for (final e in events) {
            final t = e.time != null ? '${e.time} ' : '';
            final r = e.reminderMinutes != null ? '（${e.reminderText}提醒）' : '';
            parts.add('$t${e.title}$r');
          }
          _addAiMessage('📅 已自动添加日程：${parts.join("、")}');
        }
      });

      // Check if user is setting a reminder on an existing event
      _handleReminderRequest(content);

      final role = state.currentRole;
      final semanticMemories = state.memories
          .where((m) => m.type == 'semantic')
          .map((m) => m.content)
          .join('、');
      final recentEpisodic = state.memories
          .where((m) => m.type == 'episodic')
          .take(5)
          .map((m) => m.content)
          .join('；');

      // Build calendar context
      final calendarContext = await _buildCalendarContext();

      final systemContent = '${role.systemPrompt}\n\n以下是关于用户的已知信息：\n$semanticMemories\n近期事件：$recentEpisodic$calendarContext';

      final history = state.currentRoleMessages.reversed.take(10).toList().reversed;
      final messages = <Map<String, String>>[
        {'role': 'system', 'content': systemContent},
        ...history.map((m) => {
              'role': m.isUser ? 'user' : 'assistant',
              'content': m.content,
            }),
      ];

      final reply = await service.chat(messages, state.currentModel);
      _addAiMessage(reply);
    } catch (e) {
      debugPrint('sendMessage error: $e');
      if (e is DioException && e.type == DioExceptionType.connectionTimeout) {
        _addAiMessage('请求超时，请重试');
      } else if (e is DioException &&
          e.type == DioExceptionType.connectionError) {
        _addAiMessage('无法连接到本地模型服务，请检查服务是否启动');
      } else {
        _addAiMessage('请求失败：$e');
      }
    }
  }

  void _addAiMessage(String content) {
    final aiMsg = Message(
      id: _uuid.v4(),
      roleId: state.currentRoleId,
      content: content,
      isUser: false,
      timestamp: DateTime.now().millisecondsSinceEpoch,
    );
    state = state.copyWith(
      messages: [...state.messages, aiMsg],
      isLoading: false,
    );
    _saveState();
  }

  void addMemory(Memory memory) {
    state = state.copyWith(memories: [...state.memories, memory]);
    _saveState();
  }

  void deleteMemory(String id) {
    state = state.copyWith(
        memories: state.memories.where((m) => m.id != id).toList());
    _saveState();
  }

  Future<void> clearAllMemories() async {
    state = state.copyWith(memories: []);
    _saveState();
  }

  // ---- Calendar methods ----

  final _calendarApi = CalendarApiService.instance;

  Future<void> addCalendarEvent(CalendarEvent event) async {
    await _calendarApi.createEvent(event);
    await _refreshCalendarCache();
  }

  Future<void> updateCalendarEvent(CalendarEvent updated) async {
    await _calendarApi.updateEvent(updated);
    await _refreshCalendarCache();
  }

  Future<void> deleteCalendarEvent(String id) async {
    await _calendarApi.deleteEvent(id);
    await _refreshCalendarCache();
  }

  Future<List<CalendarEvent>> getEventsForDay(DateTime day) async {
    final dateStr = '${day.year}-${day.month.toString().padLeft(2, '0')}-${day.day.toString().padLeft(2, '0')}';
    return _calendarApi.listEvents(startDate: dateStr, endDate: dateStr);
  }

  Future<List<CalendarEvent>> getEventsForRange(DateTime start, DateTime end) async {
    final startStr = '${start.year}-${start.month.toString().padLeft(2, '0')}-${start.day.toString().padLeft(2, '0')}';
    final endStr = '${end.year}-${end.month.toString().padLeft(2, '0')}-${end.day.toString().padLeft(2, '0')}';
    return _calendarApi.listEvents(startDate: startStr, endDate: endStr);
  }

  /// Refresh in-memory calendar cache (for reminder checks)
  Future<void> _refreshCalendarCache() async {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final end = today.add(const Duration(days: 30));
    final events = await getEventsForRange(today, end);
    state = state.copyWith(calendarEvents: events);
  }

  /// Use AI to semantically extract calendar events from user message
  /// Handle "提前X提醒我" style messages that set reminders on recent events
  void _handleReminderRequest(String content) {
    _aiParseReminderRequest(content).then((minutes) {
      if (minutes == null) return;

      // Find the most recent future event without a reminder
      final now = DateTime.now();
      final futureEvents = state.calendarEvents.where((e) {
        if (e.time == null) return false;
        final parts = e.time!.split(':');
        if (parts.length != 2) return false;
        final dt = DateTime(e.date.year, e.date.month, e.date.day,
            int.parse(parts[0]), int.parse(parts[1]));
        return dt.isAfter(now);
      }).toList()
        ..sort((a, b) {
          final aParts = a.time!.split(':');
          final bParts = b.time!.split(':');
          final aDt = DateTime(a.date.year, a.date.month, a.date.day,
              int.parse(aParts[0]), int.parse(aParts[1]));
          final bDt = DateTime(b.date.year, b.date.month, b.date.day,
              int.parse(bParts[0]), int.parse(bParts[1]));
          return aDt.compareTo(bDt);
        });

      if (futureEvents.isEmpty) return;

      final target = futureEvents.first;
      updateCalendarEvent(target.copyWith(reminderMinutes: minutes));

      String reminderText;
      if (minutes >= 1440) {
        reminderText = '提前${minutes ~/ 1440}天';
      } else if (minutes >= 60) {
        reminderText = '提前${minutes ~/ 60}小时';
      } else {
        reminderText = '提前$minutes分钟';
      }
      _addAiMessage('🔔 已设置提醒：${target.time} ${target.title}（$reminderText）');
    });
  }

  /// Ask AI to parse reminder setting from user message
  Future<int?> _aiParseReminderRequest(String content) async {
    if (state.serviceHost.isEmpty || state.currentModel.isEmpty) return null;

    try {
      final ModelService service = state.serviceType == 'ollama'
          ? OllamaService(state.serviceHost)
          : LMStudioService(state.serviceHost);

      final prompt = '''判断用户是否在设置日程提醒。如果是，返回提前提醒的分钟数（纯数字）。如果不是，返回 null。

示例：
"提前一小时提醒我" → 60
"提前30分钟提醒" → 30
"提前半小时提醒我" → 30
"提前两小时提醒" → 120
"提前1天提醒" → 1440
"提前10分钟提醒我" → 10
"你好" → null
"明天开会" → null

只返回数字或null，不要其他文字。

用户说：$content''';

      final result = await service.chat([
        {'role': 'user', 'content': prompt},
      ], state.currentModel);

      final cleaned = result.trim().toLowerCase();
      if (cleaned == 'null' || cleaned.isEmpty) return null;
      // Extract first number from response
      final match = RegExp(r'\d+').firstMatch(cleaned);
      if (match == null) return null;
      final val = int.tryParse(match.group(0)!);
      return (val != null && val > 0) ? val : null;
    } catch (e) {
      debugPrint('aiParseReminderRequest error: $e');
      return null;
    }
  }

  Future<List<CalendarEvent>> _aiExtractCalendarEvents(String userMessage) async {
    if (state.serviceHost.isEmpty || state.currentModel.isEmpty) return [];

    try {
      final ModelService service = state.serviceType == 'ollama'
          ? OllamaService(state.serviceHost)
          : LMStudioService(state.serviceHost);

      final now = DateTime.now();
      final weekday = ['一', '二', '三', '四', '五', '六', '日'][now.weekday - 1];
      final prompt = '''你是一个日程提取助手。分析以下文本，提取其中包含的日程/会议/约会/活动等事件。

规则：
1. 如果文本中没有任何日程相关内容，只返回 []
2. 如果有，返回JSON数组，每个事件格式：
   {"title":"简短标题","date":"YYYY-MM-DD","time":"HH:mm","description":"备注","reminderMinutes":数字}
3. title 要简洁（如"戴唯伟的快速会议"而非整段邀请文本）
4. description 放会议号、链接、地点等补充信息，没有则不填
5. reminderMinutes：如果用户提到提醒（如"提前1小时提醒"），换算成分钟数填入；没提到则不填
6. time、description、reminderMinutes 都是可选字段
7. 只返回JSON数组，不要任何其他文字

当前：${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')} 周$weekday
日期换算："今天"=${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}，"明天"+1天，"后天"+2天，"下周X"=下个周X的日期。

文本内容：
$userMessage''';

      final result = await service.chat([
        {'role': 'user', 'content': prompt},
      ], state.currentModel);

      final jsonStr = _extractJson(result);
      if (jsonStr == null) return [];

      final list = jsonDecode(jsonStr) as List;
      if (list.isEmpty) return [];

      return list.map((item) {
        final m = item as Map<String, dynamic>;
        final dateStr = m['date'] as String;
        final parts = dateStr.split('-');
        if (parts.length != 3) return null;
        final date = DateTime(
          int.parse(parts[0]),
          int.parse(parts[1]),
          int.parse(parts[2]),
        );
        return CalendarEvent(
          id: _uuid.v4(),
          title: m['title'] as String,
          date: date,
          time: m['time'] as String?,
          description: m['description'] as String?,
          reminderMinutes: m['reminderMinutes'] as int?,
        );
      }).whereType<CalendarEvent>().toList();
    } catch (e) {
      debugPrint('aiExtractCalendarEvents error: $e');
      return [];
    }
  }

  /// Extract JSON array from AI response text
  /// Build calendar context string for system prompt
  Future<String> _buildCalendarContext() async {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final end = today.add(const Duration(days: 7));

    final upcoming = await getEventsForRange(today, end);

    if (upcoming.isEmpty) return '\n\n用户日历：近7天无日程。';

    final weekdays = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
    final buf = StringBuffer('\n\n用户日历（近7天）：');
    for (final e in upcoming) {
      final dayLabel = e.date == today
          ? '今天'
          : e.date == today.add(const Duration(days: 1))
              ? '明天'
              : '${e.date.month}/${e.date.day}(${weekdays[e.date.weekday - 1]})';
      final time = e.time ?? '全天';
      final reminder = e.reminderMinutes != null ? ' [${e.reminderText}提醒]' : '';
      final desc = e.description != null ? ' - ${e.description}' : '';
      buf.write('\n- $dayLabel $time ${e.title}$reminder$desc');
    }
    return buf.toString();
  }

  String? _extractJson(String text) {
    final start = text.indexOf('[');
    final end = text.lastIndexOf(']');
    if (start == -1 || end == -1 || end <= start) return null;
    return text.substring(start, end + 1);
  }

  List<Message> getMessagesForRole(String roleId) {
    return state.messages.where((m) => m.roleId == roleId).toList()
      ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
  }

  int? getLastMessageTimeForRole(String roleId) {
    final msgs = state.messages.where((m) => m.roleId == roleId);
    if (msgs.isEmpty) return null;
    return msgs.map((m) => m.timestamp).reduce((a, b) => a > b ? a : b);
  }

  void clearMessagesForRole(String roleId) {
    state = state.copyWith(
      messages: state.messages
          .where((m) => !(m.roleId == roleId && m.groupId == null))
          .toList(),
    );
    _saveState();
  }

  // ---- Group methods ----

  Group createGroup(String name, List<String> roleIds) {
    final group = Group(
      id: 'group_${_uuid.v4()}',
      name: name,
      roleIds: roleIds,
    );
    state = state.copyWith(groups: [...state.groups, group]);
    _saveState();
    return group;
  }

  void deleteGroup(String groupId) {
    state = state.copyWith(
      groups: state.groups.where((g) => g.id != groupId).toList(),
      messages: state.messages.where((m) => m.groupId != groupId).toList(),
    );
    _saveState();
  }

  void clearGroupMessages(String groupId) {
    state = state.copyWith(
      messages: state.messages.where((m) => m.groupId != groupId).toList(),
    );
    _saveState();
  }

  List<Message> getGroupMessagesList(String groupId) {
    return state.messages.where((m) => m.groupId == groupId).toList()
      ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
  }

  int? getLastGroupMessageTime(String groupId) {
    final msgs = state.messages.where((m) => m.groupId == groupId);
    if (msgs.isEmpty) return null;
    return msgs.map((m) => m.timestamp).reduce((a, b) => a > b ? a : b);
  }

  Future<void> sendGroupMessage(String groupId, String content) async {
    final group = state.getGroupById(groupId);
    if (group == null) return;

    final userMsg = Message(
      id: _uuid.v4(),
      roleId: '',
      content: content,
      isUser: true,
      timestamp: DateTime.now().millisecondsSinceEpoch,
      groupId: groupId,
    );
    state = state.copyWith(
      messages: [...state.messages, userMsg],
      loadingGroupId: groupId,
    );
    _saveState();

    try {
      if (state.serviceHost.isEmpty || state.currentModel.isEmpty) {
        state = state.copyWith(clearLoadingGroupId: true);
        return;
      }

      final ModelService service = state.serviceType == 'ollama'
          ? OllamaService(state.serviceHost)
          : LMStudioService(state.serviceHost);

      // Build shared context from memories
      final semanticMemories = state.memories
          .where((m) => m.type == 'semantic')
          .map((m) => m.content)
          .join('、');
      final recentEpisodic = state.memories
          .where((m) => m.type == 'episodic')
          .take(5)
          .map((m) => m.content)
          .join('；');

      // Parse @mentions to determine which roles should respond
      final mentionedRoleIds = <String>[];
      for (final roleId in group.roleIds) {
        final role = state.getRoleById(roleId);
        if (role != null &&
            (content.contains('@${role.name}') || content.contains('＠${role.name}'))) {
          mentionedRoleIds.add(roleId);
        }
      }
      // If specific roles are mentioned, only they respond; otherwise all respond
      final respondingRoleIds = mentionedRoleIds.isNotEmpty ? mentionedRoleIds : group.roleIds;

      // Each role responds sequentially
      for (final roleId in respondingRoleIds) {
        final role = state.getRoleById(roleId);
        if (role == null) continue;

        final calendarContext = await _buildCalendarContext();
        final systemContent =
            '${role.systemPrompt}\n\n以下是关于用户的已知信息：\n$semanticMemories\n近期事件：$recentEpisodic$calendarContext'
            '\n\n你正在一个群聊中，群名：${group.name}。其他成员：${group.roleIds.where((id) => id != roleId).map((id) => state.getRoleById(id)?.name ?? id).join("、")}。'
            '请简洁回复，不要重复其他成员已经说过的内容。';

        final history = getGroupMessagesList(groupId).reversed.take(10).toList().reversed;
        final messages = <Map<String, String>>[
          {'role': 'system', 'content': systemContent},
          ...history.map((m) {
            if (m.isUser) return {'role': 'user', 'content': m.content};
            return {'role': 'assistant', 'content': '[${state.getRoleById(m.roleId)?.name ?? m.roleId}]: ${m.content}'};
          }),
        ];

        final reply = await service.chat(messages, state.currentModel);
        _addGroupAiMessage(groupId, roleId, reply);
        // Small delay between responses for natural feel
        await Future.delayed(const Duration(milliseconds: 300));
      }
    } catch (e) {
      debugPrint('sendGroupMessage error: $e');
      if (e is DioException && e.type == DioExceptionType.connectionError) {
        _addGroupAiMessage(groupId, group.roleIds.first,
            '无法连接到本地模型服务，请检查服务是否启动');
      } else {
        _addGroupAiMessage(groupId, group.roleIds.first, '请求失败，请重试');
      }
    }

    state = state.copyWith(clearLoadingGroupId: true);
    _saveState();
  }

  void _addGroupAiMessage(String groupId, String roleId, String content) {
    final aiMsg = Message(
      id: _uuid.v4(),
      roleId: roleId,
      content: content,
      isUser: false,
      timestamp: DateTime.now().millisecondsSinceEpoch,
      groupId: groupId,
    );
    state = state.copyWith(messages: [...state.messages, aiMsg]);
    _saveState();
  }
}

