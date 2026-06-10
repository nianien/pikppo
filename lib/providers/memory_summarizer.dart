import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import '../db/mappers.dart';
import '../models/memory.dart';
import '../services/model_service.dart';
import '../utils/user_facing_error.dart';
import 'app_state_provider.dart';
import 'database_provider.dart';
import 'model_service_provider.dart';

const _uuid = Uuid();

/// 背景任务：定时把对话片段归纳成长期记忆。
///
/// - **触发**：周期 timer + 用户闲置阈值；显式 [runNow] 绕过空闲检查（设置页"立即归纳"）。
/// - **解耦**：组件只依赖 [Ref]，从 [appStateProvider]/[modelServiceProvider] 读现状，
///   通过 [AppStateNotifier.applyMemoryDiff] 提交变更——不直接 set state。
class MemorySummarizer {
  final Ref _ref;
  final Duration interval;
  final Duration idleThreshold;

  Timer? _timer;
  bool _running = false;
  DateTime _lastUserActivity = DateTime.now();

  MemorySummarizer(
    this._ref, {
    required this.interval,
    required this.idleThreshold,
  });

  void start() {
    _timer?.cancel();
    _timer = Timer.periodic(interval, (_) => _maybeRun(forceIdle: false));
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// 用户操作时刷新心跳——闲置阈值的"闲置"从最后一次活动起算。
  void markActivity() => _lastUserActivity = DateTime.now();

  /// 立即归纳一次，跳过空闲检查。
  Future<void> runNow() => _maybeRun(forceIdle: true);

  Future<void> _maybeRun({required bool forceIdle}) async {
    if (_running) return;
    if (!forceIdle) {
      final idle = DateTime.now().difference(_lastUserActivity);
      if (idle < idleThreshold) return;
    }
    _running = true;
    try {
      final service = _ref.read(modelServiceProvider);
      if (service == null) return;
      await _summarizeAllRoles(service);
    } catch (e) {
      debugPrint('memory summary failed: ${debugReason(e)}');
    } finally {
      _running = false;
    }
  }

  Future<void> _summarizeAllRoles(ModelService service) async {
    final prefs = await SharedPreferences.getInstance();
    final state = _ref.read(appStateProvider);
    final model = state.currentModel;
    // 直查 db——不依赖内存 state.messages（懒加载后未必包含所有 role）。
    final db = await _ref.read(databaseProvider.future);
    for (final role in state.roles) {
      final lastTs = prefs.getInt('summaryLastTs_${role.id}') ?? 0;
      final rows = await db.messagesForRole(role.id);
      final recent = rows
          .where((m) => m.kind == 'chat' && m.timestamp > lastTs)
          .map(messageFromRow)
          .toList()
        ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
      if (recent.length < 4) continue; // need a meaningful window

      final transcript = recent
          .map((m) =>
              '${m.isUser ? "用户" : role.name}: ${m.content.replaceAll('\n', ' ')}')
          .join('\n');

      // 现有 semantic 记忆——给模型作为可 update 的候选；episodic 不作 update 目标。
      final candidates = _ref
          .read(appStateProvider)
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

      final prompt = _buildPrompt(role.name, role.description, existingJson,
          transcript);

      try {
        final result = await service.chat([
          {'role': 'user', 'content': prompt},
        ], model);
        final jsonStr = _extractJsonArray(result);
        if (jsonStr == null) {
          await prefs.setInt('summaryLastTs_${role.id}', recent.last.timestamp);
          continue;
        }
        final list = jsonDecode(jsonStr);
        if (list is! List) continue;
        final diff = _computeDiff(list, role.id);
        if (diff.updated.isNotEmpty || diff.added.isNotEmpty) {
          _ref.read(appStateProvider.notifier).applyMemoryDiff(
                updated: diff.updated,
                added: diff.added,
              );
        }
        await prefs.setInt('summaryLastTs_${role.id}', recent.last.timestamp);
      } catch (e) {
        debugPrint(
            'summarize role ${role.id} failed: ${debugReason(e)}');
      }
    }
  }

  static String _buildPrompt(
    String roleName,
    String roleDescription,
    List<Map<String, dynamic>> existing,
    String transcript,
  ) =>
      '''你是用户记忆归纳助手。从下面的对话片段中提取关于用户的稳定事实。

已有可能相关的记忆（如有冲突，使用 op=update 替换；id 必须引用此处的 id）：
${jsonEncode(existing)}

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

角色：$roleName（$roleDescription）
对话：
$transcript''';

  _MemoryDiff _computeDiff(List<dynamic> ops, String roleId) {
    final existingMemories = _ref.read(appStateProvider).memories;
    final byId = {for (final m in existingMemories) m.id: m};
    final updated = <String, Memory>{};
    final added = <Memory>[];
    final now = DateTime.now().millisecondsSinceEpoch;

    bool isDuplicate(String content) {
      final norm = content.trim();
      bool same(Memory m) => m.content.trim() == norm;
      return existingMemories.any(same) ||
          updated.values.any(same) ||
          added.any(same);
    }

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
        // 未知 id → 按 add 处理
      }

      if (isDuplicate(content)) continue;
      added.add(Memory(
        id: _uuid.v4(),
        type: type,
        content: content,
        roleId: scope == 'profile' ? null : roleId,
        timestamp: now,
        tags: const [],
      ));
    }

    return _MemoryDiff(updated: updated, added: added);
  }

  /// 取出第一个完整 JSON 数组，容忍模型在 `[...]` 外面包码块或解释文字。
  static String? _extractJsonArray(String text) {
    final start = text.indexOf('[');
    if (start == -1) return null;
    final end = text.lastIndexOf(']');
    if (end <= start) return null;
    return text.substring(start, end + 1);
  }
}

class _MemoryDiff {
  final Map<String, Memory> updated;
  final List<Memory> added;
  _MemoryDiff({required this.updated, required this.added});
}
