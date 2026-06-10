import 'role.dart';
import 'message.dart';
import 'memory.dart';
import 'group.dart';
import 'calendar_event.dart';
import 'conversation_summary.dart';

enum McpConnectionState { disconnected, connecting, connected, error }

class AppState {
  final List<Role> roles;
  /// 已加载到内存的消息——按 conversation 懒加载，初始为空，进入聊天页时通过
  /// [AppStateNotifier.ensureRoleMessagesLoaded] / `ensureGroupMessagesLoaded`
  /// 按需填充。**永远只是某些 scope 的并集**，不是全表镜像。
  final List<Message> messages;
  final List<Memory> memories;
  final List<Group> groups;
  final List<CalendarEvent> calendarEvents;
  /// 启动时一次性加载的会话摘要——每个 scope 的"末条消息时间 + 内容"，
  /// 用来渲染聊天列表无需把整张 messages 读进内存。
  /// Key 形如 `'role:<id>'` 或 `'group:<id>'`。
  final Map<String, ConversationSummary> conversationSummaries;
  final String currentRoleId;
  final String currentModel;
  /// 顶层服务类型：`'local'`（本地推理，目前唯一 provider 是 Ollama）或
  /// `'cloud'`（云端 API，由 [cloudProvider] 选择具体厂商）。
  final String serviceType;
  final String serviceHost;
  final McpConnectionState mcpState;
  final String? mcpError;
  /// 本地推理厂商：`'ollama'`（目前唯一）。预留以便扩展 vLLM / llama.cpp。
  final String localProvider;
  /// 云端厂商：`'anthropic'` | `'gemini'`。
  final String cloudProvider;
  final List<String> cloudModels;
  final String userName;
  final String preferredLanguage;
  final bool isLoading;
  final String? loadingGroupId;
  final bool onboardingCompleted;

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
    this.mcpState = McpConnectionState.disconnected,
    this.mcpError,
    this.localProvider = 'ollama',
    this.cloudProvider = 'anthropic',
    this.cloudModels = const [],
    this.conversationSummaries = const {},
    this.userName = '',
    this.preferredLanguage = '中文',
    this.isLoading = false,
    this.loadingGroupId,
    this.onboardingCompleted = false,
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
    McpConnectionState? mcpState,
    String? mcpError,
    String? localProvider,
    String? cloudProvider,
    List<String>? cloudModels,
    String? userName,
    String? preferredLanguage,
    bool? isLoading,
    String? loadingGroupId,
    bool clearLoadingGroupId = false,
    bool clearMcpError = false,
    bool? onboardingCompleted,
    Map<String, ConversationSummary>? conversationSummaries,
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
      mcpState: mcpState ?? this.mcpState,
      mcpError: clearMcpError ? null : (mcpError ?? this.mcpError),
      localProvider: localProvider ?? this.localProvider,
      cloudProvider: cloudProvider ?? this.cloudProvider,
      cloudModels: cloudModels ?? this.cloudModels,
      userName: userName ?? this.userName,
      preferredLanguage: preferredLanguage ?? this.preferredLanguage,
      isLoading: isLoading ?? this.isLoading,
      loadingGroupId:
          clearLoadingGroupId ? null : (loadingGroupId ?? this.loadingGroupId),
      onboardingCompleted: onboardingCompleted ?? this.onboardingCompleted,
      conversationSummaries:
          conversationSummaries ?? this.conversationSummaries,
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

  String get defaultHost {
    if (serviceType == 'cloud') {
      return switch (cloudProvider) {
        'gemini' => 'https://generativelanguage.googleapis.com',
        _ => 'https://api.anthropic.com',
      };
    }
    return switch (localProvider) {
      _ => 'http://localhost:11434', // ollama
    };
  }

  /// Memories visible to a given role chat: shared profile + that role's own.
  List<Memory> memoriesForRole(String roleId) {
    return memories.where((m) => m.roleId == null || m.roleId == roleId).toList();
  }
}
