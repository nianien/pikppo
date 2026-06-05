class Message {
  final String id;
  final String roleId;
  final String content;
  final bool isUser;
  final int timestamp;
  final String? groupId; // null = private chat, non-null = group chat

  /// 'chat' = 普通对话消息（默认，会进 LLM 历史）
  /// 'tool_status' = Agent 工具调用过程中的状态气泡（UI 展示用，不进 LLM 历史）
  /// 'reminder' = 日程提醒（UI 展示，不进历史）
  final String kind;

  const Message({
    required this.id,
    required this.roleId,
    required this.content,
    required this.isUser,
    required this.timestamp,
    this.groupId,
    this.kind = 'chat',
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'roleId': roleId,
        'content': content,
        'isUser': isUser,
        'timestamp': timestamp,
        if (groupId != null) 'groupId': groupId,
        if (kind != 'chat') 'kind': kind,
      };

  factory Message.fromJson(Map<String, dynamic> json) => Message(
        id: json['id'] as String,
        roleId: json['roleId'] as String,
        content: json['content'] as String,
        isUser: json['isUser'] as bool,
        timestamp: json['timestamp'] as int,
        groupId: json['groupId'] as String?,
        kind: (json['kind'] as String?) ?? 'chat',
      );
}