class Message {
  final String id;
  final String roleId;
  final String content;
  final bool isUser;
  final int timestamp;
  final String? groupId; // null = private chat, non-null = group chat

  const Message({
    required this.id,
    required this.roleId,
    required this.content,
    required this.isUser,
    required this.timestamp,
    this.groupId,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'roleId': roleId,
        'content': content,
        'isUser': isUser,
        'timestamp': timestamp,
        if (groupId != null) 'groupId': groupId,
      };

  factory Message.fromJson(Map<String, dynamic> json) => Message(
        id: json['id'] as String,
        roleId: json['roleId'] as String,
        content: json['content'] as String,
        isUser: json['isUser'] as bool,
        timestamp: json['timestamp'] as int,
        groupId: json['groupId'] as String?,
      );
}
