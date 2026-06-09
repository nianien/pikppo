import 'dart:async';
import 'dart:convert';
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
import '../data/preset_roles.dart';
import '../db/database.dart';
import '../db/mappers.dart';
import '../db/migration.dart';
import '../services/agent.dart';
import '../services/model_service.dart';
import '../services/mcp_service.dart';
import '../services/tool_registry.dart';
import '../utils/chat_history.dart';
import '../utils/time_format.dart';
import '../utils/user_facing_error.dart';
import 'database_provider.dart';
import 'memory_summarizer.dart';
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

/// Hard cap on agent loop iterations. Without this, a misbehaving model could
/// loop indefinitely between tool_use and tool_result.
const _kMaxAgentIterations = 10;

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
        _refreshCalendarCache();
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

    // 业务数据从 drift 读——预置角色与自定义角色拼装；其它表全量加载到内存
    // （当前 state 模型仍是内存为主、drift 作 source-of-truth）。
    final customRoles = (await db.allCustomRoles()).map(customRoleFromRow);
    final roles = <Role>[...defaultRoles, ...customRoles];
    final messages = (await db.allMessages()).map(messageFromRow).toList();
    final memories = (await db.allMemories()).map(memoryFromRow).toList();
    final groups = (await db.allGroups()).map(groupFromRow).toList();

    state = state.copyWith(
      roles: roles,
      messages: messages,
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

  // ---- Chat (private) ----

  Future<void> sendMessage(String content) async {
    _markActivity();
    // Trigger a background refresh so the next message has a fresh fix; this
    // call is a no-op if the cached fix is still within maxAge.
    unawaited(_ref.read(locationServiceProvider).refresh());

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
    _persistMessage(userMsg);

    try {
      if (state.currentModel.isEmpty) {
        state = state.copyWith(isLoading: false);
        return;
      }
      final service = _modelService();
      if (service == null) {
        _addAiMessage('请先在设置中配置模型服务');
        return;
      }

      final role = state.currentRole;
      final systemContent =
          await _buildSystemPrompt(role, state.currentRoleId);

      // Agentic path: 当前所选模型必须真的具备 tool 能力（Ollama 上 gemma3:4b
      // 协议层支持、但模型本身没 tool capabilities，不能走 agent loop），同时
      // 至少要有一个可用工具（本地 or MCP）。本地表非空时即便 MCP 离线也开启。
      if (await service.modelSupportsTools(state.currentModel)) {
        final mcpToolsAvailable = _mcp.isConnected
            ? (await _mcp.ensureTools()).isNotEmpty
            : false;
        if (mcpToolsAvailable || _localTools.isNotEmpty) {
          await _runAgentLoop(
            service: service,
            systemContent: systemContent,
            userInput: content,
          );
          return;
        }
      }

      // 非 agent 路径：纯对话回复。日程/提醒抽取走 agent loop，模型自主 emit
      // tool_use 调用 MCP；本路径仅服务 tool 能力缺失的模型。
      final history = recentChatHistory(
        state.currentRoleMessages.where((m) => m.kind == 'chat').toList(),
      );
      final lastUserIdx = indexOfLastUser(history);
      final messages = <Map<String, String>>[
        {'role': 'system', 'content': systemContent},
        for (var i = 0; i < history.length; i++)
          {
            'role': history[i].isUser ? 'user' : 'assistant',
            'content': i == lastUserIdx
                ? _formatUserContentForLlm(history[i])
                : history[i].content,
          },
      ];

      final reply = await service.chat(messages, state.currentModel);
      _addAiMessage(reply);
    } catch (e) {
      debugPrint('sendMessage failed: ${debugReason(e)}');
      _addAiMessage(userFacingError(e));
    }
  }

  // ---- Agent loop ----

  Future<void> _runAgentLoop({
    required ModelService service,
    required String systemContent,
    required String userInput,
  }) async {
    // Translate persisted history into the structured format Anthropic expects.
    // The current user input is the trailing message; earlier turns are plain
    // text bubbles, so we represent them as string content. Filter to chat
    // messages only — tool_status/reminder bubbles are UI-only.
    final history = recentChatHistory(
      state.currentRoleMessages.where((m) => m.kind == 'chat').toList(),
    );
    final lastUserIdx = indexOfLastUser(history);
    final messages = <Map<String, dynamic>>[
      for (var i = 0; i < history.length; i++)
        {
          'role': history[i].isUser ? 'user' : 'assistant',
          'content': i == lastUserIdx
              ? _formatUserContentForLlm(history[i])
              : history[i].content,
        },
      // The latest user message is already in [history] (sendMessage appended
      // it before calling us), so we don't add it again here.
    ];

    // 合并本地与 MCP 工具一并暴露给模型。本地工具在前——若与 MCP 同名，按
    // dispatch 时的查找顺序本地胜出（同时定义里也只保留一份以免给模型造成歧义）。
    final mcpDefs = _mcp.tools
        .where((t) => !_localTools.has(t.name))
        .map((t) => ToolDefinition(
              name: t.name,
              description: t.description,
              inputSchema: t.inputSchema,
            ))
        .toList();
    final tools = <ToolDefinition>[
      ..._localTools.definitions(),
      ...mcpDefs,
    ];

    AgentStep step;
    try {
      step = await service.agentStart(
        system: systemContent,
        messages: messages,
        model: state.currentModel,
        tools: tools,
      );
    } catch (e) {
      debugPrint('agent start failed: ${debugReason(e)}');
      _addAiMessage(userFacingError(e));
      return;
    }

    var iterations = 0;
    while (step is AgentToolRequest) {
      if (++iterations > _kMaxAgentIterations) {
        _addAiMessage('（已达到工具调用上限，停止后续推理）');
        return;
      }

      // Surface any preamble text the model emitted before the tool call.
      final preamble = step.text?.trim();
      if (preamble != null && preamble.isNotEmpty) {
        _addAiStreamPart(preamble);
      }

      // Show one "🔧 调用 X" status bubble per tool call for transparency.
      // Marked as tool_status so it's visible in UI but excluded from LLM history.
      for (final call in step.calls) {
        _addAiStreamPart('🔧 调用工具：${call.name}', kind: 'tool_status');
      }

      // Execute tool calls in order, collecting results. 本地优先，未命中再走 MCP。
      final results = <ToolResult>[];
      for (final call in step.calls) {
        try {
          final raw = _localTools.has(call.name)
              ? await _localTools.call(call.name, call.input)
              : await _mcp.callTool(call.name, call.input);
          results.add(ToolResult(toolUseId: call.id, content: raw));
        } catch (e) {
          debugPrint('tool ${call.name} failed: ${debugReason(e)}');
          // tool 错误回灌给模型——让 LLM 决定是否重试 / 改换方案；UI 不直接显示。
          results.add(ToolResult(
            toolUseId: call.id,
            content: userFacingError(e),
            isError: true,
          ));
        }
      }

      // Calendar mutations may have changed; refresh cache opportunistically.
      if (step.calls.any((c) => c.name.contains('calendar'))) {
        unawaited(_refreshCalendarCache());
      }

      messages.add(step.assistantMessage);
      messages.addAll(service.buildToolResultMessages(results));

      try {
        step = await service.agentContinue(
          system: systemContent,
          messages: messages,
          model: state.currentModel,
          tools: tools,
        );
      } catch (e) {
        debugPrint('agent continue failed: ${debugReason(e)}');
        _addAiMessage(userFacingError(e));
        return;
      }
    }

    if (step is AgentDone) {
      _addAiMessage(step.text);
    }
  }

  /// Append an intermediate AI message during an agent loop. Distinct from
  /// [_addAiMessage] in that it does NOT clear `isLoading` — the loop is still
  /// running.
  void _addAiStreamPart(String content, {String kind = 'chat'}) {
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
    _persistMessage(aiMsg);
  }

  /// 组装某个 [role] 的 system prompt——私聊和群聊共用。
  /// [groupSuffix] 给群聊用，附加成员列表 + 协作规则；私聊为 null。
  Future<String> _buildSystemPrompt(
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
    await _refreshCalendarCache();
  }

  Future<void> updateCalendarEvent(CalendarEvent updated) async {
    await _mcp.updateEvent(updated);
    // 时间/提醒可能被调整，需要重新进入提醒窗口。
    _reminderScheduler.forget(updated.id);
    await _refreshCalendarCache();
  }

  Future<void> deleteCalendarEvent(String id) async {
    await _mcp.deleteEvent(id);
    _reminderScheduler.forget(id);
    await _refreshCalendarCache();
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

  Future<void> _refreshCalendarCache() async {
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

  /// 给"最后一条 user 消息"加显式日期提示。小模型不信 system 里的日期声明，
  /// 但会跟问题贴在一起的自然语言提示走；只注入最后一条避免历史轮的旧时间戳
  /// 互相干扰。assistant 与较早的 user 消息保持原文。
  String _formatUserContentForLlm(Message m) {
    final dt = DateTime.fromMillisecondsSinceEpoch(m.timestamp);
    return '（系统提示：当前时间是 ${fmtDate(dt)} ${fmtWeekday(dt)} '
        '${fmtHourMinute(dt)} ${dt.timeZoneName}，'
        '所有"今天/明天/现在"按此换算，不要使用训练数据中的旧日期。）\n\n'
        '${m.content}';
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
    _persistMessagesForRoleDelete(roleId);
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
  }

  void clearGroupMessages(String groupId) {
    state = state.copyWith(
      messages: state.messages.where((m) => m.groupId != groupId).toList(),
    );
    _persistMessagesForGroupDelete(groupId);
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
    _markActivity();
    unawaited(_ref.read(locationServiceProvider).refresh());

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
    _persistMessage(userMsg);

    try {
      final service = _modelService();
      if (service == null) {
        state = state.copyWith(clearLoadingGroupId: true);
        return;
      }

      final mentioned = _parseMentions(content, group);
      final responding = mentioned.isNotEmpty
          ? mentioned
          : await _routeGroupMessage(content, group, service);

      for (final roleId in responding) {
        final role = state.getRoleById(roleId);
        if (role == null) continue;

        final otherNames = group.roleIds
            .where((id) => id != roleId)
            .map((id) => state.getRoleById(id)?.name ?? id)
            .join('、');
        final systemPrompt = await _buildSystemPrompt(
          role,
          roleId,
          groupSuffix: '\n\n你正在群聊"${group.name}"中。其他成员：$otherNames。'
              '请基于自身能力简洁回复，不要重复其他成员已经说过的内容。',
        );

        final history = recentChatHistory(
          getGroupMessagesList(groupId).where((m) => m.kind == 'chat').toList(),
        );
        final lastUserIdx = indexOfLastUser(history);
        final messages = <Map<String, String>>[
          {'role': 'system', 'content': systemPrompt},
          for (var i = 0; i < history.length; i++)
            if (history[i].isUser)
              {
                'role': 'user',
                'content': i == lastUserIdx
                    ? _formatUserContentForLlm(history[i])
                    : history[i].content,
              }
            else
              {
                'role': 'assistant',
                'content':
                    '[${state.getRoleById(history[i].roleId)?.name ?? history[i].roleId}]: ${history[i].content}',
              },
        ];

        final reply = await service.chat(messages, state.currentModel);
        _addGroupAiMessage(groupId, roleId, reply);
        await Future.delayed(const Duration(milliseconds: 300));
      }
    } catch (e) {
      debugPrint('sendGroupMessage failed: ${debugReason(e)}');
      _addGroupAiMessage(groupId, group.roleIds.first, userFacingError(e));
    }

    state = state.copyWith(clearLoadingGroupId: true);
    _saveState();
  }

  List<String> _parseMentions(String content, Group group) {
    final mentioned = <String>[];
    for (final roleId in group.roleIds) {
      final role = state.getRoleById(roleId);
      if (role == null) continue;
      if (content.contains('@${role.name}') ||
          content.contains('＠${role.name}')) {
        mentioned.add(roleId);
      }
    }
    return mentioned;
  }

  /// Ask the LLM which roles in [group] should reply to [content]. Falls back
  /// to the first role if the call fails or returns nothing.
  Future<List<String>> _routeGroupMessage(
      String content, Group group, ModelService service) async {
    if (group.roleIds.length <= 1) return group.roleIds;
    try {
      final roleLines = group.roleIds.map((id) {
        final r = state.getRoleById(id);
        if (r == null) return '$id - 未知角色';
        return '$id - ${r.name}：${r.description}';
      }).join('\n');
      final prompt = '''判断下面的用户消息与哪些角色相关，返回相关角色 id 的 JSON 数组。
- 仅返回 JSON 数组（如 ["work","life"]），不要其他文字
- 若没有明显相关角色，返回 []

可选角色：
$roleLines

消息：$content''';
      final result = await service.chat([
        {'role': 'user', 'content': prompt},
      ], state.currentModel);
      final ids = _parseRoleIdArray(result);
      final valid = ids.where(group.roleIds.contains).toList();
      if (valid.isEmpty) return [group.roleIds.first];
      return valid;
    } catch (e) {
      debugPrint('routeGroupMessage failed: ${debugReason(e)}');
      return [group.roleIds.first];
    }
  }

  List<String> _parseRoleIdArray(String text) {
    final start = text.indexOf('[');
    final end = text.lastIndexOf(']');
    if (start == -1 || end == -1 || end <= start) return const [];
    try {
      final list = jsonDecode(text.substring(start, end + 1));
      if (list is List) {
        return list.whereType<String>().toList();
      }
    } catch (_) {}
    return const [];
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
    _persistMessage(aiMsg);
  }

  // ---- Memory auto-summary hooks ----

  void _markActivity() => _summarizer.markActivity();

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
