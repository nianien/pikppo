import 'dart:convert';

/// 聊天图表卡片框架——把"工具结果"映射成可在对话气泡里渲染的卡片。
///
/// 设计：agent loop 执行到**可视化工具**时，除了把结果喂回模型，再额外挂一条
/// `kind:'chart'` 的消息，content 为 `{type, data}` 的 JSON 串。渲染端
/// （`message_bubble.dart` 的 `_ChartCard`）按 `type` 选对应 widget。
/// 扩展新图表：这里加一行映射 + 数据构造，渲染端加一个 widget 分支即可。

/// 把若干张卡片（每张是 `{type,data}` 的 JSON 串）打包成消息 `chartData` 列的值
/// （JSON 数组串）。空 → null（普通消息）。每张已是合法 JSON 对象，直接拼数组。
String? encodeChartData(List<String>? cards) {
  if (cards == null || cards.isEmpty) return null;
  return '[${cards.join(',')}]';
}

/// 工具名 → 卡片类型；不可视化的工具返回 null。
String? chartCardTypeForTool(String toolName) {
  switch (toolName) {
    case 'get_exchange_trend':
      return 'exchange_trend';
    default:
      return null;
  }
}

/// 用工具调用入参 [input] + 原始 JSON 结果 [rawResult] 构造卡片消息 content
/// （`{type, data}` 的 JSON 串）。非可视化工具 / 解析失败 / 数据不足以成图时返回
/// null（此时不挂卡片，只保留模型文字回复）。
String? buildChartCardContent(
    String toolName, Map<String, dynamic> input, String rawResult) {
  final type = chartCardTypeForTool(toolName);
  if (type == null) return null;
  try {
    final decoded = jsonDecode(rawResult);
    if (decoded is! Map) return null;
    final data = <String, dynamic>{...decoded.cast<String, dynamic>()};
    switch (type) {
      case 'exchange_trend':
        // 币种对来自调用入参（结果里通常不带），合并进卡片数据。
        data['from'] = input['from_currency'];
        data['to'] = input['to_currency'];
        final points = data['points'];
        if (points is! List || points.length < 2) return null; // 不足以成图
    }
    return jsonEncode({'type': type, 'data': data});
  } catch (_) {
    return null;
  }
}
