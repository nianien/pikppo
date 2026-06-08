import 'agent.dart';

/// 进程内工具：在 Flutter 端直接执行，不经过 MCP/网络。
/// 适用场景：操作本地数据（记忆、状态）或纯计算工具——延迟低、离线可用、无
/// 需 MCP 连接，跟 [McpService] 暴露的远程工具并存。
class LocalTool {
  final String name;
  final String description;
  final Map<String, dynamic> inputSchema;
  final Future<String> Function(Map<String, dynamic> input) handler;

  const LocalTool({
    required this.name,
    required this.description,
    required this.inputSchema,
    required this.handler,
  });

  ToolDefinition toDefinition() => ToolDefinition(
        name: name,
        description: description,
        inputSchema: inputSchema,
      );
}

/// Agent loop 在 dispatch 一次 tool_use 时先查这里，命中走 [call] 本地执行，
/// 否则才回退到 MCP。
///
/// 命名规则：本地胜出，注册时若与已有 MCP 工具同名，由调用方决定提示策略（这
/// 里只负责本地表，不感知 MCP）。建议本地工具命名上避开 MCP 命名空间，比如统
/// 一前缀 `local_` 或具体到操作 `note_add` / `time_now`。
class ToolRegistry {
  final Map<String, LocalTool> _byName;

  ToolRegistry(List<LocalTool> tools)
      : _byName = {for (final t in tools) t.name: t};

  bool has(String name) => _byName.containsKey(name);

  bool get isNotEmpty => _byName.isNotEmpty;

  List<ToolDefinition> definitions() =>
      _byName.values.map((t) => t.toDefinition()).toList();

  /// 执行本地工具。未注册时抛 [ArgumentError]；调用方应该先用 [has] 判定。
  Future<String> call(String name, Map<String, dynamic> input) {
    final tool = _byName[name];
    if (tool == null) {
      throw ArgumentError('local tool not registered: $name');
    }
    return tool.handler(input);
  }
}
