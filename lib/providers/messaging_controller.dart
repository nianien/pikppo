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
import '../utils/chat_history.dart';
import '../utils/time_format.dart';
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
/// - 读 state 通过 `_ref.read(appStateProvider)` 直接拿快照
/// - 写 state 通过 notifier 暴露的 `appendXxx` / `setIdle` 等公共 API
/// - 服务（MCP、Location、Model service）通过 [Ref] 自取
class MessagingController {
  final AppStateNotifier _notifier;
  final Ref _ref;

  MessagingController(this._notifier, this._ref);

  /// agent loop 最多迭代轮数——避免模型在 tool_use/tool_result 之间无限打转。
  static const _kMaxAgentIterations = 10;

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
      roleId: _ref.read(appStateProvider).currentRoleId,
      content: content,
      isUser: true,
      timestamp: DateTime.now().millisecondsSinceEpoch,
    );
    _notifier.appendUserMessage(userMsg);

    try {
      if (_ref.read(appStateProvider).currentModel.isEmpty) {
        _notifier.setIdle();
        return;
      }
      final service = _notifier.modelService();
      if (service == null) {
        _notifier.appendAiMessage('请先在设置中配置模型服务');
        return;
      }

      final role = _ref.read(appStateProvider).currentRole;
      final systemContent =
          await _notifier.buildSystemPrompt(role, _ref.read(appStateProvider).currentRoleId);

      // Agentic 路径：当前所选模型必须真有 tool 能力（Ollama 上 gemma3:4b 协议
      // 层支持但模型本身没 tool 能力，不能进 agent loop），且至少有一个可用
      // 工具（本地 or MCP）。
      if (await service.modelSupportsTools(_ref.read(appStateProvider).currentModel)) {
        final mcpToolsAvailable = _mcp.isConnected
            ? (await _mcp.ensureTools()).isNotEmpty
            : false;
        if (mcpToolsAvailable || _notifier.localTools.isNotEmpty) {
          await _runAgentLoop(
            service: service,
            systemContent: systemContent,
          );
          return;
        }
      }

      // 非 agent 路径：纯对话回复。日程/提醒抽取走 agent loop（模型自主 emit
      // tool_use 调 MCP）；本路径仅服务 tool 能力缺失的模型。
      final history = recentChatHistory(
        _ref.read(appStateProvider).currentRoleMessages
            .where((m) => m.kind == 'chat')
            .toList(),
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

      final reply = await service.chat(messages, _ref.read(appStateProvider).currentModel);
      _notifier.appendAiMessage(reply);
    } catch (e) {
      debugPrint('sendMessage failed: ${debugReason(e)}');
      _notifier.appendAiMessage(userFacingError(e));
    }
  }

  // ---- Agent loop ----

  Future<void> _runAgentLoop({
    required ModelService service,
    required String systemContent,
  }) async {
    // 把持久化历史翻译成 Anthropic 期望的结构化格式——当前用户消息是末尾，
    // 早期回合都是纯文本气泡所以用 string content。只保留 chat 类型消息，
    // tool_status / reminder 是 UI-only。
    final history = recentChatHistory(
      _ref.read(appStateProvider).currentRoleMessages
          .where((m) => m.kind == 'chat')
          .toList(),
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
      // 最新 user message 已经在 history 里（sendMessage 调本方法前 append 过），不重复。
    ];

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

    AgentStep step;
    try {
      step = await service.agentStart(
        system: systemContent,
        messages: messages,
        model: _ref.read(appStateProvider).currentModel,
        tools: tools,
      );
    } catch (e) {
      debugPrint('agent start failed: ${debugReason(e)}');
      _notifier.appendAiMessage(userFacingError(e));
      return;
    }

    var iterations = 0;
    while (step is AgentToolRequest) {
      if (++iterations > _kMaxAgentIterations) {
        _notifier.appendAiMessage('（已达到工具调用上限，停止后续推理）');
        return;
      }

      final preamble = step.text?.trim();
      if (preamble != null && preamble.isNotEmpty) {
        _notifier.appendAiStreamPart(preamble);
      }

      // 每个工具一条"🔧 调用 X"状态气泡——UI 透明，tool_status 类型不进 LLM 历史。
      for (final call in step.calls) {
        _notifier.appendAiStreamPart('🔧 调用工具：${call.name}',
            kind: 'tool_status');
      }

      // 按顺序执行 tool；本地优先，未命中走 MCP。
      final results = <ToolResult>[];
      for (final call in step.calls) {
        try {
          final raw = localTools.has(call.name)
              ? await localTools.call(call.name, call.input)
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

      // 日历类工具可能改了远端状态，机会性刷新缓存。
      if (step.calls.any((c) => c.name.contains('calendar'))) {
        unawaited(_notifier.refreshCalendarCache());
      }

      messages.add(step.assistantMessage);
      messages.addAll(service.buildToolResultMessages(results));

      try {
        step = await service.agentContinue(
          system: systemContent,
          messages: messages,
          model: _ref.read(appStateProvider).currentModel,
          tools: tools,
        );
      } catch (e) {
        debugPrint('agent continue failed: ${debugReason(e)}');
        _notifier.appendAiMessage(userFacingError(e));
        return;
      }
    }

    if (step is AgentDone) {
      _notifier.appendAiMessage(step.text);
    }
  }

  // ---- Group chat ----

  Future<void> sendGroupMessage(String groupId, String content) async {
    _notifier.markActivity();
    unawaited(_ref.read(locationServiceProvider).refresh());

    final group = _ref.read(appStateProvider).getGroupById(groupId);
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
        final role = _ref.read(appStateProvider).getRoleById(roleId);
        if (role == null) continue;

        final otherNames = group.roleIds
            .where((id) => id != roleId)
            .map((id) => _ref.read(appStateProvider).getRoleById(id)?.name ?? id)
            .join('、');
        final systemPrompt = await _notifier.buildSystemPrompt(
          role,
          roleId,
          groupSuffix: '\n\n你正在群聊"${group.name}"中。其他成员：$otherNames。'
              '请基于自身能力简洁回复，不要重复其他成员已经说过的内容。',
        );

        final history = recentChatHistory(
          _notifier
              .getGroupMessagesList(groupId)
              .where((m) => m.kind == 'chat')
              .toList(),
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
                    '[${_ref.read(appStateProvider).getRoleById(history[i].roleId)?.name ?? history[i].roleId}]: ${history[i].content}',
              },
        ];

        final reply =
            await service.chat(messages, _ref.read(appStateProvider).currentModel);
        _notifier.appendGroupAiMessage(groupId, roleId, reply);
        // 让多角色回复有节奏感、避免瞬时刷屏；常量见 [_kGroupSpeakerPause]。
        await Future.delayed(_kGroupSpeakerPause);
      }
    } catch (e) {
      debugPrint('sendGroupMessage failed: ${debugReason(e)}');
      _notifier.appendGroupAiMessage(
          groupId, group.roleIds.first, userFacingError(e));
    }

    _notifier.clearGroupLoading();
  }

  List<String> _parseMentions(String content, Group group) {
    final mentioned = <String>[];
    for (final roleId in group.roleIds) {
      final role = _ref.read(appStateProvider).getRoleById(roleId);
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
        final r = _ref.read(appStateProvider).getRoleById(id);
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
      ], _ref.read(appStateProvider).currentModel);
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
