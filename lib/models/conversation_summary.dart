/// 单个会话（私聊或群聊）的"末条消息摘要"——只存渲染列表所需的最小字段。
/// 启动时一次性预加载，让聊天列表无需把整张 messages 表读进内存。
class ConversationSummary {
  /// `'role:<roleId>'` = 私聊；`'group:<groupId>'` = 群聊。
  final String scopeKey;
  final int lastTimestamp;
  final String lastContent;

  const ConversationSummary({
    required this.scopeKey,
    required this.lastTimestamp,
    required this.lastContent,
  });

  ConversationSummary copyWith({
    int? lastTimestamp,
    String? lastContent,
  }) =>
      ConversationSummary(
        scopeKey: scopeKey,
        lastTimestamp: lastTimestamp ?? this.lastTimestamp,
        lastContent: lastContent ?? this.lastContent,
      );

  static String keyForRole(String roleId) => 'role:$roleId';
  static String keyForGroup(String groupId) => 'group:$groupId';
}
