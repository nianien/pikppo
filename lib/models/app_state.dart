import 'role.dart';
import 'message.dart';
import 'memory.dart';
import 'group.dart';
import 'calendar_event.dart';

class AppState {
  final List<Role> roles;
  final List<Message> messages;
  final List<Memory> memories;
  final List<Group> groups;
  final List<CalendarEvent> calendarEvents;
  final String currentRoleId;
  final String currentModel;
  final String serviceType; // 'ollama' | 'lmstudio'
  final String serviceHost;
  final String userName;
  final String preferredLanguage;
  final bool isLoading;
  final String? loadingGroupId; // which group is loading a response

  const AppState({
    required this.roles,
    required this.messages,
    required this.memories,
    required this.currentRoleId,
    required this.currentModel,
    required this.serviceType,
    required this.serviceHost,
    this.groups = const [],
    this.calendarEvents = const [],
    this.userName = '',
    this.preferredLanguage = '中文',
    this.isLoading = false,
    this.loadingGroupId,
  });

  AppState copyWith({
    List<Role>? roles,
    List<Message>? messages,
    List<Memory>? memories,
    List<Group>? groups,
    List<CalendarEvent>? calendarEvents,
    String? currentRoleId,
    String? currentModel,
    String? serviceType,
    String? serviceHost,
    String? userName,
    String? preferredLanguage,
    bool? isLoading,
    String? loadingGroupId,
    bool clearLoadingGroupId = false,
  }) {
    return AppState(
      roles: roles ?? this.roles,
      messages: messages ?? this.messages,
      memories: memories ?? this.memories,
      groups: groups ?? this.groups,
      calendarEvents: calendarEvents ?? this.calendarEvents,
      currentRoleId: currentRoleId ?? this.currentRoleId,
      currentModel: currentModel ?? this.currentModel,
      serviceType: serviceType ?? this.serviceType,
      serviceHost: serviceHost ?? this.serviceHost,
      userName: userName ?? this.userName,
      preferredLanguage: preferredLanguage ?? this.preferredLanguage,
      isLoading: isLoading ?? this.isLoading,
      loadingGroupId:
          clearLoadingGroupId ? null : (loadingGroupId ?? this.loadingGroupId),
    );
  }

  List<Message> get allMessages =>
      [...messages]..sort((a, b) => a.timestamp.compareTo(b.timestamp));

  List<Message> get currentRoleMessages =>
      messages
          .where((m) => m.roleId == currentRoleId && m.groupId == null)
          .toList()
        ..sort((a, b) => a.timestamp.compareTo(b.timestamp));

  List<Message> groupMessages(String groupId) =>
      messages.where((m) => m.groupId == groupId).toList()
        ..sort((a, b) => a.timestamp.compareTo(b.timestamp));

  Role get currentRole => roles.firstWhere((r) => r.id == currentRoleId);

  Role? getRoleById(String id) =>
      roles.where((r) => r.id == id).firstOrNull;

  Group? getGroupById(String id) =>
      groups.where((g) => g.id == id).firstOrNull;

  String get defaultHost =>
      serviceType == 'ollama' ? 'http://10.0.2.2:11434' : 'http://10.0.2.2:1234';
}
