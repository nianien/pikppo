import 'role.dart';
import 'message.dart';
import 'memory.dart';
import 'group.dart';
import 'conversation_summary.dart';

enum McpConnectionState { disconnected, connecting, connected, error }

/// 汇率页"常用"收藏对的首发默认（首次启动种入；之后用户可增删，存
/// SharedPreferences）。每项为 `FROM/TO` 形式的币种对。
const kDefaultExchangePairs = <String>[
  'USD/CNY',
  'EUR/CNY',
  'JPY/CNY',
  'HKD/CNY',
  'GBP/CNY',
  'USD/JPY',
];

class AppState {
  final List<Role> roles;
  /// 已加载到内存的消息——按 conversation 懒加载，初始为空，进入聊天页时通过
  /// [AppStateNotifier.ensureRoleMessagesLoaded] / `ensureGroupMessagesLoaded`
  /// 按需填充。**永远只是某些 scope 的并集**，不是全表镜像。
  final List<Message> messages;
  final List<Memory> memories;
  final List<Group> groups;
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
  /// MCP 外部工具总开关。OFF 时不连接 pikppo-mcp、agent 工具列表不含 MCP
  /// 工具——本机没跑 MCP server 的设备（如真机调试）关掉以免无谓重连。
  final bool mcpEnabled;
  /// 本地推理厂商：`'ollama'`（目前唯一）。预留以便扩展 vLLM / llama.cpp。
  final String localProvider;
  /// 云端厂商：`'anthropic'` | `'gemini'`。
  final String cloudProvider;
  final String userName;
  final String preferredLanguage;
  final bool isLoading;
  final String? loadingGroupId;
  /// 私聊 agent loop 正在执行工具时的瞬时提示（如"正在调用工具：货币换算"）。
  /// 纯 UI 过渡态——不落库、不进 LLM 历史，工具执行完即清空。null = 无工具在跑。
  final String? toolStatus;
  final bool onboardingCompleted;
  /// 锁屏显示提醒详情（v3.2 / 产品方案 §3.5）。默认 true；OFF 时系统通知的
  /// visibility 切到 private，锁屏只露 ticker（"角色 · 1 条提醒"）。
  final bool showReminderDetailsOnLockScreen;
  /// 汇率页"常用"币种对收藏（`FROM/TO`），用户可增删。
  final List<String> exchangeFavoritePairs;
  /// _loadState 是否已经把磁盘上的 settings/roles/memories/groups 全部装载到 state。
  /// _AppRoot 等这个为 true 才渲染 Onboarding/MainShell，避免在初始 default state
  /// 上抢跑的 race（点 send 被 _loadState 清空、欢迎页一闪而过 等都是 race 表现）。
  final bool isReady;

  const AppState({
    required this.roles,
    required this.messages,
    required this.memories,
    required this.currentRoleId,
    required this.currentModel,
    required this.serviceType,
    required this.serviceHost,
    this.groups = const [],
    this.mcpState = McpConnectionState.disconnected,
    this.mcpError,
    this.mcpEnabled = true,
    this.localProvider = 'ollama',
    this.cloudProvider = 'anthropic',
    this.conversationSummaries = const {},
    this.userName = '',
    this.preferredLanguage = '中文',
    this.isLoading = false,
    this.loadingGroupId,
    this.toolStatus,
    this.onboardingCompleted = false,
    this.showReminderDetailsOnLockScreen = true,
    this.exchangeFavoritePairs = kDefaultExchangePairs,
    this.isReady = false,
  });

  AppState copyWith({
    List<Role>? roles,
    List<Message>? messages,
    List<Memory>? memories,
    List<Group>? groups,
    String? currentRoleId,
    String? currentModel,
    String? serviceType,
    String? serviceHost,
    McpConnectionState? mcpState,
    String? mcpError,
    bool? mcpEnabled,
    String? localProvider,
    String? cloudProvider,
    String? userName,
    String? preferredLanguage,
    bool? isLoading,
    String? loadingGroupId,
    bool clearLoadingGroupId = false,
    String? toolStatus,
    bool clearToolStatus = false,
    bool clearMcpError = false,
    bool? onboardingCompleted,
    bool? showReminderDetailsOnLockScreen,
    List<String>? exchangeFavoritePairs,
    Map<String, ConversationSummary>? conversationSummaries,
    bool? isReady,
  }) {
    return AppState(
      roles: roles ?? this.roles,
      messages: messages ?? this.messages,
      memories: memories ?? this.memories,
      groups: groups ?? this.groups,
      currentRoleId: currentRoleId ?? this.currentRoleId,
      currentModel: currentModel ?? this.currentModel,
      serviceType: serviceType ?? this.serviceType,
      serviceHost: serviceHost ?? this.serviceHost,
      mcpState: mcpState ?? this.mcpState,
      mcpError: clearMcpError ? null : (mcpError ?? this.mcpError),
      mcpEnabled: mcpEnabled ?? this.mcpEnabled,
      localProvider: localProvider ?? this.localProvider,
      cloudProvider: cloudProvider ?? this.cloudProvider,
      userName: userName ?? this.userName,
      preferredLanguage: preferredLanguage ?? this.preferredLanguage,
      isLoading: isLoading ?? this.isLoading,
      loadingGroupId:
          clearLoadingGroupId ? null : (loadingGroupId ?? this.loadingGroupId),
      toolStatus: clearToolStatus ? null : (toolStatus ?? this.toolStatus),
      onboardingCompleted: onboardingCompleted ?? this.onboardingCompleted,
      showReminderDetailsOnLockScreen: showReminderDetailsOnLockScreen ??
          this.showReminderDetailsOnLockScreen,
      exchangeFavoritePairs:
          exchangeFavoritePairs ?? this.exchangeFavoritePairs,
      conversationSummaries:
          conversationSummaries ?? this.conversationSummaries,
      isReady: isReady ?? this.isReady,
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

  /// 极端兜底角色——仅当 roles 完全加载失败（预置角色都没读到）时用，保证
  /// 强制进入 App 后 currentRole 不抛、页面能渲染。正常路径永远走不到这里。
  static const _fallbackRole = Role(
    id: 'work',
    name: '助理',
    icon: '🤖',
    description: '',
    color: '#7CB342',
    systemPrompt: '',
  );

  /// 当前角色。找不到（id 不匹配 / roles 为空）时兜底，绝不抛——
  /// 启动异常被 [AppStateNotifier] 强制放行时也能安全渲染。
  Role get currentRole {
    if (roles.isEmpty) return _fallbackRole;
    return roles.firstWhere((r) => r.id == currentRoleId,
        orElse: () => roles.first);
  }

  Role? getRoleById(String id) =>
      roles.where((r) => r.id == id).firstOrNull;

  Group? getGroupById(String id) =>
      groups.where((g) => g.id == id).firstOrNull;

  /// Memories visible to a given role chat: shared profile + that role's own.
  List<Memory> memoriesForRole(String roleId) {
    return memories.where((m) => m.roleId == null || m.roleId == roleId).toList();
  }
}
