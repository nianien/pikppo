import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import '../models/app_state.dart';
import '../models/knowledge_card.dart';
import '../models/role.dart';
import '../models/message.dart';
import '../models/memory.dart';
import '../models/group.dart';
import '../models/calendar_event.dart';
import '../models/conversation_summary.dart';
import '../data/role_loader.dart';
import '../db/database.dart';
import '../db/mappers.dart';
import '../db/migration.dart';
import '../services/cloud_provider_catalog.dart';
import '../services/model_service.dart';
import '../services/attachment_store.dart';
import '../services/mcp_service.dart';
import '../services/reminder_router.dart';
import '../services/tool_registry.dart';
import '../services/tools/calendar_tools.dart';
import '../utils/chart_cards.dart';
import '../utils/time_format.dart';
import '../utils/user_facing_error.dart';
import 'calendar_repository_provider.dart';
import 'database_provider.dart';
import 'knowledge_repository_provider.dart';
import 'memory_repository_provider.dart';
import 'memory_summarizer.dart';
import 'messaging_controller.dart';
import 'notification_service_provider.dart';
import 'reminder_router_provider.dart';
import 'reminder_scheduler.dart';
import 'reminder_scheduler_provider.dart';
import '../services/location_service.dart';
import 'mcp_service_provider.dart';
import 'model_service_provider.dart';
import 'location_service_provider.dart';

const _uuid = Uuid();

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
  ProviderSubscription<AsyncValue<List<CalendarEvent>>>? _calendarSub;
  StreamSubscription<ReminderEvent>? _reminderSub;
  late final ToolRegistry _localTools;
  late final MemorySummarizer _summarizer;
  late final MessagingController _messaging;

  // ---- 给 MessagingController 等子组件访问的公共门面 ----

  /// 本地 tool 注册表——agent loop 合并 MCP 工具时用。
  ToolRegistry get localTools => _localTools;

  /// 当前可用的 ModelService（按 settings + apiKey 决定）。
  ModelService? modelService() => _modelService();

  /// 公共暴露 state，给 MessagingController 等子组件读——避免它们走
  /// `ref.read(appStateProvider)`（Riverpod debug 模式拦截 provider 自读自）。
  AppState get currentState => state;

  /// 防抖落盘：连续 state 改动只触发一次实际写。`_pendingSave` 串联防止并发，
  /// `dispose` 时 flush 保最后一次变更不丢。
  Timer? _saveDebounce;
  Future<void> _pendingSave = Future.value();
  static const _kSaveDebounce = Duration(milliseconds: 120);

  /// 启动放行兜底定时器——就绪或 dispose 时取消，避免悬挂。
  Timer? _readyWatchdog;

  AppStateNotifier(this._ref)
      : super(const AppState(
          // 启动时为空——_loadState 里 await loadDefaultRoles() 后注入。
          // _AppRoot 用 isReady 守住 UI，期间不会渲染依赖 currentRole 的页面。
          roles: [],
          messages: [],
          memories: [],
          currentRoleId: 'work',
          currentModel: '',
          serviceType: 'cloud',
          serviceHost: 'https://api.anthropic.com',
        )) {
    _localTools = _buildLocalTools();
    _summarizer = MemorySummarizer(
      _ref,
      interval: _kMemorySummaryInterval,
      idleThreshold: _kIdleSummaryThreshold,
    );
    _messaging = MessagingController(this, _ref);
    _loadState();
    _startReadyWatchdog();
    _summarizer.start();
    _wireMcpListener();
    _wireCalendarStream();
    _wireReminderStream();
    // Fire-and-forget: 不阻塞首屏；权限弹窗会自然出现在首次 GPS 请求时。
    unawaited(_ref.read(locationServiceProvider).refresh());
  }

  /// 进程内工具表。这里的工具直接在 Flutter 端运行，不走 MCP——用于本地数据
  /// 操作（calendar、未来的 notes 等）或纯计算。pikppo-mcp 维护远程/外部工具
  /// （Drive 等），两者在 agent loop 里合并暴露给模型，dispatch 时按名分流。
  ToolRegistry _buildLocalTools() => ToolRegistry([
        ...buildCalendarTools(_ref),
      ]);

  @override
  Future<void> dispose() async {
    _summarizer.stop();
    _readyWatchdog?.cancel();
    _mcpSub?.cancel();
    _calendarSub?.close();
    _reminderSub?.cancel();
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
    });
  }

  /// 重新连接 MCP——程序内部使用（如网络恢复后），不接受外部 host 参数。
  /// host 来自 [defaultMcpHost]（编译期默认 + dart-define 覆盖）。
  Future<void> reconnectMcp() async {
    if (!state.mcpEnabled) return;
    await _mcp.connect(defaultMcpHost);
  }

  /// 直接调一个 MCP 工具并拿到原始 JSON 字符串——给需要主动查外部数据的 UI 页
  /// （如汇率页）用，不经 agent loop。未连接时 [McpService.callTool] 抛
  /// [McpUnavailableException]，调用方负责兜底（提示 + reconnectMcp）。
  Future<String> callMcpTool(String name, Map<String, dynamic> args) =>
      _mcp.callTool(name, args);

  /// MCP 总开关。开 → 立即连接；关 → 断开并清空工具目录。
  Future<void> setMcpEnabled(bool enabled) async {
    state = state.copyWith(mcpEnabled: enabled);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('mcpEnabled', enabled);
    if (enabled) {
      unawaited(_mcp.connect(defaultMcpHost).catchError((Object e) {
        debugPrint('MCP connect failed (non-fatal): ${debugReason(e)}');
      }));
    } else {
      await _mcp.disconnect();
    }
  }

  // ---- Calendar stream ----

  /// 订阅 [upcomingCalendarEventsProvider]，把 30 天内的事件推给
  /// [reminderSchedulerProvider]——这是 scheduler 唯一的事件来源。
  /// Repository 写入后 drift 自动通知，无需手动 refresh。
  void _wireCalendarStream() {
    final scheduler = _ref.read(reminderSchedulerProvider);
    _calendarSub = _ref.listen<AsyncValue<List<CalendarEvent>>>(
      upcomingCalendarEventsProvider,
      (_, next) {
        next.whenData(scheduler.setEvents);
      },
      fireImmediately: true,
    );
  }

  // ---- Reminder stream ----

  /// 订阅 [reminderSchedulerProvider.events]：每条到点的 [ReminderEvent] →
  /// [ReminderRouter] 路由到 1–N 个角色 → 在每个角色私聊里 append 一条
  /// `kind='reminder'` 消息（v3.2 §4 / 产品方案 §3.2 提醒以聊天形态呈现）。
  void _wireReminderStream() {
    final scheduler = _ref.read(reminderSchedulerProvider);
    _reminderSub = scheduler.events.listen(_dispatchReminder);
  }

  /// 单角色分发（v3.2）：优先用事件上的 routedRoleId（事件写入时已路由），
  /// 不存在则用 router 做一次兜底（兼容 v3.1 老行 + LLM 失败场景）。
  Future<void> _dispatchReminder(ReminderEvent reminder) async {
    final event = reminder.event;
    final router = _ref.read(reminderRouterProvider);
    String roleId = event.routedRoleId ?? '';
    if (roleId.isEmpty || state.getRoleById(roleId) == null) {
      try {
        roleId = await router.route(
          event: event,
          candidates: state.roles,
          llmService: _modelService(),
          llmModel: state.currentModel.isEmpty ? null : state.currentModel,
        );
      } catch (e) {
        debugPrint('reminder route failed: ${debugReason(e)}');
        roleId = router.defaultRoleId;
      }
    }
    if (state.getRoleById(roleId) == null) return; // 角色已被删，放弃
    _appendReminderMessage(roleId, reminder);
  }

  /// 在指定角色私聊里 append 一条 reminder 消息——内容措辞先简洁兜底，未来可
  /// 升级为"按角色 system prompt 生成措辞"（需要一次 LLM 调用，延迟暂不引入）。
  ///
  /// 同时调 NotificationService.showImmediate 兜底——OS 通知预调度在某些厂商
  /// 极端省电下可能漏触发，前台到点时再发一条确保用户被打扰一次（同 id 调度
  /// 已发过的情况，OS 会自动 dedupe）。
  void _appendReminderMessage(String roleId, ReminderEvent reminder) {
    final event = reminder.event;
    final timeHint = reminder.diffMinutes >= 60
        ? '约 ${reminder.diffMinutes ~/ 60} 小时后开始'
        : '${reminder.diffMinutes} 分钟后开始';
    final timeLabel =
        event.localTimeLabel != null ? '${event.localTimeLabel} ' : '';
    final content = '⏰ $timeLabel${event.title}（$timeHint）';

    final msg = Message(
      id: _uuid.v4(),
      roleId: roleId,
      content: content,
      isUser: false,
      timestamp: DateTime.now().millisecondsSinceEpoch,
      kind: 'reminder',
    );
    state = state.copyWith(messages: [...state.messages, msg]);
    _persistMessage(msg);

    // 系统通知兜底——只在前台触发时调，因为后台时这条路径不会被执行（App
    // 进程不在），OS 已经按预调度独立弹出。
    final role = state.getRoleById(roleId);
    if (role != null) {
      unawaited(
          _ref.read(notificationServiceProvider).showImmediate(event, role));
    }
  }

  // ---- Attachments & forwarding ----

  /// 发送附件消息（不触发 AI 回复——模型暂不消费文件内容，喂给 LLM 的多模态
  /// 链路后续单独做）。[groupId] 非空 = 发到群聊。
  Future<void> sendAttachment({
    required String type,
    required String sourcePath,
    required String name,
    String? groupId,
  }) async {
    final copy = await AttachmentStore.import(sourcePath);
    final size = await copy.length();
    final msg = Message(
      id: _uuid.v4(),
      // 群聊的用户消息 roleId 为空串（与 MessagingController 的群发一致）。
      roleId: groupId == null ? state.currentRoleId : '',
      content: '',
      isUser: true,
      timestamp: DateTime.now().millisecondsSinceEpoch,
      groupId: groupId,
      attachmentType: type,
      attachmentPath: copy.path,
      attachmentName: name,
      attachmentSize: size,
    );
    state = state.copyWith(messages: [...state.messages, msg]);
    _persistMessage(msg);
  }

  /// 把一条消息转发到目标会话（角色私聊或群聊）。复制为**当前用户发出的新
  /// 消息**，不触发 AI 回复；附件复用同一份私有副本（引用计数式删除暂不做，
  /// 删除会话时按路径清理，另一会话引用同文件时该气泡退化为"文件已清理"）。
  void forwardMessage(Message source, {String? toRoleId, String? toGroupId}) {
    assert((toRoleId == null) != (toGroupId == null));
    final msg = Message(
      id: _uuid.v4(),
      roleId: toRoleId ?? '',
      content: source.content,
      isUser: true,
      timestamp: DateTime.now().millisecondsSinceEpoch,
      groupId: toGroupId,
      attachmentType: source.attachmentType,
      attachmentPath: source.attachmentPath,
      attachmentName: source.attachmentName,
      attachmentSize: source.attachmentSize,
    );
    state = state.copyWith(messages: [...state.messages, msg]);
    _persistMessage(msg);
  }

  // ---- Persistence ----

  /// 当前数据库实例——首次访问时打开 + 解密 + （首次启动）迁移旧 prefs 数据。
  Future<PikppoDatabase> get _db => _ref.read(databaseProvider.future);

  /// 终极兜底：极端情况下 [_loadState] 的某个 await 真正挂起（连 finally 都跑不
  /// 到，如 SharedPreferences / 兜底 loadDefaultRoles 卡死），这个定时器到点强制
  /// 放行进入页面。正常路径（含 db 超时）远在它之前就 ready 了，watchdog 不触发。
  void _startReadyWatchdog() {
    _readyWatchdog = Timer(const Duration(seconds: 9), () {
      _readyWatchdog = null;
      if (!state.isReady) {
        debugPrint('loadState watchdog fired (9s) — forcing app entry');
        state = state.copyWith(isReady: true);
      }
    });
  }

  /// 启动加载的**总闸**：无论内部发生什么（异常 / 部分超时），finally 都把
  /// `isReady` 置 true，让 App 进入页面——开屏不该因任何初始化失败而卡死。
  /// 真正的步骤在 [_loadStateInner]；这里只负责"无论如何都放行"。
  Future<void> _loadState() async {
    try {
      await _loadStateInner();
    } catch (e) {
      debugPrint('loadState failed: ${debugReason(e)}');
    } finally {
      if (!state.isReady) {
        // 兜底：内部在设置 roles 前就挂了（prefs / 预置角色读取失败），再试一次
        // 预置角色，至少让聊天列表有东西渲染。
        if (state.roles.isEmpty) {
          try {
            state = state.copyWith(roles: await loadDefaultRoles());
          } catch (e) {
            debugPrint('fallback loadDefaultRoles failed: ${debugReason(e)}');
          }
        }
        state = state.copyWith(isReady: true);
      }
      // 已就绪，watchdog 没用了——取消，别悬挂（也让 widget 测试不报 pending timer）。
      _readyWatchdog?.cancel();
      _readyWatchdog = null;
    }
  }

  Future<void> _loadStateInner() async {
    final prefs = await SharedPreferences.getInstance();
    final roleId = prefs.getString('currentRoleId') ?? 'work';
    final model = prefs.getString('currentModel') ?? '';
    // 旧版本可能存的是 `'ollama'` 或 `'lmstudio'`——归一到 `'local'`。
    // LM Studio 已下线，localProvider 全部当作 ollama 处理。
    var storedType = prefs.getString('serviceType') ?? 'cloud';
    if (storedType == 'ollama' || storedType == 'lmstudio') {
      storedType = 'local';
    }
    // 本地推理（Ollama）是开发期测试通道：release 锁定云端，设置页的
    // 本地/云端选择也只在 debug 构建显示。
    final serviceType = kDebugMode ? storedType : 'cloud';
    final localProvider = prefs.getString('localProvider') ?? 'ollama';
    final cloudProvider = prefs.getString('cloudProvider') ?? 'anthropic';
    // 首次启动 / 旧版本没存过 host 时，按当前 type/provider + 当前平台给默认。
    final defaultHost = serviceType == 'cloud'
        ? _cloudDefaultHost(cloudProvider)
        : _localDefaultHost(localProvider);
    // 被锁定切到云端时（debug 存的是 local、跑的是 release），存量 host 指向
    // 本地服务已无意义，跟着归位到云端默认。
    final serviceHost = serviceType == storedType
        ? (prefs.getString('serviceHost') ?? defaultHost)
        : defaultHost;
    final userName = prefs.getString('userName') ?? '';
    final language = prefs.getString('preferredLanguage') ?? '中文';
    final onboardingCompleted = prefs.getBool('onboardingCompleted') ?? false;
    final showLockDetails =
        prefs.getBool('showReminderDetailsOnLockScreen') ?? true;
    final mcpEnabled = prefs.getBool('mcpEnabled') ?? true;
    // 汇率"常用"收藏：首次启动种入默认对，之后以用户增删结果为准。
    final exchangeFavoritePairs =
        prefs.getStringList('exchangeFavoritePairs') ?? kDefaultExchangePairs;
    // 模型列表缓存——切换面板秒开，不用每次现拉 API。
    _ref.read(modelCacheProvider.notifier).state =
        decodeModelCache(prefs.getString(modelCachePrefsKey));
    // 同步到 NotificationService，让首批 scheduleFor 用对的 visibility。
    _ref
        .read(notificationServiceProvider)
        .setShowDetailsOnLockScreen(showLockDetails);

    // 预置角色优先就绪——这是渲染 MainShell 的最低要求，必须先于 db 拿到。
    // 从 assets/roles/*.yaml 一次性加载；失败会向上抛到 [_loadState] 的兜底。
    final defaultRoles = await loadDefaultRoles();

    // **db 阶段整体 try + 超时**：开库（含 SQLCipher 解密）/ 迁移 / 查询任一失败
    // 或卡住，都退化成"只有预置角色、空记忆/群组/摘要"，绝不阻断启动。db 一旦
    // 卡住，后续懒加载（进聊天页）再失败由各自路径兜底，不影响进入页面。
    var roles = <Role>[...defaultRoles];
    var memories = const <Memory>[];
    var groups = const <Group>[];
    var summaries = const <String, ConversationSummary>{};
    try {
      final db = await _db.timeout(const Duration(seconds: 6));
      await migrateFromPrefsIfNeeded(
        db,
        reservedRoleIds: defaultRoles.map((r) => r.id).toSet(),
      );
      // 启动只加载小集合：自定义角色、群聊、记忆、会话摘要——messages 按会话懒加载。
      final customRoles = (await db.allCustomRoles()).map(customRoleFromRow);
      roles = <Role>[...defaultRoles, ...customRoles];
      memories = (await db.allMemories()).map(memoryFromRow).toList();
      groups = (await db.allGroups()).map(groupFromRow).toList();
      summaries = await _loadConversationSummaries(db);
    } catch (e) {
      debugPrint('loadState db phase failed/timeout: ${debugReason(e)}');
    }

    // 注：不写 messages: const []——保留 ready 前用户可能误操作产生的输入。
    state = state.copyWith(
      roles: roles,
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
      showReminderDetailsOnLockScreen: showLockDetails,
      mcpEnabled: mcpEnabled,
      exchangeFavoritePairs: exchangeFavoritePairs,
      conversationSummaries: summaries,
    );

    // 下面这些都**不该阻塞进入页面**——全部 fire-and-forget，本方法随即返回，
    // isReady 由 [_loadState] 的 finally 立即置位。哪怕 keychain 读取卡住也不卡开屏。
    unawaited(_loadCloudKeysThenBootstrap());

    // 显式吃掉 MCP 初始连接失败——非致命，UI 会按 mcpState 自己处理（banner /
    // 日历页提示），不能让一条 unawaited future error 在控制台飘红误导调试。
    if (mcpEnabled) {
      unawaited(_mcp.connect(defaultMcpHost).catchError((Object e) {
        debugPrint('MCP initial connect failed (non-fatal): ${debugReason(e)}');
      }));
    }

    // Calendar 写副作用钩子——Repository 写入 / 删除事件时调用，触发路由 +
    // 系统通知调度。绑定时机点：state.roles 已就绪，db 已开。
    unawaited(_bindCalendarWriteHooks());

    // isReady 由 [_loadState] 的 finally 统一置位（保证异常路径也放行），这里不设。
  }

  /// 读云端 API key（keychain）→ 若 currentModel 还空，给默认 provider 拉一次模型
  /// 列表取首个当默认。整条都不阻塞启动：keychain 卡/失败不影响进入页面，
  /// currentModel 留空时聊天页横幅兜底提示。
  Future<void> _loadCloudKeysThenBootstrap() async {
    try {
      await loadAllCloudApiKeys(
        storage: _ref.read(secureStorageProvider),
        setKeys: (m) => _ref.read(cloudApiKeysProvider.notifier).state = m,
      );
    } catch (e) {
      debugPrint('loadAllCloudApiKeys failed: ${debugReason(e)}');
    }
    if (state.currentModel.isEmpty) {
      unawaited(_bootstrapDefaultModel());
    }
  }

  /// 把 Calendar 写副作用接到 ReminderRouter + NotificationService 上。
  /// 创建/修改事件时：路由出 roleId → 写回 routedRoleId → schedule OS 通知。
  /// 删除时：cancel 已注册的通知。
  Future<void> _bindCalendarWriteHooks() async {
    try {
      final repo = await _ref.read(calendarRepositoryProvider.future);
      final router = _ref.read(reminderRouterProvider);
      final notif = _ref.read(notificationServiceProvider);

      repo.bindHooks(
        onWrite: (event) async {
          final reminderMinutes = event.reminderMinutes;
          if (reminderMinutes == null) {
            // 没设提醒：取消可能存在的旧调度（编辑事件去掉提醒的场景）。
            await notif.cancelFor(event.id);
            return;
          }
          // 路由：优先用事件已有 routedRoleId（用户在 UI 显式改过角色时尊重），
          // 否则跑路由器。
          String roleId = event.routedRoleId ?? '';
          if (roleId.isEmpty || state.getRoleById(roleId) == null) {
            try {
              roleId = await router.route(
                event: event,
                candidates: state.roles,
                llmService: _modelService(),
                llmModel:
                    state.currentModel.isEmpty ? null : state.currentModel,
              );
            } catch (e) {
              debugPrint(
                  'reminder route on write failed: ${debugReason(e)}');
              roleId = router.defaultRoleId;
            }
            // cache 到事件行（dirty=true 让 P2 备份带走）
            await repo.setRoutedRoleId(event.id, roleId);
          }
          final role = state.getRoleById(roleId);
          if (role == null) return;
          // 先取消旧，再注册新（OS 自己也会覆盖，显式 cancel 保险）
          await notif.cancelFor(event.id);
          // 用最新的事件态（含 routedRoleId）调度。这里直接拼一个 minimal copy
          // 即可（NotificationService 只读 startTime / reminderMinutes / title 等）
          await notif.scheduleFor(
            event.copyWith(routedRoleId: roleId),
            role,
          );
        },
        onDelete: (eventId) async {
          await notif.cancelFor(eventId);
        },
      );
    } catch (e) {
      debugPrint('bind calendar hooks failed: ${debugReason(e)}');
    }
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

  // ---- Lazy load: per-conversation messages（分页）----

  /// 单页大小——首次进入加载最新这么多条，向上滚动每次再追加这么多更早的。
  static const _kMessagePageSize = 50;

  /// 已加载过首屏（latest 页）的会话 scope。键形如 `'role:<id>'` / `'group:<id>'`。
  final Set<String> _loadedScopes = {};

  /// 该 scope 是否还有更早的消息可拉（false = 已经到顶）。未加载过的 scope 不
  /// 在 map 里；调用方应该用 [hasMoreMessages] 检查。
  final Map<String, bool> _scopeHasMore = {};

  /// 正在为该 scope 拉取消息（首屏或翻页）——避免并发重复请求。
  final Set<String> _scopeLoading = {};

  bool hasMoreMessages(String scopeKey) => _scopeHasMore[scopeKey] ?? false;

  /// 进入某私聊页时调——首次加载最新一页消息。幂等：已加载/正在加载时直接返回。
  Future<void> ensureRoleMessagesLoaded(String roleId) async {
    final key = ConversationSummary.keyForRole(roleId);
    if (_loadedScopes.contains(key) || _scopeLoading.contains(key)) return;
    _scopeLoading.add(key);
    try {
      final db = await _db;
      final rows = await db.messagesForRoleLatest(roleId,
          limit: _kMessagePageSize);
      _appendLoadedMessages(rows);
      _loadedScopes.add(key);
      _scopeHasMore[key] = rows.length == _kMessagePageSize;
    } catch (e) {
      debugPrint(
          'ensureRoleMessagesLoaded($roleId) failed: ${debugReason(e)}');
    } finally {
      _scopeLoading.remove(key);
    }
  }

  /// 向上翻页：拉早于当前已加载最旧消息的下一页。
  /// 返回 true 表示这次拉到了新消息，UI 可以决定是否提示。
  Future<bool> loadMoreRoleMessages(String roleId) async {
    final key = ConversationSummary.keyForRole(roleId);
    if (!hasMoreMessages(key) || _scopeLoading.contains(key)) return false;
    final oldest = _oldestTimestampForScope(key);
    if (oldest == null) return false;
    _scopeLoading.add(key);
    try {
      final db = await _db;
      final rows = await db.messagesForRoleBefore(roleId,
          beforeTimestamp: oldest, limit: _kMessagePageSize);
      _appendLoadedMessages(rows);
      _scopeHasMore[key] = rows.length == _kMessagePageSize;
      return rows.isNotEmpty;
    } catch (e) {
      debugPrint(
          'loadMoreRoleMessages($roleId) failed: ${debugReason(e)}');
      return false;
    } finally {
      _scopeLoading.remove(key);
    }
  }

  /// 群聊版 [ensureRoleMessagesLoaded]。
  Future<void> ensureGroupMessagesLoaded(String groupId) async {
    final key = ConversationSummary.keyForGroup(groupId);
    if (_loadedScopes.contains(key) || _scopeLoading.contains(key)) return;
    _scopeLoading.add(key);
    try {
      final db = await _db;
      final rows = await db.messagesForGroupLatest(groupId,
          limit: _kMessagePageSize);
      _appendLoadedMessages(rows);
      _loadedScopes.add(key);
      _scopeHasMore[key] = rows.length == _kMessagePageSize;
    } catch (e) {
      debugPrint(
          'ensureGroupMessagesLoaded($groupId) failed: ${debugReason(e)}');
    } finally {
      _scopeLoading.remove(key);
    }
  }

  /// 群聊版 [loadMoreRoleMessages]。
  Future<bool> loadMoreGroupMessages(String groupId) async {
    final key = ConversationSummary.keyForGroup(groupId);
    if (!hasMoreMessages(key) || _scopeLoading.contains(key)) return false;
    final oldest = _oldestTimestampForScope(key);
    if (oldest == null) return false;
    _scopeLoading.add(key);
    try {
      final db = await _db;
      final rows = await db.messagesForGroupBefore(groupId,
          beforeTimestamp: oldest, limit: _kMessagePageSize);
      _appendLoadedMessages(rows);
      _scopeHasMore[key] = rows.length == _kMessagePageSize;
      return rows.isNotEmpty;
    } catch (e) {
      debugPrint(
          'loadMoreGroupMessages($groupId) failed: ${debugReason(e)}');
      return false;
    } finally {
      _scopeLoading.remove(key);
    }
  }

  /// 把 db row 合并进 state.messages，按 id 去重避免重复加载。
  void _appendLoadedMessages(List<MessageRow> rows) {
    if (rows.isEmpty) return;
    final existingIds = state.messages.map((m) => m.id).toSet();
    final fresh = rows
        .map(messageFromRow)
        .where((m) => !existingIds.contains(m.id))
        .toList();
    if (fresh.isEmpty) return;
    state = state.copyWith(messages: [...state.messages, ...fresh]);
  }

  /// 该 scope 当前已加载消息中最早的时间戳——翻页时作 before 锚点。
  int? _oldestTimestampForScope(String scopeKey) {
    final filtered = state.messages.where((m) {
      if (scopeKey.startsWith('role:')) {
        return m.groupId == null &&
            m.roleId == scopeKey.substring('role:'.length);
      }
      if (scopeKey.startsWith('group:')) {
        return m.groupId == scopeKey.substring('group:'.length);
      }
      return false;
    });
    if (filtered.isEmpty) return null;
    return filtered.map((m) => m.timestamp).reduce((a, b) => a < b ? a : b);
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
    await prefs.setBool(
        'showReminderDetailsOnLockScreen', state.showReminderDetailsOnLockScreen);
    await prefs.setStringList(
        'exchangeFavoritePairs', state.exchangeFavoritePairs);
  }

  // ---- DB write helpers（fire-and-forget；失败入日志，不阻塞 UI）----

  void _persistMessage(Message m) {
    unawaited(_db.then((db) => db.insertMessage(messageToCompanion(m))));
    _bumpConversationSummary(m);
  }

  void _persistMessagesForRoleDelete(String roleId) {
    unawaited(_db.then((db) async {
      final paths = await db.attachmentPathsForRole(roleId);
      await db.deleteMessagesForRole(roleId);
      await _cleanupOrphanAttachments(db, paths);
    }));
  }

  void _persistMessagesForGroupDelete(String groupId) {
    unawaited(_db.then((db) async {
      final paths = await db.attachmentPathsForGroup(groupId);
      await db.deleteMessagesForGroup(groupId);
      await _cleanupOrphanAttachments(db, paths);
    }));
  }

  /// 删完消息后清理私有附件副本：转发会共享同一路径，仅当库里再无引用才删文件。
  Future<void> _cleanupOrphanAttachments(
      PikppoDatabase db, List<String> paths) async {
    for (final path in paths.toSet()) {
      if (await db.countMessagesWithAttachment(path) == 0) {
        await AttachmentStore.delete(path);
      }
    }
  }

  // ---- Memory writes（统一委托 MemoryRepository，盖戳 + 软删 + 副作用编排）----

  void _persistMemory(Memory m) {
    unawaited(_ref
        .read(memoryRepositoryProvider.future)
        .then((repo) => repo.add(m)));
  }

  void _persistMemoryDelete(String id) {
    unawaited(_ref
        .read(memoryRepositoryProvider.future)
        .then((repo) => repo.delete(id)));
  }

  void _persistMemoriesClear() {
    unawaited(_ref
        .read(memoryRepositoryProvider.future)
        .then((repo) => repo.clearAll()));
  }

  void _persistGroup(Group g) {
    unawaited(_db.then((db) => db.insertGroup(groupToCompanion(g))));
  }

  void _persistGroupDelete(String id) {
    unawaited(_db.then((db) async {
      final paths = await db.attachmentPathsForGroup(id);
      await db.deleteGroup(id);
      await db.deleteMessagesForGroup(id);
      await _cleanupOrphanAttachments(db, paths);
    }));
  }

  void _persistCustomRole(Role role) {
    unawaited(_db.then((db) => db.insertCustomRole(customRoleToCompanion(role))));
  }

  /// 批量提交 memory diff——委托 [MemoryRepository.applyDiff]，事务内一次落盘
  /// 并共用同一 updatedAt 时间戳。
  void _persistMemoryDiff({
    required Map<String, Memory> updated,
    required List<Memory> added,
  }) {
    if (updated.isEmpty && added.isEmpty) return;
    unawaited(_ref.read(memoryRepositoryProvider.future).then((repo) =>
        repo.applyDiff(updated: updated.values, added: added)));
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

  /// 用当前模型把 [text] 翻译成用户首选语言（本身已是该语言则译成英文）。
  /// **一次性调用，不进对话历史**——供消息选择菜单"翻译"的弹窗用。
  /// 未配置模型时抛 [StateError]（调用方在弹窗里转成友好提示）。
  /// 翻译选中/整条文本——返回译文 + 推荐标签（供"保存到知识卡片"用）。
  Future<LlmCardResult> translateText(String text) async {
    final service = modelService();
    if (service == null || state.currentModel.isEmpty) {
      throw StateError('未配置模型');
    }
    final lang = state.preferredLanguage;
    final hint = await _tagReuseHint(text);
    final prompt = '把下面的文本翻译成$lang；如果它本身就是$lang，则翻译成英文。\n'
        '只输出 JSON，不要任何额外说明：{"text":"译文","tags":["主题/领域标签"]}\n'
        'tags 给 1-3 个简短标签（如 英语、商务、技术），无合适标签给空数组。\n'
        '$hint'
        '\n原文：$text';
    final raw = await service.chat([
      {'role': 'user', 'content': prompt},
    ], state.currentModel);
    return _parseCardResult(raw);
  }

  /// 用当前模型解释 [term] 在 [context]（它所在的一两句）里的含义。**一次性调用，
  /// 只带词 + 最小必要语境，不拖整段对话历史、不进对话历史**——供消息选择菜单
  /// "解释"的弹窗用。归属：这是用户显式触发的、需要知识广度的外部 LLM 查询，
  /// 本就该走模型，不是被错塞外部的本地能力。未配置模型时抛 [StateError]。
  /// 解释 [term] 在 [context] 里的含义——返回释义 + 推荐标签。
  Future<LlmCardResult> explainInContext(String term, String context) async {
    final service = modelService();
    if (service == null || state.currentModel.isEmpty) {
      throw StateError('未配置模型');
    }
    final lang = state.preferredLanguage;
    final hint = await _tagReuseHint('$term $context');
    final prompt = '用$lang简洁解释下面这段话里"$term"指什么——只解释它在该语境中的'
        '含义，必要时补一句背景，不要复述原文、不要展开无关内容。\n'
        '只输出 JSON，不要任何额外说明：{"text":"释义正文","tags":["主题/领域标签"]}\n'
        'tags 给 1-3 个简短标签（如 金融、英语、编程），无合适标签给空数组。\n'
        '$hint'
        '\n语境：$context';
    final raw = await service.chat([
      {'role': 'user', 'content': prompt},
    ], state.currentModel);
    return _parseCardResult(raw);
  }

  /// 一键优化某张知识卡片——把释义改写得更清晰精炼，同时重新推荐标签。返回供
  /// UI 预览，用户确认后再 [updateKnowledgeCard] 落库。
  Future<LlmCardResult> optimizeKnowledgeCard(KnowledgeCard card) async {
    final service = modelService();
    if (service == null || state.currentModel.isEmpty) {
      throw StateError('未配置模型');
    }
    final lang = state.preferredLanguage;
    final hint = await _tagReuseHint('${card.term} ${card.content}');
    final prompt = '下面是一张知识卡片的词条与释义。用$lang把释义改写得更清晰、准确、'
        '精炼（保持原意，去冗余、补必要背景），并重新推荐标签。\n'
        '只输出 JSON：{"text":"优化后的释义","tags":["标签"]}\n'
        'tags 给 1-3 个简短主题/领域标签。\n'
        '$hint'
        '\n词条：${card.term}\n释义：${card.content}';
    final raw = await service.chat([
      {'role': 'user', 'content': prompt},
    ], state.currentModel);
    return _parseCardResult(raw);
  }

  /// 候选标签软约束行——取已有标签里与当前文本相关的（[KnowledgeRepository.
  /// candidateTags]：字面命中 + 频次兜底），拼成提示让 LLM 优先复用、收敛词表。
  /// 空词表返回空串（不污染 prompt）。纯本地，无额外请求。
  Future<String> _tagReuseHint(String text) async {
    try {
      final repo = await _ref.read(knowledgeRepositoryProvider.future);
      final candidates = await repo.candidateTags(text);
      if (candidates.isEmpty) return '';
      return '已有标签（尽量复用下列，确无合适再新建）：${candidates.join('、')}\n';
    } catch (_) {
      // 标签收敛是锦上添花——取不到候选就退化成无约束推荐，绝不阻断释义/翻译。
      return '';
    }
  }

  /// 宽容解析 LLM 的 `{"text":..,"tags":[..]}` 返回——剥代码围栏、取首个 JSON 对象；
  /// 解析失败则整段当正文、无标签（绝不让一次格式抖动毁掉结果）。
  LlmCardResult _parseCardResult(String raw) {
    final s = raw.trim();
    final start = s.indexOf('{');
    final end = s.lastIndexOf('}');
    if (start >= 0 && end > start) {
      try {
        final m = jsonDecode(s.substring(start, end + 1)) as Map;
        final text =
            (m['text'] ?? m['explanation'] ?? m['translation'] ?? '')
                .toString()
                .trim();
        final tags = (m['tags'] as List?)
                ?.map((e) => e.toString().trim())
                .where((t) => t.isNotEmpty)
                .take(5)
                .toList() ??
            const <String>[];
        if (text.isNotEmpty) return LlmCardResult(text, tags);
      } catch (_) {}
    }
    return LlmCardResult(s, const []);
  }

  // ---- 知识卡片（委托 [KnowledgeRepository]）----

  /// 保存一张知识卡片（释义/翻译弹窗的"保存到知识卡片"）。id/createdAt 在此生成。
  /// [source] 来源分类（释义/翻译），[tags] 仅话题标签（用户勾选的 LLM 推荐）。
  Future<void> saveKnowledgeCard({
    required String term,
    required String content,
    required String source,
    required List<String> tags,
  }) async {
    final repo = await _ref.read(knowledgeRepositoryProvider.future);
    await repo.add(KnowledgeCard(
      id: _uuid.v4(),
      term: term.trim(),
      content: content.trim(),
      source: source,
      tags: tags,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    ));
  }

  Future<void> updateKnowledgeCard(KnowledgeCard card) async {
    final repo = await _ref.read(knowledgeRepositoryProvider.future);
    await repo.update(card);
  }

  Future<void> deleteKnowledgeCard(String id) async {
    final repo = await _ref.read(knowledgeRepositoryProvider.future);
    await repo.delete(id);
  }

  /// 设置卡片重要程度（收藏切换：0/1）——只动 importance，不碰标签关联。
  Future<void> setKnowledgeCardImportance(String id, int importance) async {
    final repo = await _ref.read(knowledgeRepositoryProvider.future);
    await repo.setImportance(id, importance);
  }

  /// 收藏一个汇率对（[from]/[to]）到"常用"。已存在则不重复，新对追加到末尾。
  void addExchangePair(String from, String to) {
    final pair = '$from/$to';
    if (state.exchangeFavoritePairs.contains(pair)) return;
    state = state.copyWith(
      exchangeFavoritePairs: [...state.exchangeFavoritePairs, pair],
    );
    _saveState();
  }

  /// 从"常用"移除一个汇率对（`FROM/TO`）。
  void removeExchangePair(String pair) {
    if (!state.exchangeFavoritePairs.contains(pair)) return;
    state = state.copyWith(
      exchangeFavoritePairs:
          state.exchangeFavoritePairs.where((p) => p != pair).toList(),
    );
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

  /// 对话内一步切换云端 provider + 模型——单次 state 更新避免中间态（如
  /// provider 已切、model 还是旧家的）被 UI/请求读到。provider 未变则只换
  /// 模型，不重置用户自定义 host。
  void switchCloudProviderAndModel(String provider, String model) {
    if (state.serviceType != 'cloud' || state.cloudProvider != provider) {
      state = state.copyWith(
        serviceType: 'cloud',
        cloudProvider: provider,
        serviceHost: _cloudDefaultHost(provider),
        currentModel: model,
      );
    } else {
      state = state.copyWith(currentModel: model);
    }
    _saveState();
  }

  /// 从 [cloudProviderCatalog] 取该 provider 的默认 host——加新 provider 时
  /// 只改 catalog，本函数不动。
  static String _cloudDefaultHost(String provider) =>
      cloudProviderSpec(provider).defaultHost;

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

  /// 锁屏显示提醒详情开关——同步到 NotificationService（下次 schedule 生效，
  /// 已注册的不回头改；产品决定）+ 持久化。
  void updateShowReminderDetailsOnLockScreen(bool show) {
    state = state.copyWith(showReminderDetailsOnLockScreen: show);
    _ref.read(notificationServiceProvider).setShowDetailsOnLockScreen(show);
    _saveState();
  }

  /// 显式请求通知权限——首次打开设置页 / 首次创建带提醒事件时调。
  /// 返回 true 表示用户授权（或 OS 不需要授权）。
  Future<bool> requestNotificationPermissions() {
    return _ref.read(notificationServiceProvider).requestPermissions();
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
      cloudApiKeys: _ref.read(cloudApiKeysProvider),
    );
  }

  /// 启动兜底：currentModel 为空时给当前 cloud provider 拉一次模型列表、取首个
  /// 作默认，顺手写回缓存（切换面板秒开）。任何失败都静默——零配置体验不能因
  /// 网络抖动卡死，留空由聊天页横幅提示。
  Future<void> _bootstrapDefaultModel() async {
    try {
      final provider = state.cloudProvider;
      final service = buildModelService(
        type: 'cloud',
        host: _cloudDefaultHost(provider),
        localProvider: '',
        cloudProvider: provider,
        cloudApiKeys: _ref.read(cloudApiKeysProvider),
      );
      if (service == null) return; // key 缺失
      final models = await service.fetchModels();
      if (models.isEmpty) return;
      // 期间用户可能已手动选过模型，别覆盖。
      if (state.currentModel.isEmpty) {
        state = state.copyWith(currentModel: models.first);
        _saveState();
      }
      final updated = {..._ref.read(modelCacheProvider), provider: models};
      _ref.read(modelCacheProvider.notifier).state = updated;
      unawaited(persistModelCache(updated));
    } catch (e) {
      debugPrint('bootstrap default model failed: ${debugReason(e)}');
    }
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
  /// [charts] 非空时把图表卡片挂在这条消息上，与文字同气泡渲染（图在上、文字在下）。
  void appendAiMessage(String content, {List<String>? charts}) {
    final aiMsg = Message(
      id: _uuid.v4(),
      roleId: state.currentRoleId,
      content: content,
      isUser: false,
      timestamp: DateTime.now().millisecondsSinceEpoch,
      chartData: encodeChartData(charts),
    );
    state = state.copyWith(
      messages: [...state.messages, aiMsg],
      isLoading: false,
      clearToolStatus: true,
    );
    _persistMessage(aiMsg);
  }

  /// 失败回复气泡——kind='error'。**不落库、不进 LLM 历史**（history 只取
  /// kind=='chat'），仅当次会话展示，气泡下方带"重试"。退出 loading。
  void appendAiError(String content) {
    final errMsg = Message(
      id: _uuid.v4(),
      roleId: state.currentRoleId,
      content: content,
      isUser: false,
      timestamp: DateTime.now().millisecondsSinceEpoch,
      kind: 'error',
    );
    state = state.copyWith(
      messages: [...state.messages, errMsg],
      isLoading: false,
      clearToolStatus: true,
    );
  }

  /// 重试：抹掉当前私聊尾部的 error 气泡 + 重新进入 loading，再委托
  /// MessagingController 用现有历史（末条仍是那条用户消息）重新生成。
  Future<void> retryLastReply() {
    removeTrailingErrorForRetry();
    return _messaging.retryLastReply();
  }

  /// 移除当前私聊会话尾部连续的 error 气泡，并重新进入 loading 态。
  /// 给 [MessagingController.retryLastReply] 用——error 气泡未落库，只在内存清。
  void removeTrailingErrorForRetry() {
    final errorIds = state.currentRoleMessages
        .where((m) => m.kind == 'error')
        .map((m) => m.id)
        .toSet();
    state = state.copyWith(
      messages:
          state.messages.where((m) => !errorIds.contains(m.id)).toList(),
      isLoading: true,
      clearToolStatus: true,
    );
  }

  /// agent loop 执行工具期间的瞬时提示。[label] 为 null 时清空。
  void setToolStatus(String? label) {
    if (label == null) {
      state = state.copyWith(clearToolStatus: true);
    } else {
      state = state.copyWith(toolStatus: label);
    }
  }

  /// 退出 loading 但不追加消息（如：currentModel 为空时直接 return）。
  void setIdle() {
    state = state.copyWith(isLoading: false, clearToolStatus: true);
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

    // 明确告知模型哪些工具可用——避免它在 MCP 离线时编造"我帮你查到的"日程
    // 等不存在的用户数据。
    final toolNames = <String>[
      ..._localTools.definitions().map((t) => t.name),
      if (_mcp.isConnected) ..._mcp.tools.map((t) => t.name),
    ];
    if (toolNames.isEmpty) {
      lines.add('- 当前**没有任何外部工具可用**（日历/邮件/搜索 等均不可调用）。');
    } else {
      lines.add('- 当前可调用工具：${toolNames.join('、')}');
    }

    // 反编造硬约束——这是必须存在的护栏，无论工具是否可用都加。
    lines.add(
      '\n【关于用户特定数据的硬约束】\n'
      '用户的日程、邮件、记忆、联系人、账单等**用户私有数据**，你只能通过上面'
      '列出的工具实际查询得到。**绝对禁止**以下行为：\n'
      '- 在没有工具返回结果的情况下，编造任何具体日程/邮件/事件\n'
      '- 用"可能"、"也许"、"猜测"等措辞包装编造的具体内容\n'
      '- 假装你已经查过用户的数据\n'
      '当用户问及这类数据而工具不可用或未调用时，**必须直接说明"我目前没有访问'
      '<日历/邮件/...>的工具，无法查到具体内容"**，让用户决定下一步。',
    );
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

  // ---- Calendar（委托给 [CalendarRepository]） ----

  Future<void> addCalendarEvent(CalendarEventDraft draft) async {
    final repo = await _ref.read(calendarRepositoryProvider.future);
    await repo.create(draft);
  }

  Future<void> updateCalendarEvent(
      String id, CalendarEventPatch patch) async {
    final repo = await _ref.read(calendarRepositoryProvider.future);
    await repo.update(id, patch);
  }

  Future<void> deleteCalendarEvent(String id) async {
    final repo = await _ref.read(calendarRepositoryProvider.future);
    await repo.delete(id);
  }

  /// 给 system prompt 拼"近 7 天日历"段——从本地实时流读，与 UI 一致。
  /// 流尚未发出第一个值时回退到 listRange 兜底（首次启动场景）。
  Future<String> _buildCalendarContext() async {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final end = today.add(const Duration(days: 7));

    List<CalendarEvent> events;
    try {
      final cached = _ref.read(upcomingCalendarEventsProvider).valueOrNull;
      if (cached != null) {
        events = cached
            .where((e) =>
                !e.localStart.isBefore(today) && !e.localStart.isAfter(end))
            .toList();
      } else {
        final repo = await _ref.read(calendarRepositoryProvider.future);
        events = await repo.listRange(today.toUtc(), end.toUtc());
      }
    } catch (e) {
      debugPrint('build calendar context failed: ${debugReason(e)}');
      return '';
    }

    if (events.isEmpty) return '\n\n用户日历：近7天无日程。';

    final weekdays = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
    final buf = StringBuffer('\n\n用户日历（近7天）：');
    for (final e in events) {
      final localDate = e.localDate;
      final dayLabel = localDate == today
          ? '今天'
          : localDate == today.add(const Duration(days: 1))
              ? '明天'
              : '${localDate.month}/${localDate.day}(${weekdays[localDate.weekday - 1]})';
      final time = e.localTimeLabel ?? '全天';
      final reminder = e.reminderMinutes != null ? ' [${e.reminderText}提醒]' : '';
      final desc = e.description.isNotEmpty ? ' - ${e.description}' : '';
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

  /// 删除选中的若干条消息（多选删除）——删的是单/多条，不是整个会话。
  /// 同步抹掉内存 + drift；附件副本按"库里再无引用"清理。删后重算受影响
  /// 会话的摘要（聊天列表的末条预览），空会话则清掉摘要。
  Future<void> deleteMessages(Set<String> ids) async {
    if (ids.isEmpty) return;
    final removed =
        state.messages.where((m) => ids.contains(m.id)).toList();
    if (removed.isEmpty) return;
    // 受影响的会话 scope key——删完要重算其摘要。
    final affectedRoleIds = removed
        .where((m) => m.groupId == null)
        .map((m) => m.roleId)
        .toSet();
    final affectedGroupIds =
        removed.map((m) => m.groupId).whereType<String>().toSet();

    state = state.copyWith(
      messages: state.messages.where((m) => !ids.contains(m.id)).toList(),
    );

    final db = await _db;
    final attachmentPaths =
        removed.map((m) => m.attachmentPath).whereType<String>().toList();
    for (final id in ids) {
      await db.deleteMessage(id);
    }
    await _cleanupOrphanAttachments(db, attachmentPaths);

    for (final roleId in affectedRoleIds) {
      await _recomputeRoleSummary(db, roleId);
    }
    for (final groupId in affectedGroupIds) {
      await _recomputeGroupSummary(db, groupId);
    }
  }

  /// 删消息后重算某私聊会话的摘要：取库里现存末条；空会话则清掉摘要。
  Future<void> _recomputeRoleSummary(PikppoDatabase db, String roleId) async {
    final rows = await db.messagesForRoleLatest(roleId, limit: 1);
    final key = ConversationSummary.keyForRole(roleId);
    if (rows.isEmpty) {
      _clearConversationSummary(key);
      return;
    }
    _setConversationSummary(key, rows.last.timestamp, rows.last.content);
  }

  Future<void> _recomputeGroupSummary(
      PikppoDatabase db, String groupId) async {
    final rows = await db.messagesForGroupLatest(groupId, limit: 1);
    final key = ConversationSummary.keyForGroup(groupId);
    if (rows.isEmpty) {
      _clearConversationSummary(key);
      return;
    }
    _setConversationSummary(key, rows.last.timestamp, rows.last.content);
  }

  void _setConversationSummary(String key, int timestamp, String content) {
    final next = Map<String, ConversationSummary>.from(
        state.conversationSummaries)
      ..[key] = ConversationSummary(
        scopeKey: key,
        lastTimestamp: timestamp,
        lastContent: content,
      );
    state = state.copyWith(conversationSummaries: next);
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

  /// 群聊里某个角色回复。[charts] 非空时把图表卡片挂在这条消息上同气泡渲染。
  void appendGroupAiMessage(String groupId, String roleId, String content,
      {List<String>? charts}) {
    final aiMsg = Message(
      id: _uuid.v4(),
      roleId: roleId,
      content: content,
      isUser: false,
      timestamp: DateTime.now().millisecondsSinceEpoch,
      groupId: groupId,
      chartData: encodeChartData(charts),
    );
    state = state.copyWith(messages: [...state.messages, aiMsg]);
    _persistMessage(aiMsg);
  }

  /// 群聊里某个角色回复失败的 error 气泡——kind='error'，带发言人 roleId。
  /// **不落库、不进 LLM 历史**，仅当次会话展示，气泡下方"重试"重跑该角色。
  /// 不动 loading（多角色循环里逐个调，loading 由 [clearGroupLoading] 统一收尾）。
  void appendGroupAiError(String groupId, String roleId, String content) {
    final errMsg = Message(
      id: _uuid.v4(),
      roleId: roleId,
      content: content,
      isUser: false,
      timestamp: DateTime.now().millisecondsSinceEpoch,
      groupId: groupId,
      kind: 'error',
    );
    state = state.copyWith(messages: [...state.messages, errMsg]);
  }

  /// 群聊全部角色回复完后退出 loading。
  void clearGroupLoading() {
    state = state.copyWith(clearLoadingGroupId: true);
  }

  /// 重试群聊里某条失败回复：抹掉那条 error 气泡 + 进入 loading，再委托
  /// MessagingController 只重跑该角色（其余已成功的回复不动）。
  Future<void> retryGroupReply(
      String groupId, String roleId, String errorMsgId) {
    state = state.copyWith(
      messages: state.messages.where((m) => m.id != errorMsgId).toList(),
      loadingGroupId: groupId,
    );
    return _messaging.retryGroupRoleReply(groupId, roleId);
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
