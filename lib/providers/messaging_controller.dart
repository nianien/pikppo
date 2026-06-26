import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import '../models/group.dart';
import '../models/message.dart';
import '../services/agent.dart';
import '../services/mcp_service.dart';
import '../services/model_service.dart';
import '../utils/chart_cards.dart';
import '../utils/chat_history.dart';
import '../utils/time_format.dart';
import '../utils/tool_labels.dart';
import '../utils/user_facing_error.dart';
import 'app_state_provider.dart';
import 'location_service_provider.dart';
import 'mcp_service_provider.dart';

const _uuid = Uuid();

/// 私聊 + 群聊 + agent loop 的实现归属。原本是 AppStateNotifier 内的 400+ 行
/// 主链路；拆出来后 notifier 只负责持久化、状态变更、组件协调，messaging
/// 流程在这里集中实现。
///
/// 与 notifier 的关系：
/// - 读 state 通过 `_notifier.currentState` 直接拿快照
/// - 写 state 通过 notifier 暴露的 `appendXxx` / `setIdle` 等公共 API
/// - 服务（MCP、Location、Model service）通过 [Ref] 自取
class MessagingController {
  final AppStateNotifier _notifier;
  final Ref _ref;

  MessagingController(this._notifier, this._ref);

  /// agent loop 最多迭代轮数——避免模型在 tool_use/tool_result 之间无限打转。
  static const _kMaxAgentIterations = 10;

  /// 工具结果已被渲染成图表卡片时，附在该工具结果后喂回模型的提示——避免模型
  /// 把每日明细复述成 ASCII 表格（图已展示），只要一两句话结论。
  static const _kChartedToolHint =
      '[系统提示：以上数据已以图表卡片形式展示给用户。请勿复述每日明细或绘制表格；'
      '用一两句话总结要点即可——趋势方向、涨跌幅、区间高低、最新值。]';

  /// 走 agent 路径时附加到 system prompt 的工具使用纪律——时效性数据必须实时重查，
  /// 不能凭历史对话里的旧值作答（否则不调工具：既无图表卡片，数据也是陈旧的）。
  static const _kRealtimeToolDirective =
      '【工具使用纪律】涉及实时 / 时效性数据（汇率、股价、天气等），即使本次对话里'
      '已出现过相关数值，也必须调用对应工具重新获取最新数据后再作答；不要凭历史'
      '消息里的旧值或"刚查到的数据"直接回答。';

  /// 群聊角色逐个回复之间的间隔——纯节奏，避免瞬时刷屏。控制 0 = 无停顿。
  /// 当前由 [sendGroupMessage] 内逐角色 reply 后 await。后续要做"用户可配"
  /// 把它升到 settings 即可，注入点单一。
  static const _kGroupSpeakerPause = Duration(milliseconds: 300);

  // ---- Convenience accessors ----

  McpService get _mcp => _ref.read(mcpServiceProvider);

  // ---- Private chat ----

  Future<void> sendMessage(String content) async {
    _notifier.markActivity();
    // 触发后台定位刷新——下一条消息的 system prompt 拿到新鲜 fix。
    unawaited(_ref.read(locationServiceProvider).refresh());

    final userMsg = Message(
      id: _uuid.v4(),
      roleId: _notifier.currentState.currentRoleId,
      content: content,
      isUser: true,
      timestamp: DateTime.now().millisecondsSinceEpoch,
    );
    _notifier.appendUserMessage(userMsg);

    await _generateReply(roleId: _notifier.currentState.currentRoleId);
  }

  /// 重试：当前私聊尾部 error 气泡已由 notifier 抹掉并重新进入 loading，这里用
  /// 现有历史（末条仍是那条用户消息）重跑生成。
  Future<void> retryLastReply() =>
      _generateReply(roleId: _notifier.currentState.currentRoleId);

  // ---- Group chat ----

  Future<void> sendGroupMessage(String groupId, String content) async {
    _notifier.markActivity();
    unawaited(_ref.read(locationServiceProvider).refresh());

    final group = _notifier.currentState.getGroupById(groupId);
    if (group == null) return;

    final userMsg = Message(
      id: _uuid.v4(),
      roleId: '',
      content: content,
      isUser: true,
      timestamp: DateTime.now().millisecondsSinceEpoch,
      groupId: groupId,
    );
    _notifier.appendGroupUserMessage(userMsg, groupId);

    try {
      final service = _notifier.modelService();
      if (service == null) {
        _notifier.clearGroupLoading();
        return;
      }

      final mentioned = _parseMentions(content, group);
      final responding = mentioned.isNotEmpty
          ? mentioned
          : await _routeGroupMessage(content, group, service);

      for (final roleId in responding) {
        await _generateReply(roleId: roleId, group: group);
        // 让多角色回复有节奏感、避免瞬时刷屏；常量见 [_kGroupSpeakerPause]。
        await Future.delayed(_kGroupSpeakerPause);
      }
    } catch (e) {
      // 路由层失败（routing/service）——挂一条可重试的 error 气泡到首个成员。
      debugPrint('sendGroupMessage routing failed: ${debugReason(e)}');
      _notifier.appendGroupAiError(
          groupId, group.roleIds.first, userFacingError(e));
    }

    _notifier.clearGroupLoading();
  }

  /// 重试群聊里某条失败回复——error 气泡已由 notifier 抹掉并重进 loading，
  /// 这里只重跑该角色，其余成功回复不动。收尾清 loading。
  Future<void> retryGroupRoleReply(String groupId, String roleId) async {
    final group = _notifier.currentState.getGroupById(groupId);
    if (group != null) {
      await _generateReply(roleId: roleId, group: group);
    }
    _notifier.clearGroupLoading();
  }

  // ---- 统一生成链路（私聊 / 群聊每个角色共用）----

  /// 给会话里某个角色生成一条回复。私聊传 [group]=null，群聊传所在群。
  /// **不论私聊群聊，都按"模型有 tool 能力 + 有可用工具"决定走 agent loop**——
  /// 由模型自行决定要不要 emit tool_use；否则退化为纯 chat。失败统一落可重试
  /// 的 error 气泡。首发与重试共用——history 从 state 现取，天然带已有上下文。
  Future<void> _generateReply({required String roleId, Group? group}) async {
    final groupId = group?.id;
    try {
      if (_notifier.currentState.currentModel.isEmpty) {
        _abortQuietly(groupId);
        return;
      }
      final service = _notifier.modelService();
      if (service == null) {
        // 顶部常驻 InfoBanner 已提示"未配置模型 + 去设置"，不再灌气泡污染对话流。
        _abortQuietly(groupId);
        return;
      }
      final role = _notifier.currentState.getRoleById(roleId);
      if (role == null) {
        _abortQuietly(groupId);
        return;
      }

      final systemContent = await _notifier.buildSystemPrompt(
        role,
        roleId,
        groupSuffix: group == null ? null : _groupSuffix(group, roleId),
      );

      // agent loop 门槛：模型真有 tool 能力（Ollama 上 gemma3:4b 协议层支持但
      // 模型本身没 tool 能力）且至少一个可用工具（本地 or MCP）。满足就交给模型
      // 自行判断调不调；不满足退化纯 chat。
      var useTools = false;
      if (await service.modelSupportsTools(_notifier.currentState.currentModel)) {
        final mcpToolsAvailable = _mcp.isConnected
            ? (await _mcp.ensureTools()).isNotEmpty
            : false;
        useTools = mcpToolsAvailable || _notifier.localTools.isNotEmpty;
      }

      final turns = _historyTurns(roleId: roleId, group: group);

      if (useTools) {
        await _runAgentLoop(
          service: service,
          // 附"时效数据必须重查"指令——否则模型常凭历史对话里的旧汇率/价格直接
          // 作答（不调工具 → 既无图、数据又陈旧）。
          systemContent: '$systemContent\n\n$_kRealtimeToolDirective',
          messages: <Map<String, dynamic>>[...turns],
          onFinal: (t, charts) => _appendFinal(groupId, roleId, t, charts),
          onError: (t) => _appendError(groupId, roleId, t),
        );
      } else {
        final messages = <Map<String, String>>[
          {'role': 'system', 'content': systemContent},
          ...turns,
        ];
        final reply =
            await service.chat(messages, _notifier.currentState.currentModel);
        _appendFinal(groupId, roleId, reply);
      }
    } catch (e) {
      debugPrint('generateReply failed: ${debugReason(e)}');
      _appendError(groupId, roleId, userFacingError(e));
    }
  }

  /// 把持久化历史翻译成模型期望的 user/assistant 轮次（不含 system）。只保留
  /// chat 类型，tool_status / reminder / error 都是 UI-only。群聊里 assistant
  /// 轮带 `[角色名]:` 前缀，让每个角色看得出谁说的；私聊不加前缀。最末一条 user
  /// 注入显式日期提示（见 [_formatUserContentForLlm]）。
  List<Map<String, String>> _historyTurns(
      {required String roleId, Group? group}) {
    final source = group == null
        ? _notifier.currentState.currentRoleMessages
        : _notifier.getGroupMessagesList(group.id);
    final history =
        recentChatHistory(source.where((m) => m.kind == 'chat').toList());
    final lastUserIdx = indexOfLastUser(history);
    return [
      for (var i = 0; i < history.length; i++)
        if (history[i].isUser)
          {
            'role': 'user',
            'content': i == lastUserIdx
                ? _formatUserContentForLlm(history[i])
                : history[i].content,
          }
        else if (group == null)
          {'role': 'assistant', 'content': history[i].content}
        else
          {
            'role': 'assistant',
            'content':
                '[${_notifier.currentState.getRoleById(history[i].roleId)?.name ?? history[i].roleId}]: ${history[i].content}',
          },
    ];
  }

  String _groupSuffix(Group group, String roleId) {
    final otherNames = group.roleIds
        .where((id) => id != roleId)
        .map((id) => _notifier.currentState.getRoleById(id)?.name ?? id)
        .join('、');
    return '\n\n你正在群聊"${group.name}"中。其他成员：$otherNames。'
        '请基于自身能力简洁回复，不要重复其他成员已经说过的内容。';
  }

  // 三个 append 路由：私聊 / 群聊落到各自的 notifier API。
  // [charts] 非空时挂到这条消息上同气泡渲染（图在上、文字在下）。
  void _appendFinal(String? groupId, String roleId, String text,
      [List<String> charts = const []]) {
    final cards = charts.isEmpty ? null : charts;
    if (groupId == null) {
      _notifier.appendAiMessage(text, charts: cards);
    } else {
      _notifier.appendGroupAiMessage(groupId, roleId, text, charts: cards);
    }
  }

  void _appendError(String? groupId, String roleId, String text) {
    if (groupId == null) {
      _notifier.appendAiError(text);
    } else {
      _notifier.appendGroupAiError(groupId, roleId, text);
    }
  }

  /// 静默收尾（模型未配 / service 空 / 角色缺失）：私聊退出 loading；群聊不动，
  /// 交给外层 [sendGroupMessage] / [retryGroupRoleReply] 的 clearGroupLoading。
  void _abortQuietly(String? groupId) {
    if (groupId == null) _notifier.setIdle();
  }

  /// 取某工具名对应的 MCP `title`（本地工具不在 MCP 目录里，返回 null）。
  String? _mcpTitleFor(String name) {
    for (final t in _mcp.tools) {
      if (t.name == name) return t.title;
    }
    return null;
  }

  // ---- Agent loop（会话无关，通过回调把回复落到对应 scope）----

  Future<void> _runAgentLoop({
    required ModelService service,
    required String systemContent,
    required List<Map<String, dynamic>> messages,
    required void Function(String text, List<String> charts) onFinal,
    required void Function(String text) onError,
  }) async {
    // 合并本地与 MCP 工具一并暴露给模型。同名时本地胜出（同时 MCP 端去重）。
    final localTools = _notifier.localTools;
    final mcpDefs = _mcp.tools
        .where((t) => !localTools.has(t.name))
        .map((t) => ToolDefinition(
              name: t.name,
              description: t.description,
              inputSchema: t.inputSchema,
            ))
        .toList();
    final tools = <ToolDefinition>[
      ...localTools.definitions(),
      ...mcpDefs,
    ];

    // 工具产出的图表卡片**先缓存**，本轮出最终文字时随 onFinal 一起挂到**同一条
    // 消息**上（图在上、文字在下、一个气泡一个头像），而非另起一条卡片消息。
    final pendingCards = <String>[];

    AgentStep step;
    try {
      step = await service.agentStart(
        system: systemContent,
        messages: messages,
        model: _notifier.currentState.currentModel,
        tools: tools,
      );
    } catch (e) {
      debugPrint('agent start failed: ${debugReason(e)}');
      onError(userFacingError(e));
      return;
    }

    var iterations = 0;
    while (step is AgentToolRequest) {
      if (++iterations > _kMaxAgentIterations) {
        onFinal('（已达到工具调用上限，停止后续推理）', pendingCards);
        return;
      }

      // 不展示模型调工具前的开场白（step.text，如"我来查一下…"）——纯报幕、与
      // "思考中/正在调用工具"提示重复，且会让一次问答多冒一个气泡。最终答案在
      // 工具跑完后的 onFinal 里。

      // 工具执行期间的瞬时提示"正在调用工具：<中文名>"——纯 UI 过渡态，不落库、
      // 不进 LLM 历史。展示名优先本地映射，缺失回退 MCP 工具的 title（见
      // [toolDisplayName]）；本地工具不在 _mcp.tools 里，title 为 null。
      final toolNames = step.calls
          .map((c) => toolDisplayName(c.name, fallbackTitle: _mcpTitleFor(c.name)))
          .join('、');
      _notifier.setToolStatus('正在调用工具：$toolNames');

      // 按顺序执行 tool；本地优先，未命中走 MCP。
      final results = <ToolResult>[];
      for (final call in step.calls) {
        try {
          final raw = localTools.has(call.name)
              ? await localTools.call(call.name, call.input)
              : await _mcp.callTool(call.name, call.input);
          // 可视化工具：生成图表卡片但**先缓存**，终点和文字一起落（见 flushCards）。
          // 非可视化 / 数据不足时返回 null，不挂卡。
          final card = buildChartCardContent(call.name, call.input, raw);
          if (card != null) {
            pendingCards.add(card);
            // 已图表化——结果后附提示，引导模型简短总结而非复述/画表。
            results.add(ToolResult(
                toolUseId: call.id, content: '$raw\n\n$_kChartedToolHint'));
          } else {
            results.add(ToolResult(toolUseId: call.id, content: raw));
          }
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
      // 工具跑完，回到模型推理——清掉工具提示，ThinkingBubble 恢复普通"思考中"。
      _notifier.setToolStatus(null);

      // 日历工具走本地 Repository，drift watch 自动通知 UI，无需手动 refresh。

      messages.add(step.assistantMessage);
      messages.addAll(service.buildToolResultMessages(results));

      try {
        step = await service.agentContinue(
          system: systemContent,
          messages: messages,
          model: _notifier.currentState.currentModel,
          tools: tools,
        );
      } catch (e) {
        debugPrint('agent continue failed: ${debugReason(e)}');
        // 续推失败 → error 气泡可重试；图丢弃（重试会重查重画），避免把图挂到
        // error 上的别扭形态。
        onError(userFacingError(e));
        return;
      }
    }

    if (step is AgentDone) {
      // 图表随最终文字挂到同一条消息上（pendingCards 可能为空 = 普通文字回复）。
      onFinal(step.text, pendingCards);
    }
  }

  List<String> _parseMentions(String content, Group group) {
    final mentioned = <String>[];
    for (final roleId in group.roleIds) {
      final role = _notifier.currentState.getRoleById(roleId);
      if (role == null) continue;
      if (content.contains('@${role.name}') ||
          content.contains('＠${role.name}')) {
        mentioned.add(roleId);
      }
    }
    return mentioned;
  }

  /// 让 LLM 判断 [content] 跟群里哪些角色相关；失败 / 空回退到第一个角色。
  Future<List<String>> _routeGroupMessage(
      String content, Group group, ModelService service) async {
    if (group.roleIds.length <= 1) return group.roleIds;
    try {
      final roleLines = group.roleIds.map((id) {
        final r = _notifier.currentState.getRoleById(id);
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
      ], _notifier.currentState.currentModel);
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

  // ---- Helpers ----

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
}
