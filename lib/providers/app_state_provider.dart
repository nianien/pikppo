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
import '../services/agent.dart';
import '../services/model_service.dart';
import '../services/ollama_service.dart';
import '../services/lmstudio_service.dart';
import '../services/cloud_model_service.dart';
import '../services/mcp_service.dart';
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
  Timer? _reminderTimer;
  Timer? _summaryTimer;
  StreamSubscription<McpConnectionState>? _mcpSub;
  final Set<String> _remindedEventIds = {};
  DateTime _lastUserActivity = DateTime.now();
  bool _summaryRunning = false;

  AppStateNotifier(this._ref)
      : super(const AppState(
          roles: defaultRoles,
          messages: [],
          memories: [],
          currentRoleId: 'work',
          currentModel: '',
          serviceType: 'ollama',
          serviceHost: 'http://localhost:11434',
        )) {
    _loadState();
    _startReminderCheck();
    _startSummaryLoop();
    _wireMcpListener();
    // Fire-and-forget: 不阻塞首屏；权限弹窗会自然出现在首次 GPS 请求时。
    unawaited(_ref.read(locationServiceProvider).refresh());
  }

  @override
  void dispose() {
    _reminderTimer?.cancel();
    _summaryTimer?.cancel();
    _mcpSub?.cancel();
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

  Future<void> reconnectMcp({String? host}) async {
    final target = host ?? state.mcpHost;
    if (target.isEmpty) return;
    state = state.copyWith(mcpHost: target);
    await _saveState();
    await _mcp.connect(target);
  }

  void updateMcpHost(String host) {
    state = state.copyWith(mcpHost: host);
    _saveState();
  }

  // ---- Reminder loop ----

  void _startReminderCheck() {
    _reminderTimer = Timer.periodic(_kReminderInterval, (_) {
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
      if (diffMinutes > 0 &&
          diffMinutes <= event.reminderMinutes! &&
          !_remindedEventIds.contains(event.id)) {
        _remindedEventIds.add(event.id);
        final desc = event.description != null ? '\n${event.description}' : '';
        final timeHint = diffMinutes >= 60
            ? '约${diffMinutes ~/ 60}小时后'
            : '$diffMinutes分钟后';
        _addReminderMessage(
          '⏰ 日程提醒（$timeHint开始）\n${event.time} ${event.title}$desc',
        );
      }
    }
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
    _saveState();
  }

  // ---- Persistence ----

  Future<void> _loadState() async {
    final prefs = await SharedPreferences.getInstance();
    final roleId = prefs.getString('currentRoleId') ?? 'work';
    final model = prefs.getString('currentModel') ?? '';
    final serviceType = prefs.getString('serviceType') ?? 'ollama';
    final serviceHost =
        prefs.getString('serviceHost') ?? 'http://localhost:11434';
    final mcpHost = prefs.getString('mcpHost') ?? 'http://localhost:8000';
    final cloudProvider = prefs.getString('cloudProvider') ?? 'anthropic';
    final userName = prefs.getString('userName') ?? '';
    final language = prefs.getString('preferredLanguage') ?? '中文';
    final onboardingCompleted = prefs.getBool('onboardingCompleted') ?? false;

    final rolesJson = prefs.getString('customRoles');
    final roles = <Role>[...defaultRoles];
    if (rolesJson != null) {
      final customRoles = (jsonDecode(rolesJson) as List)
          .map((e) => Role.fromJson(e as Map<String, dynamic>))
          .toList();
      roles.addAll(customRoles);
    }

    final messagesJson = prefs.getString('messages');
    final messages = messagesJson == null
        ? <Message>[]
        : (jsonDecode(messagesJson) as List)
            .map((e) => Message.fromJson(e as Map<String, dynamic>))
            .toList();

    final memoriesJson = prefs.getString('memories');
    final memories = memoriesJson == null
        ? <Memory>[]
        : (jsonDecode(memoriesJson) as List)
            .map((e) => Memory.fromJson(e as Map<String, dynamic>))
            .toList();

    final groupsJson = prefs.getString('groups');
    var groups = <Group>[];
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
      mcpHost: mcpHost,
      cloudProvider: cloudProvider,
      userName: userName,
      preferredLanguage: language,
      onboardingCompleted: onboardingCompleted,
    );

    // Load cloud API key (no-op if storage absent), then start MCP connection.
    try {
      await loadAnthropicApiKeyWith(
        storage: _ref.read(secureStorageProvider),
        setKey: (v) =>
            _ref.read(anthropicApiKeyProvider.notifier).state = v,
      );
    } catch (e) {
      debugPrint('loadAnthropicApiKey error: $e');
    }

    unawaited(_mcp.connect(mcpHost));
  }

  Future<void> _saveState() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('currentRoleId', state.currentRoleId);
    await prefs.setString('currentModel', state.currentModel);
    await prefs.setString('serviceType', state.serviceType);
    await prefs.setString('serviceHost', state.serviceHost);
    await prefs.setString('mcpHost', state.mcpHost);
    await prefs.setString('cloudProvider', state.cloudProvider);
    await prefs.setString('userName', state.userName);
    await prefs.setString('preferredLanguage', state.preferredLanguage);
    await prefs.setBool('onboardingCompleted', state.onboardingCompleted);

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

  // ---- Settings mutations ----

  void switchRole(String roleId) {
    state = state.copyWith(currentRoleId: roleId);
    _saveState();
  }

  void switchModel(String model) {
    state = state.copyWith(currentModel: model);
    _saveState();
  }

  void updateServiceType(String type) {
    final host = switch (type) {
      'ollama' => 'http://localhost:11434',
      'lmstudio' => 'http://localhost:1234',
      'cloud' => 'https://api.anthropic.com',
      _ => state.serviceHost,
    };
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

  void completeOnboarding() {
    state = state.copyWith(onboardingCompleted: true);
    _saveState();
  }

  // ---- Model service factory ----

  ModelService? _modelService() {
    if (state.serviceType == 'cloud') {
      final apiKey = _ref.read(anthropicApiKeyProvider) ?? '';
      if (apiKey.isEmpty) return null;
      return CloudModelService(apiKey: apiKey, host: state.serviceHost);
    }
    if (state.serviceHost.isEmpty || state.currentModel.isEmpty) return null;
    if (state.serviceType == 'ollama') {
      return OllamaService(state.serviceHost);
    }
    return LMStudioService(state.serviceHost);
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
    _saveState();

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
          await _buildPrivateSystemPrompt(role, state.currentRoleId);

      // Agentic path (Claude + MCP connected): the model decides which tools
      // to call. No need for the bespoke calendar regex/extraction path.
      if (service.supportsTools && _mcp.isConnected) {
        final tools = await _mcp.ensureTools();
        if (tools.isNotEmpty) {
          await _runAgentLoop(
            service: service,
            systemContent: systemContent,
            userInput: content,
          );
          return;
        }
      }

      // Non-agent path: kick off bespoke calendar extraction + reminder parse
      // in parallel (doesn't block reply), then a plain chat completion.
      _aiExtractCalendarEvents(content, service).then((events) async {
        if (events.isEmpty) return;
        final succeeded = <CalendarEvent>[];
        final failures = <String>[];
        for (final event in events) {
          try {
            await addCalendarEvent(event);
            succeeded.add(event);
          } catch (e) {
            debugPrint('auto-add calendar event failed: $e');
            failures.add(e is McpUnavailableException
                ? 'MCP 服务未连接'
                : e.toString());
          }
        }
        if (succeeded.isNotEmpty) {
          final parts = succeeded.map((e) {
            final t = e.time != null ? '${e.time} ' : '';
            final r = e.reminderMinutes != null ? '（${e.reminderText}提醒）' : '';
            return '$t${e.title}$r';
          }).join('、');
          _addAiStreamPart('📅 已自动添加日程：$parts');
        }
        if (failures.isNotEmpty) {
          _addAiStreamPart(
            '⚠️ 日程添加失败：${failures.first}',
            kind: 'reminder',
          );
        }
      });

      _handleReminderRequest(content, service);

      final history = state.currentRoleMessages
          .where((m) => m.kind == 'chat')
          .toList()
          .reversed
          .take(10)
          .toList()
          .reversed;
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
        _addAiMessage('无法连接到模型服务，请检查服务是否启动');
      } else {
        _addAiMessage('请求失败：$e');
      }
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
    final history = state.currentRoleMessages
        .where((m) => m.kind == 'chat')
        .toList()
        .reversed
        .take(10)
        .toList()
        .reversed;
    final messages = <Map<String, dynamic>>[
      ...history.map((m) => {
            'role': m.isUser ? 'user' : 'assistant',
            'content': m.content,
          }),
      // The latest user message is already in [history] (sendMessage appended
      // it before calling us), so we don't add it again here.
    ];

    final tools = _mcp.tools
        .map((t) => ToolDefinition(
              name: t.name,
              description: t.description,
              inputSchema: t.inputSchema,
            ))
        .toList();

    AgentStep step;
    try {
      step = await service.agentStart(
        system: systemContent,
        messages: messages,
        model: state.currentModel,
        tools: tools,
      );
    } catch (e) {
      debugPrint('agent start error: $e');
      _addAiMessage('请求失败：$e');
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

      // Execute tool calls in order, collecting results.
      final results = <ToolResult>[];
      for (final call in step.calls) {
        try {
          final raw = await _mcp.callTool(call.name, call.input);
          results.add(ToolResult(toolUseId: call.id, content: raw));
        } catch (e) {
          debugPrint('tool ${call.name} failed: $e');
          results.add(ToolResult(
            toolUseId: call.id,
            content: 'tool error: $e',
            isError: true,
          ));
        }
      }

      // Calendar mutations may have changed; refresh cache opportunistically.
      if (step.calls.any((c) => c.name.contains('calendar'))) {
        unawaited(_refreshCalendarCache());
      }

      messages.add(step.assistantMessage);
      messages.add(service.buildToolResultMessage(results));

      try {
        step = await service.agentContinue(
          system: systemContent,
          messages: messages,
          model: state.currentModel,
          tools: tools,
        );
      } catch (e) {
        debugPrint('agent continue error: $e');
        _addAiMessage('请求失败：$e');
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
    _saveState();
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

  /// Build the system prompt for a private chat with [role].
  Future<String> _buildPrivateSystemPrompt(Role role, String roleId) async {
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
    final buf = StringBuffer(role.systemPrompt);
    buf.write('\n\n${_buildContextHeader()}');
    if (profileMemories.isNotEmpty) {
      buf.write('\n\n关于用户：\n${profileMemories.join('、')}');
    }
    if (roleSemantic.isNotEmpty) {
      buf.write('\n\n${role.name}的专属记忆：\n${roleSemantic.join('、')}');
    }
    if (episodic.isNotEmpty) {
      buf.write('\n\n近期事件：\n${episodic.join('；')}');
    }
    if (calendarContext.isNotEmpty) {
      buf.write(calendarContext);
    }
    return buf.toString();
  }

  /// Session context: current time + location, fetched live from device.
  ///
  /// 时间总是实时；位置读 [LocationService] 缓存（永远不在 prompt 构建过程中
  /// 等待 GPS——首次定位异步进行，缓存命中后续 prompt 都能拿到）。
  String _buildContextHeader() {
    final now = DateTime.now();
    final weekdays = ['一', '二', '三', '四', '五', '六', '日'];
    final date = _fmtDate(now);
    final wd = weekdays[now.weekday - 1];
    final hh = now.hour.toString().padLeft(2, '0');
    final mm = now.minute.toString().padLeft(2, '0');
    final tz = now.timeZoneName;
    final offset = now.timeZoneOffset;
    final sign = offset.isNegative ? '-' : '+';
    final hOff = offset.inHours.abs().toString().padLeft(2, '0');
    final mOff = (offset.inMinutes.abs() % 60).toString().padLeft(2, '0');

    final buf = StringBuffer(
        '当前时间：$date 周$wd $hh:$mm（$tz UTC$sign$hOff:$mOff）');

    final loc = _ref.read(locationServiceProvider);
    final fix = loc.lastKnown;
    if (fix != null) {
      buf.write('\n当前位置：${fix.displayLabel}'
          '（${fix.latitude.toStringAsFixed(4)}, ${fix.longitude.toStringAsFixed(4)}）');
    } else if (loc.status == LocationStatus.denied ||
        loc.status == LocationStatus.deniedForever) {
      buf.write('\n当前位置：用户未授权');
    } else if (loc.status == LocationStatus.serviceDisabled) {
      buf.write('\n当前位置：设备定位服务关闭');
    }
    return buf.toString();
  }

  // ---- Memory ----

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

  // ---- Calendar (via MCP) ----

  Future<void> addCalendarEvent(CalendarEvent event) async {
    await _mcp.createEvent(event);
    await _refreshCalendarCache();
  }

  Future<void> updateCalendarEvent(CalendarEvent updated) async {
    await _mcp.updateEvent(updated);
    // 时间/提醒可能被调整，需要重新进入提醒窗口。
    _remindedEventIds.remove(updated.id);
    await _refreshCalendarCache();
  }

  Future<void> deleteCalendarEvent(String id) async {
    await _mcp.deleteEvent(id);
    _remindedEventIds.remove(id);
    await _refreshCalendarCache();
  }

  Future<List<CalendarEvent>> getEventsForDay(DateTime day) async {
    if (!_mcp.isConnected) return [];
    final dateStr = _fmtDate(day);
    return _mcp.listEvents(startDate: dateStr, endDate: dateStr);
  }

  Future<List<CalendarEvent>> getEventsForRange(
      DateTime start, DateTime end) async {
    if (!_mcp.isConnected) return [];
    return _mcp.listEvents(
        startDate: _fmtDate(start), endDate: _fmtDate(end));
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
      // 收敛去重集合：只保留窗口内仍然存在的事件 id，避免长期累积。
      final liveIds = events.map((e) => e.id).toSet();
      _remindedEventIds.retainAll(liveIds);
      state = state.copyWith(calendarEvents: events);
    } catch (e) {
      debugPrint('refreshCalendarCache error: $e');
    }
  }

  // ---- AI extraction (calendar) ----

  void _handleReminderRequest(String content, ModelService service) {
    _aiParseReminderRequest(content, service).then((minutes) async {
      if (minutes == null) return;
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
      try {
        await updateCalendarEvent(target.copyWith(reminderMinutes: minutes));
      } catch (e) {
        debugPrint('reminder update failed: $e');
        return;
      }
      final reminderText = minutes >= 1440
          ? '提前${minutes ~/ 1440}天'
          : (minutes >= 60 ? '提前${minutes ~/ 60}小时' : '提前$minutes分钟');
      _addAiMessage('🔔 已设置提醒：${target.time} ${target.title}（$reminderText）');
    });
  }

  Future<int?> _aiParseReminderRequest(
      String content, ModelService service) async {
    try {
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
      final match = RegExp(r'\d+').firstMatch(cleaned);
      if (match == null) return null;
      final val = int.tryParse(match.group(0)!);
      return (val != null && val > 0) ? val : null;
    } catch (e) {
      debugPrint('aiParseReminderRequest error: $e');
      return null;
    }
  }

  Future<List<CalendarEvent>> _aiExtractCalendarEvents(
      String userMessage, ModelService service) async {
    try {
      final now = DateTime.now();
      final weekday = ['一', '二', '三', '四', '五', '六', '日'][now.weekday - 1];
      final today = _fmtDate(now);
      final prompt = '''你是一个日程提取助手。分析以下文本，提取其中包含的日程/会议/约会/活动等事件。

规则：
1. 如果文本中没有任何日程相关内容，只返回 []
2. 如果有，返回JSON数组，每个事件格式：
   {"title":"简短标题","date":"YYYY-MM-DD","time":"HH:mm","description":"备注","reminderMinutes":数字}
3. title 要简洁
4. description 放会议号、链接、地点等补充信息，没有则不填
5. reminderMinutes：如果用户提到提醒，换算成分钟数填入；没提到则不填
6. time、description、reminderMinutes 都是可选字段
7. 只返回JSON数组，不要任何其他文字

当前：$today 周$weekday
日期换算："今天"=$today，"明天"+1天，"后天"+2天，"下周X"=下个周X的日期。

文本内容：
$userMessage''';
      final result = await service.chat([
        {'role': 'user', 'content': prompt},
      ], state.currentModel);
      final jsonStr = _extractJsonArray(result);
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

  String? _extractJsonArray(String text) {
    final start = text.indexOf('[');
    final end = text.lastIndexOf(']');
    if (start == -1 || end == -1 || end <= start) return null;
    return text.substring(start, end + 1);
  }

  String _fmtDate(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

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

  // ---- Groups ----

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
    _saveState();

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

        final calendarContext = await _buildCalendarContext();
        final visible = state.memoriesForRole(roleId);
        final profileMemories = visible
            .where((m) => m.roleId == null && m.type == 'semantic')
            .map((m) => m.content)
            .join('、');
        final roleSemantic = visible
            .where((m) => m.roleId == roleId && m.type == 'semantic')
            .map((m) => m.content)
            .join('、');
        final episodic = visible
            .where((m) => m.roleId == roleId && m.type == 'episodic')
            .take(5)
            .map((m) => m.content)
            .join('；');

        final otherNames = group.roleIds
            .where((id) => id != roleId)
            .map((id) => state.getRoleById(id)?.name ?? id)
            .join('、');

        final systemBuf = StringBuffer(role.systemPrompt);
        systemBuf.write('\n\n${_buildContextHeader()}');
        if (profileMemories.isNotEmpty) {
          systemBuf.write('\n\n关于用户：\n$profileMemories');
        }
        if (roleSemantic.isNotEmpty) {
          systemBuf.write('\n\n${role.name}的专属记忆：\n$roleSemantic');
        }
        if (episodic.isNotEmpty) {
          systemBuf.write('\n\n近期事件：\n$episodic');
        }
        if (calendarContext.isNotEmpty) systemBuf.write(calendarContext);
        systemBuf.write(
          '\n\n你正在群聊"${group.name}"中。其他成员：$otherNames。'
          '请基于自身能力简洁回复，不要重复其他成员已经说过的内容。',
        );

        final history = getGroupMessagesList(groupId)
            .where((m) => m.kind == 'chat')
            .toList()
            .reversed
            .take(10)
            .toList()
            .reversed;
        final messages = <Map<String, String>>[
          {'role': 'system', 'content': systemBuf.toString()},
          ...history.map((m) {
            if (m.isUser) return {'role': 'user', 'content': m.content};
            final speaker =
                state.getRoleById(m.roleId)?.name ?? m.roleId;
            return {'role': 'assistant', 'content': '[$speaker]: ${m.content}'};
          }),
        ];

        final reply = await service.chat(messages, state.currentModel);
        _addGroupAiMessage(groupId, roleId, reply);
        await Future.delayed(const Duration(milliseconds: 300));
      }
    } catch (e) {
      debugPrint('sendGroupMessage error: $e');
      final fallback = group.roleIds.first;
      if (e is DioException && e.type == DioExceptionType.connectionError) {
        _addGroupAiMessage(
            groupId, fallback, '无法连接到模型服务，请检查服务是否启动');
      } else {
        _addGroupAiMessage(groupId, fallback, '请求失败，请重试');
      }
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
      debugPrint('routeGroupMessage error: $e');
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
    _saveState();
  }

  // ---- Memory auto-summary ----

  void _startSummaryLoop() {
    _summaryTimer = Timer.periodic(_kMemorySummaryInterval, (_) {
      _maybeRunSummary(forceIdle: false);
    });
  }

  void _markActivity() {
    _lastUserActivity = DateTime.now();
  }

  Future<void> _maybeRunSummary({required bool forceIdle}) async {
    if (_summaryRunning) return;
    // 设计：定期 timer + 用户闲置时触发；显式触发（设置页"立即归纳"）可绕过空闲检查。
    if (!forceIdle) {
      final idleFor = DateTime.now().difference(_lastUserActivity);
      if (idleFor < _kIdleSummaryThreshold) return;
    }

    _summaryRunning = true;
    try {
      final service = _modelService();
      if (service == null) return;
      await _summarizeRoleConversations(service);
    } catch (e) {
      debugPrint('summary error: $e');
    } finally {
      _summaryRunning = false;
    }
  }

  /// Manually trigger a summary pass (used by settings page).
  Future<void> runMemorySummaryNow() async {
    await _maybeRunSummary(forceIdle: true);
  }

  /// For each role with new messages since the last summary, ask the LLM to
  /// extract durable facts and merge them into [memories]. Existing semantic
  /// memories visible to the role are passed in so the model can choose to
  /// `update` a stale fact (e.g. dietary change) instead of appending dupes.
  Future<void> _summarizeRoleConversations(ModelService service) async {
    final prefs = await SharedPreferences.getInstance();
    for (final role in state.roles) {
      final lastTs = prefs.getInt('summaryLastTs_${role.id}') ?? 0;
      final recent = state.messages
          .where((m) =>
              m.roleId == role.id && m.kind == 'chat' && m.timestamp > lastTs)
          .toList()
        ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
      if (recent.length < 4) continue; // need a meaningful window

      final transcript = recent
          .map((m) =>
              '${m.isUser ? "用户" : role.name}: ${m.content.replaceAll('\n', ' ')}')
          .join('\n');

      // Existing semantic memories the role might update (profile + own scope).
      // Episodic memories are events — not candidates for updates.
      final candidates = state
          .memoriesForRole(role.id)
          .where((m) => m.type == 'semantic')
          .toList()
        ..sort((a, b) => b.timestamp.compareTo(a.timestamp));
      final existingJson = candidates
          .take(40)
          .map((m) => {
                'id': m.id,
                'scope': m.roleId == null ? 'profile' : 'role',
                'content': m.content,
              })
          .toList();

      final prompt = '''你是用户记忆归纳助手。从下面的对话片段中提取关于用户的稳定事实。

已有可能相关的记忆（如有冲突，使用 op=update 替换；id 必须引用此处的 id）：
${jsonEncode(existingJson)}

输出 JSON 数组，每条：
{"op":"add"|"update","id":"oldId(仅 op=update)","scope":"profile|role","type":"semantic|episodic","content":"事实"}

规则：
- 性格、家庭、健康、姓名、过敏等通用画像 → scope=profile
- 仅与本角色领域相关 → scope=role
- 稳定特征 → semantic；具体事件 → episodic
- 与已有记忆冲突（如"喜欢咖啡"变"不喝咖啡"）→ op=update 引用旧 id
- 完全新增 → op=add
- 没有任何可归纳事实 → []
- 单条 content ≤30 字，不要捏造

角色：${role.name}（${role.description}）
对话：
$transcript''';

      try {
        final result = await service.chat([
          {'role': 'user', 'content': prompt},
        ], state.currentModel);
        final jsonStr = _extractJsonArray(result);
        if (jsonStr == null) {
          await prefs.setInt('summaryLastTs_${role.id}', recent.last.timestamp);
          continue;
        }
        final list = jsonDecode(jsonStr);
        if (list is! List) continue;
        _applyMemoryOps(list, role.id);
        await prefs.setInt('summaryLastTs_${role.id}', recent.last.timestamp);
      } catch (e) {
        debugPrint('summarize role ${role.id} failed: $e');
      }
    }
  }

  /// Apply add/update operations returned by the summarizer. Falls back to
  /// `add` if `op` is missing or `update` references an unknown id.
  void _applyMemoryOps(List<dynamic> ops, String roleId) {
    final byId = {for (final m in state.memories) m.id: m};
    final updated = <String, Memory>{};
    final added = <Memory>[];
    final now = DateTime.now().millisecondsSinceEpoch;

    for (final item in ops) {
      if (item is! Map) continue;
      final op = (item['op'] as String?) ?? 'add';
      final scope = item['scope'] as String?;
      final type = (item['type'] as String?) ?? 'semantic';
      final content = (item['content'] as String?)?.trim();
      if (content == null || content.isEmpty) continue;

      if (op == 'update') {
        final oldId = item['id'] as String?;
        final old = oldId == null ? null : byId[oldId];
        if (old != null) {
          updated[old.id] = old.copyWith(
            type: type,
            content: content,
            timestamp: now,
          );
          continue;
        }
        // Unknown id → treat as add
      }

      if (_memoryDuplicate(content, updated.values, added)) continue;
      added.add(Memory(
        id: _uuid.v4(),
        type: type,
        content: content,
        roleId: scope == 'profile' ? null : roleId,
        timestamp: now,
        tags: const [],
      ));
    }

    if (updated.isEmpty && added.isEmpty) return;
    final next = state.memories
        .map((m) => updated[m.id] ?? m)
        .toList()
      ..addAll(added);
    state = state.copyWith(memories: next);
    _saveState();
  }

  bool _memoryDuplicate(
    String content,
    Iterable<Memory> updated,
    Iterable<Memory> added,
  ) {
    final norm = content.trim();
    bool same(Memory m) => m.content.trim() == norm;
    return state.memories.any(same) || updated.any(same) || added.any(same);
  }
}
