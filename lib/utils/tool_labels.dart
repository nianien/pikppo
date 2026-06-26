/// 工具接口名 → 给用户看的中文名。Agent loop 执行工具时的瞬时提示
/// （"正在调用工具：xxx"）用它，把 `calendar_list_events` 这类接口名翻成
/// "查询日程"。未收录的名字回退到原始接口名，保证不丢信息。
const _toolLabels = <String, String>{
  // 本地日历工具（lib/services/tools/calendar_tools.dart）
  'calendar_list_events': '查询日程',
  'calendar_create_event': '创建日程',
  'calendar_update_event': '修改日程',
  'calendar_delete_event': '删除日程',
  // MCP 汇率工具（pikppo-mcp）
  'convert_currency': '货币换算',
  'get_exchange_rate': '查询汇率',
  'get_exchange_trend': '汇率走势',
  'list_exchange_rates': '汇率列表',
};

/// 工具展示名：**优先本地映射**（最可控的中文名），缺失时回退 MCP 工具的
/// `title`（[fallbackTitle]，服务端写了就能直接用），再缺退回原始接口名。
String toolDisplayName(String toolName, {String? fallbackTitle}) {
  final mapped = _toolLabels[toolName];
  if (mapped != null) return mapped;
  final title = fallbackTitle?.trim();
  if (title != null && title.isNotEmpty) return title;
  return toolName;
}
