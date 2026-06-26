import 'package:flutter/services.dart' show rootBundle;
import 'package:yaml/yaml.dart';
import '../models/role.dart';

/// 预置角色的稳定 id 序——顺序即 UI 展示顺序，也决定 ReminderRouter 兜底优先级
/// （work 排第一与 [ReminderRouter.defaultRoleId] 默认一致）。
///
/// **不要在中间插入新 id 调整老用户的角色顺序**——id 是 S3 脊柱，序列对应消息/
/// 记忆的角色归属；改 id = 改用户数据归属。新增角色追加到末尾。
const _kPresetRoleIds = ['work', 'life', 'finance', 'health'];

/// 启动期一次性加载。
///
/// 失败行为：单文件解析失败 → 跳过该角色，记日志，不阻塞其他角色加载；全部
/// 失败 → 返回空列表，由调用方决定降级策略（首启 onboarding 阻塞 / 设置页提
/// 示等）。
///
/// 为什么不缓存：本函数被 [AppStateNotifier._loadState] 调一次；角色列表落到
/// state 后 UI 直接消费内存中的拷贝，不会反复调本函数。
Future<List<Role>> loadDefaultRoles() async {
  final results = <Role>[];
  for (final id in _kPresetRoleIds) {
    try {
      final raw = await rootBundle.loadString('assets/roles/$id.yaml');
      final doc = loadYaml(raw);
      if (doc is! YamlMap) {
        throw FormatException(
            'assets/roles/$id.yaml: top-level must be a YAML map');
      }
      final role = _parseRole(doc, expectedId: id);
      results.add(role);
    } catch (e) {
      // ignore: avoid_print
      print('[role_loader] skip $id: $e');
    }
  }
  return results;
}

/// [expectedId] 用于校验"文件名 id 等于 yaml id 字段"——避免改文件名忘改 id
/// 这类常见错误悄悄通过。
Role _parseRole(YamlMap doc, {required String expectedId}) {
  String require(String key) {
    final v = doc[key];
    if (v is! String || v.isEmpty) {
      throw FormatException(
          'assets/roles/$expectedId.yaml: field "$key" required and must be non-empty string');
    }
    return v;
  }

  final id = require('id');
  if (id != expectedId) {
    throw FormatException(
        'assets/roles/$expectedId.yaml: id "$id" does not match filename');
  }
  return Role(
    id: id,
    name: require('name'),
    icon: require('icon'),
    description: require('description'),
    color: require('color'),
    systemPrompt: require('systemPrompt').trim(),
  );
}
