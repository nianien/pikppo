import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import '../models/calendar_event.dart';
import '../models/role.dart';
import '../utils/user_facing_error.dart';
import 'model_service.dart';

/// 提醒路由——按 data-architecture v3.2 §4「提醒路由（单角色）」契约实现。
///
/// 决定一条事件类提醒（日历事件、未来的邮件/IM 抽取等）归属哪个角色。
/// **单角色归属**：一条事件只归一个角色私聊 + 一条系统通知，避免锁屏刷屏；
/// 由 Repository 在写入事件时调本路由器，结果 cache 到 `routedRoleId` 列上，
/// OS 通知预调度才能在 App 被杀场景下投递到正确角色。
///
/// 路由分两段：
/// 1. **规则 prefilter**：关键词匹配命中即返回；多角色都命中时按预置角色优先级
///    取一（work > finance > health > life）——产品级的"主导项"判断
/// 2. **LLM 兜底**：规则未命中走小模型判断
/// 兜底失败（无 service、超时、解析错）→ 退到 [defaultRoleId]
///
/// 严格端上：事件内容与角色清单不出设备；零知识相容。
class ReminderRouter {
  /// LLM 兜底的最长等待时间——超时退到默认角色，不阻塞事件写入。
  static const _kLlmTimeout = Duration(seconds: 8);

  /// 预置角色优先级——多关键词命中时取最靠前的。理由：
  /// - work：最常见提醒场景（会议、deadline），承担默认兜底角色
  /// - finance：金额相关歧义少，命中即归属
  /// - health：身体相关，与生活有边界但更专属
  /// - life：兜底域；与上述任何域并存时让位
  static const _kPriority = ['work', 'finance', 'health', 'life'];

  /// 内置关键词词典——按角色 id 索引，命中即归属。预置角色覆盖 80% 日常事件；
  /// 自定义角色未列入词典时走 LLM 路径，准确率由 LLM 保证。
  static const Map<String, List<String>> _keywordRules = {
    'work': [
      '会议', '周会', '汇报', 'review', '面试', '客户', '提案',
      '同事', '项目', '排期', 'OKR', 'KPI', '述职', '考核',
      '邮件', 'mail', 'email', '老板', '总监', '主管',
      'PRD', '需求', '上线', 'release', 'deploy',
    ],
    'life': [
      '聚餐', '约饭', '吃饭', '咖啡', '电影', '逛街',
      '快递', '取件', '车检', '加油', '理发', '美容',
      '搬家', '装修', '生日', '纪念日', '婚礼', '聚会',
      '同学', '朋友', '家人',
    ],
    'finance': [
      '还款', '账单', '信用卡', '工资', '发薪', '房租', '物业',
      '水电', '燃气', '保费', '理财', '基金', '股票',
      '报税', '退税', '社保', '公积金', '转账', '预算',
    ],
    'health': [
      '体检', '医院', '看病', '挂号', '复查', '吃药', '服药',
      '健身', '跑步', '游泳', '瑜伽', '血压', '血糖', '睡眠',
      '冥想', '疫苗', '牙医', '眼睛',
    ],
  };

  /// 兜底角色 id——所有路径都失败时让提醒至少触达。默认职场助理（最容易出现
  /// 时间敏感事件）。Phase 2 后可让用户在设置里改。
  final String defaultRoleId;

  ReminderRouter({this.defaultRoleId = 'work'});

  /// 按事件 [event] 与可见角色 [candidates] 路由到单一目标角色 id。
  ///
  /// [llmService] / [llmModel] 任一为空 → 跳过 LLM，规则未命中即兜底。
  /// 返回的 id 一定是 [candidates] 中某个的 id（或 [defaultRoleId] 兜底）。
  Future<String> route({
    required CalendarEvent event,
    required List<Role> candidates,
    ModelService? llmService,
    String? llmModel,
  }) async {
    if (candidates.isEmpty) return defaultRoleId;

    final candidateIds = candidates.map((r) => r.id).toSet();
    final fallback = _pickFallback(candidateIds);

    // 阶段一：关键词 prefilter——命中按优先级取主导项。
    final ruleHit = _keywordPick(event, candidateIds);
    if (ruleHit != null) {
      return ruleHit;
    }

    // 阶段二：LLM 兜底。
    if (llmService == null || llmModel == null || llmModel.isEmpty) {
      return fallback;
    }
    try {
      final picked = await _llmRoute(event, candidates, llmService, llmModel)
          .timeout(_kLlmTimeout);
      if (picked != null && candidateIds.contains(picked)) return picked;
    } on TimeoutException {
      debugPrint('reminder router LLM timeout, fallback');
    } catch (e) {
      debugPrint('reminder router LLM failed: ${debugReason(e)}');
    }
    return fallback;
  }

  // ---- 阶段一：规则 ----

  /// 多角色都命中时，按 [_kPriority] 取最靠前的；预置角色之外（如自定义角色）
  /// 没有词典条目，自然不参与规则阶段。
  String? _keywordPick(CalendarEvent event, Set<String> candidateIds) {
    final haystack = '${event.title} ${event.description}'.toLowerCase();
    final hits = <String>{};
    _keywordRules.forEach((roleId, words) {
      if (!candidateIds.contains(roleId)) return;
      for (final w in words) {
        if (haystack.contains(w.toLowerCase())) {
          hits.add(roleId);
          break;
        }
      }
    });
    if (hits.isEmpty) return null;
    for (final p in _kPriority) {
      if (hits.contains(p)) return p;
    }
    return hits.first;
  }

  /// 兜底角色选择：优先 [defaultRoleId]，不在候选集时退到第一个候选。
  String _pickFallback(Set<String> candidateIds) {
    if (candidateIds.contains(defaultRoleId)) return defaultRoleId;
    return candidateIds.first;
  }

  // ---- 阶段二：LLM ----

  Future<String?> _llmRoute(
    CalendarEvent event,
    List<Role> candidates,
    ModelService service,
    String model,
  ) async {
    final candidateLines = candidates
        .map((r) => '- ${r.id}: ${r.name}（${r.description}）')
        .join('\n');
    final time = event.localTimeLabel ?? '全天';
    final desc = event.description.isEmpty ? '(无)' : event.description;
    final prompt =
        '''你是助理团队的调度员。下面这条日程提醒应该由哪个角色发出？
返回单一角色 id 的 JSON 字符串（如 "work"），不要其他文字。
事件可能跨域时取主导项（如"家庭聚餐时谈年终奖"主导是 work）。
无明确归属时返回 ""。

可选角色：
$candidateLines

日程：
标题：${event.title}
时间：$time
备注：$desc''';

    final result = await service.chat([
      {'role': 'user', 'content': prompt},
    ], model);
    return _parseSingleId(result);
  }

  /// 容错解析：模型可能返回 `"work"` / `work` / `{"role":"work"}` 等多种形态。
  /// 取出现的第一个非空字符串 id。
  static String? _parseSingleId(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return null;
    // 优先尝试 JSON 解析
    try {
      final decoded = jsonDecode(trimmed);
      if (decoded is String && decoded.isNotEmpty) return decoded;
      if (decoded is Map) {
        for (final v in decoded.values) {
          if (v is String && v.isNotEmpty) return v;
        }
      }
      if (decoded is List) {
        for (final v in decoded) {
          if (v is String && v.isNotEmpty) return v;
        }
      }
    } catch (_) {/* fall through */}
    // 兜底：取第一个英文/数字标识符
    final match = RegExp(r'[a-zA-Z_][a-zA-Z0-9_]*').firstMatch(trimmed);
    return match?.group(0);
  }
}
