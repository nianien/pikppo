import 'dart:async';
import 'package:drift/drift.dart' show InsertMode;
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
import '../models/conversation_summary.dart';
import '../data/preset_roles.dart';
import '../db/database.dart';
import '../db/mappers.dart';
import '../db/migration.dart';
import '../services/model_service.dart';
import '../services/mcp_service.dart';
import '../services/tool_registry.dart';
import '../utils/time_format.dart';
import '../utils/user_facing_error.dart';
import 'database_provider.dart';
import 'memory_summarizer.dart';
import 'messaging_controller.dart';
import 'reminder_scheduler.dart';
import '../services/location_service.dart';
import 'mcp_service_provider.dart';
import 'model_service_provider.dart';
import 'location_service_provider.dart';

const _uuid = Uuid();

/// Frequency at which we re-check upcoming calendar events for reminders.
const _kReminderInterval = Duration(seconds: 30);

/// How often the background memory summarizer wakes up.
const _kMemorySummaryInterval = Duration(hours: 1);

/// Idle threshold (no user activity) after which we trigger an extra summary
/// pass.
const _kIdleSummaryThreshold = Duration(minutes: 30);

final appStateProvider =
    StateNotifierProvider<AppStateNotifier, AppState>((ref) {
  return AppStateNotifier(ref);
});

class AppStateNotifier extends StateNotifier<AppState> {
  final Ref _ref;
  StreamSubscription<McpConnectionState>? _mcpSub;
  late final ToolRegistry _localTools;
  late final ReminderScheduler _reminderScheduler;
  late final MemorySummarizer _summarizer;
  late final MessagingController _messaging;

  // ---- 给 MessagingController 等子组件访问的公共门面 ----

  /// 本地 tool 注册表——agent loop 合并 MCP 工具时用。
  ToolRegistry get localTools => _localTools;

  /// 当前可用的 ModelService（按 settings + apiKey 决定）。
  ModelService? modelService() => _modelService();

  /// 防抖落盘：连续 state 改动只触发一次实际写。`_pendingSave` 串联防止并发，
  /// `dispose` 时 flush 保最后一次变更不丢。
  Timer? _saveDebounce;
  Future<void> _pendingSave = Future.value();
  static const _kSaveDebounce = Duration(milliseconds: 120);

  AppStateNotifier(this._ref)
      : super(const AppState(
          roles: defaultRoles,
          messages: [],
          memories: [],
          currentRoleId: 'work',
          currentModel: '',
          serviceType: 'local',
          serviceHost: 'http://localhost:11434',
        )) {
    _localTools = _buildLocalTools();
    _reminderScheduler = ReminderScheduler(
      interval: _kReminderInterval,
      getEvents: () => state.calendarEvents,
      onReminder: _onReminderDue,
    );
    _summarizer = MemorySummarizer(
      _ref,
      interval: _kMemorySummaryInterval,
      idleThreshold: _kIdleSummaryThreshold,
    );
    _messaging = MessagingController(this, _ref);
    _loadState();
    _reminderScheduler.start();
    _summarizer.start();
    _wireMcpListener();
    // Fire-and-forget: 不阻塞首屏；权限弹窗会自然出现在首次 GPS 请求时。
    unawaited(_ref.read(locationServiceProvider).refresh());
  }

  /// 进程内工具表。这里的工具直接在 Flutter 端运行，不走 MCP——用于本地数据
  /// 操作或纯计算。pikppo-mcp 维护远程/外部工具（云日历、Drive 等），两者在
  /// agent loop 里合并暴露给模型，dispatch 时按名分流。
  ///
  /// 目前为空——等 `note_add` / `note_search` 等本地操作迁入时再注册。
  ToolRegistry _buildLocalTools() => ToolRegistry(const []);

  @override
  Future<void> dispose() async {
    _reminderScheduler.stop();
    _summarizer.stop();
    _mcpSub?.cancel();
    // Flush 待落盘的变更——避免最后一次 setState 因防抖窗口未到而丢失。
    _saveDebounce?.cancel();
    _saveDebounce = null;
    await _writeSnapshot();
    super.dispose();
  }

  // ---- MCP wiring ----

  McpService get _mcp => _ref.read(mcpServiceProvider);

  void _wireMcpListener() {
    _mcpSub = _mcp.stateStream.listen((s) {
      state = state.copyWith(
        mcpState: s,
        mcpError: _mcp.lastError,
        clearMcpError: _mcp.lastError == null,
      );
      if (s == McpConnectionState.connected) {
        refreshCalendarCache();
      }
    });
  }

  /// 重新连接 MCP——程序内部使用（如网络恢复后），不接受外部 host 参数。
  /// host 来自 [defaultMcpHost]（编译期默认 + dart-define 覆盖）。
  Future<void> reconnectMcp() async {
    await _mcp.connect(defaultMcpHost);
  }

  // ---- Reminder hook ----

  /// [ReminderScheduler] 命中提醒窗口时回调到这里——拼好文案发到当前角色对话。
  void _onReminderDue(CalendarEvent event, int diffMinutes) {
    final desc = event.description != null ? '\n${event.description}' : '';
    final timeHint = diffMinutes >= 60
        ? '约${diffMinutes ~/ 60}小时后'
        : '$diffMinutes分钟后';
    _addReminderMessage(
      '⏰ 日程提醒（$timeHint开始）\n${event.time} ${event.title}$desc',
    );
  }

  void _addReminderMessage(String content) {
    final msg = Message(
      id: _uuid.v4(),
      roleId: state.currentRoleId,
      content: content,
      isUser: false,
      timestamp: DateTime.now().millisecondsSinceEpoch,
      kind: 'reminder',
    );
    state = state.copyWith(messages: [...state.messages, msg]);
    _persistMessage(msg);
  }

  // ---- Persistence ----

  /// 当前数据库实例——首次访问时打开 + 解密 + （首次启动）迁移旧 prefs 数据。
  Future<PikppoDatabase> get _db => _ref.read(databaseProvider.future);

  Future<void> _loadState() async {
    final prefs = await SharedPreferences.getInstance();
    final roleId = prefs.getString('currentRoleId') ?? 'work';
    final model = prefs.getString('currentModel') ?? '';
    // 旧版本可能存的是 `'ollama'` 或 `'lmstudio'`——归一到 `'local'`。
    // LM Studio 已下线，localProvider 全部当作 ollama 处理。
    var serviceType = prefs.getString('serviceType') ?? 'local';
    if (serviceType == 'ollama' || serviceType == 'lmstudio') {
      serviceType = 'local';
    }
    final localProvider = prefs.getString('localProvider') ?? 'ollama';
    final cloudProvider = prefs.getString('cloudProvider') ?? 'anthropic';
    // 首次启动 / 旧版本没存过 host 时，按当前 type/provider + 当前平台给默认。
    final defaultHost = serviceType == 'cloud'
        ? _cloudDefaultHost(cloudProvider)
        : _localDefaultHost(localProvider);
    final serviceHost = prefs.getString('serviceHost') ?? defaultHost;
    final userName = prefs.getString('userName') ?? '';
    final language = prefs.getString('preferredLanguage') ?? '中文';
    final onboardingCompleted = prefs.getBool('onboardingCompleted') ?? false;

    // 打开 db + 迁移旧 prefs JSON（幂等，第二次启动跳过）。
    final db = await _db;
    await migrateFromPrefsIfNeeded(db);

    // 启动时只加载小集合：角色、群聊、记忆、会话摘要——后两类用来渲染聊天
    // 列表，不需要 messages 全表。**messages 按会话懒加载**，进入某个聊天页
    // 时由 [ensureRoleMessagesLoaded] / [ensureGroupMessagesLoaded] 填进 state。
    final customRoles = (await db.allCustomRoles()).map(customRoleFromRow);
    final roles = <Role>[...defaultRoles, ...customRoles];
    final memories = (await db.allMemories()).map(memoryFromRow).toList();
    final groups = (await db.allGroups()).map(groupFromRow).toList();
    final summaries = await _loadConversationSummaries(db);

    state = state.copyWith(
      roles: roles,
      messages: const [],
      memories: memories,
      groups: groups,
      currentRoleId: roleId,
      currentModel: model,
      serviceType: serviceType,
      serviceHost: serviceHost,
      localProvider: localProvider,
      cloudProvider: cloudProvider,
      userName: userName,
      preferredLanguage: language,
      onboardingCompleted: onboardingCompleted,
      conversationSummaries: summaries,
    );

    // Load cloud API keys (no-op if storage absent), then start MCP connection.
    final storage = _ref.read(secureStorageProvider);
    try {
      await loadAnthropicApiKeyWith(
        storage: storage,
        setKey: (v) =>
            _ref.read(anthropicApiKeyProvider.notifier).state = v,
      );
    } catch (e) {
      debugPrint('loadAnthropicApiKey failed: ${debugReason(e)}');
    }
    try {
      await loadGeminiApiKeyWith(
        storage: storage,
        setKey: (v) => _ref.read(geminiApiKeyProvider.notifier).state = v,
      );
    } catch (e) {
      debugPrint('loadGeminiApiKey failed: ${debugReason(e)}');
    }

    unawaited(_mcp.connect(defaultMcpHost));
  }

  /// 启动时一次 SQL 查询拿到所有会话末条消息——给聊天列表渲染用。
  Future<Map<String, ConversationSummary>> _loadConversationSummaries(
      PikppoDatabase db) async {
    final rows = await db.latestPerConversation();
    final map = <String, ConversationSummary>{};
    for (final r in rows) {
      final key = r.groupId == null
          ? ConversationSummary.keyForRole(r.roleId)
          : ConversationSummary.keyForGroup(r.groupId!);
      map[key] = ConversationSummary(
        scopeKey: key,
        lastTimestamp: r.timestamp,
        lastContent: r.content,
      );
    }
    return map;
  }

  // ---- Lazy load: per-conversation messages ----

  /// 已加载到 [state.messages] 的会话 scope。键形如 `'role:<id>'` / `'group:<id>'`。
  final Set<String> _loadedScopes = {};

  /// 进入某私聊页时调——首次调用从 db 加载消息进 state，幂等：第二次直接返回。
  Future<void> ensureRoleMessagesLoaded(String roleId) async {
    final key = ConversationSummary.keyForRole(roleId);
    if (_loadedScopes.contains(key)) return;
    _loadedScopes.add(key);
    try {
      final db = await _db;
      final rows = await db.messagesForRole(roleId);
      if (rows.isEmpty) return;
      final loaded = rows.map(messageFromRow).toList();
      // 去重合并：可能同一条消息因并发 ensure 被加两次。
      final existingIds = state.messages.map((m) => m.id).toSet();
      final fresh = loaded.where((m) => !existingIds.contains(m.id));
      state =
          state.copyWith(messages: [...state.messages, ...fresh]);
    } catch (e) {
      debugPrint(
          'ensureRoleMessagesLoaded($roleId) failed: ${debugReason(e)}');
      _loadedScopes.remove(key); // 失败允许重试
    }
  }

  /// 进入某群聊页时调——同上但按 groupId。
  Future<void> ensureGroupMessagesLoaded(String groupId) async {
    final key = ConversationSummary.keyForGroup(groupId);
    if (_loadedScopes.contains(key)) return;
    _loadedScopes.add(key);
    try {
      final db = await _db;
      final rows = await db.messagesForGroup(groupId);
      if (rows.isEmpty) return;
      final loaded = rows.map(messageFromRow).toList();
      final existingIds = state.messages.map((m) => m.id).toSet();
      final fresh = loaded.where((m) => !existingIds.contains(m.id));
      state =
          state.copyWith(messages: [...state.messages, ...fresh]);
    } catch (e) {
      debugPrint(
          'ensureGroupMessagesLoaded($groupId) failed: ${debugReason(e)}');
      _loadedScopes.remove(key);
    }
  }

  /// 清掉某 scope 的会话摘要（清空消息 / 删群聊时用）。
  void _clearConversationSummary(String scopeKey) {
    if (!state.conversationSummaries.containsKey(scopeKey)) return;
    final next = Map<String, ConversationSummary>.from(
        state.conversationSummaries)
      ..remove(scopeKey);
    state = state.copyWith(conversationSummaries: next);
  }

  /// 在某 scope 新增/更新一条消息后同步会话摘要——让聊天列表立刻看到。
  void _bumpConversationSummary(Message m) {
    final key = m.groupId == null
        ? ConversationSummary.keyForRole(m.roleId)
        : ConversationSummary.keyForGroup(m.groupId!);
    final next = Map<String, ConversationSummary>.from(
        state.conversationSummaries)
      ..[key] = ConversationSummary(
        scopeKey: key,
        lastTimestamp: m.timestamp,
        lastContent: m.content,
      );
    state = state.copyWith(conversationSummaries: next);
  }

  /// 调度一次落盘——多次连续调用合并成一次实际写入，避免 sendMessage / addMemory
  /// 之类高频 setState 引起的 IO 风暴。dispose 时 flush 兜底。
  void _saveState() {
    _saveDebounce?.cancel();
    _saveDebounce = Timer(_kSaveDebounce, () {
      _saveDebounce = null;
      _pendingSave = _pendingSave.then((_) => _writeSnapshot());
    });
  }

  /// 把小 KV 类设置（currentRole/Model/serviceType/语言等）落到 SharedPreferences。
  /// 业务实体（messages/memories/groups/customRoles）由各自的 mutation 直接调
  /// drift 增量写——不再走全量 JSON。
  Future<void> _writeSnapshot() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('currentRoleId', state.currentRoleId);
    await prefs.setString('currentModel', state.currentModel);
    await prefs.setString('serviceType', state.serviceType);
    await prefs.setString('serviceHost', state.serviceHost);
    await prefs.setString('localProvider', state.localProvider);
    await prefs.setString('cloudProvider', state.cloudProvider);
    await prefs.setString('userName', state.userName);
    await prefs.setString('preferredLanguage', state.preferredLanguage);
    await prefs.setBool('onboardingCompleted', state.onboardingCompleted);
  }

  // ---- DB write helpers（fire-and-forget；失败入日志，不阻塞 UI）----

  void _persistMessage(Message m) {
    unawaited(_db.then((db) => db.insertMessage(messageToCompanion(m))));
    _bumpConversationSummary(m);
  }

  void _persistMessagesForRoleDelete(String roleId) {
    unawaited(_db.then((db) => db.deleteMessagesForRole(roleId)));
  }

  void _persistMessagesForGroupDelete(String groupId) {
    unawaited(_db.then((db) => db.deleteMessagesForGroup(groupId)));
  }

  void _persistMemory(Memory m) {
    unawaited(_db.then((db) => db.insertMemory(memoryToCompanion(m))));
  }

  void _persistMemoryDelete(String id) {
    unawaited(_db.then((db) => db.deleteMemory(id)));
  }

  void _persistMemoriesClear() {
    unawaited(_db.then((db) => db.clearAllMemories()));
  }

  void _persistGroup(Group g) {
    unawaited(_db.then((db) => db.insertGroup(groupToCompanion(g))));
  }

  void _persistGroupDelete(String id) {
    unawaited(_db.then((db) async {
      await db.deleteGroup(id);
      await db.deleteMessagesForGroup(id);
    }));
  }

  void _persistCustomRole(Role role) {
    unawaited(_db.then((db) => db.insertCustomRole(customRoleToCompanion(role))));
  }

  /// 批量提交 memory diff——updated + added 一次事务，减少 IO。
  void _persistMemoryDiff({
    required Map<String, Memory> updated,
    required List<Memory> added,
  }) {
    if (updated.isEmpty && added.isEmpty) return;
    unawaited(_db.then((db) async {
      await db.batch((batch) {
        for (final m in updated.values) {
          batch.insert(
            db.memoryRows,
            memoryToCompanion(m),
            mode: InsertMode.insertOrReplace,
          );
        }
        for (final m in added) {
          batch.insert(db.memoryRows, memoryToCompanion(m));
        }
      });
    }));
  }

  // ---- Settings mutations ----

  void switchRole(String roleId) {
    state = state.copyWith(currentRoleId: roleId);
    _saveState();
  }

  void switchModel(String model) {
    state = state.copyWith(currentModel: model);
    _saveState();
  }

  /// 切换顶层服务类型（local / cloud），host 自动回到对应 provider 的默认值。
  void updateServiceType(String type) {
    final host = type == 'cloud'
        ? _cloudDefaultHost(state.cloudProvider)
        : _localDefaultHost(state.localProvider);
    state = state.copyWith(serviceType: type, serviceHost: host);
    _saveState();
  }

  /// 切换本地推理 provider（ollama / 未来的 vLLM 等）。host 回到该 provider 默认。
  void updateLocalProvider(String provider) {
    state = state.copyWith(
      localProvider: provider,
      serviceHost: _localDefaultHost(provider),
    );
    _saveState();
  }

  /// 切换云端 provider（anthropic / gemini / ...）。host 回到该 provider 默认。
  /// API Key 由调用方保证已配置。
  void updateCloudProvider(String provider) {
    state = state.copyWith(
      cloudProvider: provider,
      serviceHost: _cloudDefaultHost(provider),
    );
    _saveState();
  }

  static String _cloudDefaultHost(String provider) => switch (provider) {
        'gemini' => 'https://generativelanguage.googleapis.com',
        _ => 'https://api.anthropic.com',
      };

  /// 本地推理默认 host。**按平台自适应**：
  /// - Android 模拟器里 `localhost` 指模拟器自身、连不到宿主机，需要 `10.0.2.2`。
  /// - 其它平台（iOS 模拟器、macOS / Windows / Linux 桌面）`localhost` 即宿主机。
  /// - 真 Android 设备需要宿主机 LAN IP，无法自动推断，用户在设置里手填即可。
  static String _localDefaultHost(String provider) {
    final base = defaultTargetPlatform == TargetPlatform.android
        ? '10.0.2.2'
        : 'localhost';
    return switch (provider) {
      _ => 'http://$base:11434', // ollama
    };
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
    _persistCustomRole(role);
  }

  void completeOnboarding() {
    state = state.copyWith(onboardingCompleted: true);
    _saveState();
  }

  // ---- Model service factory ----

  /// 组装当前可用的 ModelService。直接调 [buildModelService] 纯工厂——不去
  /// `ref.read(modelServiceProvider)`，否则会跟 provider 内部 `watch` 本 notifier
  /// 的 state 构成循环依赖（Riverpod 抛 `CircularDependencyError`）。
  ///
  /// `OllamaService` 跨实例的能力缓存通过 host 维度 static 表保活，不依赖
  /// 实例复用。
  ModelService? _modelService() {
    if (state.serviceType != 'cloud' && state.currentModel.isEmpty) {
      return null;
    }
    return buildModelService(
      type: state.serviceType,
      host: state.serviceHost,
      localProvider: state.localProvider,
      cloudProvider: state.cloudProvider,
      anthropicKey: _ref.read(anthropicApiKeyProvider),
      geminiKey: _ref.read(geminiApiKeyProvider),
    );
  }

  // ---- Chat entry points（委托给 MessagingController）----

  Future<void> sendMessage(String content) => _messaging.sendMessage(content);

  /// Append user 消息 + 进入 loading 态——MessagingController 进入 sendMessage 时调。
  void appendUserMessage(Message msg) {
    state = state.copyWith(
      messages: [...state.messages, msg],
      isLoading: true,
    );
    _persistMessage(msg);
  }

  /// Append AI 最终回复并退出 loading 态——MessagingController 拿到模型回复后调。
  void appendAiMessage(String content) {
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
    _persistMessage(aiMsg);
  }

  /// agent loop 中间态气泡——不退出 loading，区别于 [appendAiMessage]。
  void appendAiStreamPart(String content, {String kind = 'chat'}) {
    final msg = Message(
      id: _uuid.v4(),
      roleId: state.currentRoleId,
      content: content,
      isUser: false,
      timestamp: DateTime.now().millisecondsSinceEpoch,
      kind: kind,
    );
    state = state.copyWith(messages: [...state.messages, msg]);
    _persistMessage(msg);
  }

  /// 退出 loading 但不追加消息（如：currentModel 为空时直接 return）。
  void setIdle() {
    state = state.copyWith(isLoading: false);
  }

  /// 组装某个 [role] 的 system prompt——私聊和群聊共用。
  /// [groupSuffix] 给群聊用，附加成员列表 + 协作规则；私聊为 null。
  /// public 供 [MessagingController] 调用。
  Future<String> buildSystemPrompt(
    Role role,
    String roleId, {
    String? groupSuffix,
  }) async {
    final visible = state.memoriesForRole(roleId);
    final profileMemories = visible
        .where((m) => m.roleId == null && m.type == 'semantic')
        .map((m) => m.content)
        .toList();
    final roleSemantic = visible
        .where((m) => m.roleId == roleId && m.type == 'semantic')
        .map((m) => m.content)
        .toList();
    final episodic = visible
        .where((m) => m.roleId == roleId && m.type == 'episodic')
        .take(5)
        .map((m) => m.content)
        .toList();

    final calendarContext = await _buildCalendarContext();
    // 实时系统信息放最前并强声明权威性，避免小模型用训练时的旧日期/坐标乱答。
    final buf = StringBuffer(_buildContextHeader())
      ..write('\n\n${role.systemPrompt}');
    if (profileMemories.isNotEmpty) {
      buf.write('\n\n关于用户：\n${profileMemories.join('、')}');
    }
    if (roleSemantic.isNotEmpty) {
      buf.write('\n\n${role.name}的专属记忆：\n${roleSemantic.join('、')}');
    }
    if (episodic.isNotEmpty) {
      buf.write('\n\n近期事件：\n${episodic.join('；')}');
    }
    if (calendarContext.isNotEmpty) buf.write(calendarContext);
    if (groupSuffix != null) buf.write(groupSuffix);
    return buf.toString();
  }

  /// Session context: current time + location, fetched live from device.
  ///
  /// 时间总是实时；位置读 [LocationService] 缓存（永远不在 prompt 构建过程中
  /// 等待 GPS——首次定位异步进行，缓存命中后续 prompt 都能拿到）。
  ///
  /// 措辞按"系统强制信息"组织，明确告诉模型必须以此为准——小模型默认会用训
  /// 练截止时的旧日期回答"今天是几号"。
  String _buildContextHeader() {
    final lines = <String>[
      '【系统实时信息（权威，请以此为准；不要使用训练数据中的日期或地点猜测）】',
      '- 当前日期时间：${fmtSystemTimestamp(DateTime.now())}',
    ];

    final loc = _ref.read(locationServiceProvider);
    final fix = loc.lastKnown;
    if (fix != null) {
      lines.add('- 当前位置：${fix.displayLabel}'
          '（GPS ${fix.latitude.toStringAsFixed(4)}, ${fix.longitude.toStringAsFixed(4)}）');
    } else if (loc.status == LocationStatus.denied ||
        loc.status == LocationStatus.deniedForever) {
      lines.add('- 当前位置：用户未授权获取，无法获知');
    } else if (loc.status == LocationStatus.serviceDisabled) {
      lines.add('- 当前位置：设备定位服务关闭，无法获知');
    } else {
      lines.add('- 当前位置：正在获取，暂未知');
    }
    lines.add('- "今天"、"明天"、"现在"、"附近"等相对表达，必须基于上述实时信息换算。');
    return lines.join('\n');
  }

  // ---- Memory ----

  void addMemory(Memory memory) {
    state = state.copyWith(memories: [...state.memories, memory]);
    _persistMemory(memory);
  }

  void deleteMemory(String id) {
    state = state.copyWith(
        memories: state.memories.where((m) => m.id != id).toList());
    _persistMemoryDelete(id);
  }

  Future<void> clearAllMemories() async {
    state = state.copyWith(memories: []);
    _persistMemoriesClear();
  }

  // ---- Calendar (via MCP) ----

  Future<void> addCalendarEvent(CalendarEvent event) async {
    await _mcp.createEvent(event);
    await refreshCalendarCache();
  }

  Future<void> updateCalendarEvent(CalendarEvent updated) async {
    await _mcp.updateEvent(updated);
    // 时间/提醒可能被调整，需要重新进入提醒窗口。
    _reminderScheduler.forget(updated.id);
    await refreshCalendarCache();
  }

  Future<void> deleteCalendarEvent(String id) async {
    await _mcp.deleteEvent(id);
    _reminderScheduler.forget(id);
    await refreshCalendarCache();
  }

  Future<List<CalendarEvent>> getEventsForDay(DateTime day) async {
    if (!_mcp.isConnected) return [];
    final dateStr = fmtDate(day);
    return _mcp.listEvents(startDate: dateStr, endDate: dateStr);
  }

  Future<List<CalendarEvent>> getEventsForRange(
      DateTime start, DateTime end) async {
    if (!_mcp.isConnected) return [];
    return _mcp.listEvents(
        startDate: fmtDate(start), endDate: fmtDate(end));
  }

  Future<void> refreshCalendarCache() async {
    if (!_mcp.isConnected) {
      state = state.copyWith(calendarEvents: const []);
      return;
    }
    try {
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      final end = today.add(const Duration(days: 30));
      final events = await getEventsForRange(today, end);
      // 窗口外的事件清出去重表——避免长期累积。
      final liveIds = events.map((e) => e.id).toSet();
      for (final e in state.calendarEvents) {
        if (!liveIds.contains(e.id)) _reminderScheduler.forget(e.id);
      }
      state = state.copyWith(calendarEvents: events);
    } catch (e) {
      debugPrint('refreshCalendarCache failed: ${debugReason(e)}');
    }
  }

  Future<String> _buildCalendarContext() async {
    if (!_mcp.isConnected) return '';
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

  // ---- Misc helpers ----

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
    _persistMessagesForRoleDelete(roleId);
    _clearConversationSummary(ConversationSummary.keyForRole(roleId));
  }

  // ---- Groups ----

  Group createGroup(String name, List<String> roleIds) {
    final group = Group(
      id: 'group_${_uuid.v4()}',
      name: name,
      roleIds: roleIds,
    );
    state = state.copyWith(groups: [...state.groups, group]);
    _persistGroup(group);
    return group;
  }

  void deleteGroup(String groupId) {
    state = state.copyWith(
      groups: state.groups.where((g) => g.id != groupId).toList(),
      messages: state.messages.where((m) => m.groupId != groupId).toList(),
    );
    _persistGroupDelete(groupId);
    _clearConversationSummary(ConversationSummary.keyForGroup(groupId));
  }

  void clearGroupMessages(String groupId) {
    state = state.copyWith(
      messages: state.messages.where((m) => m.groupId != groupId).toList(),
    );
    _persistMessagesForGroupDelete(groupId);
    _clearConversationSummary(ConversationSummary.keyForGroup(groupId));
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

  Future<void> sendGroupMessage(String groupId, String content) =>
      _messaging.sendGroupMessage(groupId, content);

  /// 群聊 user 消息 append + 进入 loading 态。
  void appendGroupUserMessage(Message msg, String groupId) {
    state = state.copyWith(
      messages: [...state.messages, msg],
      loadingGroupId: groupId,
    );
    _persistMessage(msg);
  }

  /// 群聊里某个角色回复。
  void appendGroupAiMessage(String groupId, String roleId, String content) {
    final aiMsg = Message(
      id: _uuid.v4(),
      roleId: roleId,
      content: content,
      isUser: false,
      timestamp: DateTime.now().millisecondsSinceEpoch,
      groupId: groupId,
    );
    state = state.copyWith(messages: [...state.messages, aiMsg]);
    _persistMessage(aiMsg);
  }

  /// 群聊全部角色回复完后退出 loading。
  void clearGroupLoading() {
    state = state.copyWith(clearLoadingGroupId: true);
  }

  // ---- Memory auto-summary hooks ----

  /// 用户操作时刷新心跳——闲置阈值的"闲置"从最后一次活动起算。
  /// public 供 [MessagingController] 调用。
  void markActivity() => _summarizer.markActivity();

  /// 显式触发一次记忆归纳（设置页"立即归纳"按钮用）。
  Future<void> runMemorySummaryNow() => _summarizer.runNow();

  /// 由 [MemorySummarizer] 调回——把归纳出的 diff 应用到记忆列表。
  void applyMemoryDiff({
    required Map<String, Memory> updated,
    required List<Memory> added,
  }) {
    if (updated.isEmpty && added.isEmpty) return;
    final next = state.memories.map((m) => updated[m.id] ?? m).toList()
      ..addAll(added);
    state = state.copyWith(memories: next);
    _persistMemoryDiff(updated: updated, added: added);
  }
}
