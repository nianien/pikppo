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

  /// 附件类型：'image' | 'video' | 'file'，null = 纯文本消息。
  /// 附件消息的 [content] 存说明文字（可为空串）；文件本体是应用文档目录
  /// attachments/ 下的私有副本（[attachmentPath]）。
  final String? attachmentType;
  final String? attachmentPath;
  final String? attachmentName;
  final int? attachmentSize;

  /// 富图表卡片，JSON 数组字符串 `[{type,data}, ...]`。挂在 AI 文字消息上、与文字
  /// 同气泡渲染（图在上、文字在下）。[content] 保持纯文本——进 LLM 历史、可复制/
  /// 转发；图表数据独立于此，不进历史。null = 普通消息。
  final String? chartData;

  const Message({
    required this.id,
    required this.roleId,
    required this.content,
    required this.isUser,
    required this.timestamp,
    this.groupId,
    this.kind = 'chat',
    this.attachmentType,
    this.attachmentPath,
    this.attachmentName,
    this.attachmentSize,
    this.chartData,
  });

  bool get hasAttachment => attachmentType != null;

  Map<String, dynamic> toJson() => {
        'id': id,
        'roleId': roleId,
        'content': content,
        'isUser': isUser,
        'timestamp': timestamp,
        if (groupId != null) 'groupId': groupId,
        if (kind != 'chat') 'kind': kind,
        if (attachmentType != null) 'attachmentType': attachmentType,
        if (attachmentPath != null) 'attachmentPath': attachmentPath,
        if (attachmentName != null) 'attachmentName': attachmentName,
        if (attachmentSize != null) 'attachmentSize': attachmentSize,
        if (chartData != null) 'chartData': chartData,
      };

  factory Message.fromJson(Map<String, dynamic> json) => Message(
        id: json['id'] as String,
        roleId: json['roleId'] as String,
        content: json['content'] as String,
        isUser: json['isUser'] as bool,
        timestamp: json['timestamp'] as int,
        groupId: json['groupId'] as String?,
        kind: (json['kind'] as String?) ?? 'chat',
        attachmentType: json['attachmentType'] as String?,
        attachmentPath: json['attachmentPath'] as String?,
        attachmentName: json['attachmentName'] as String?,
        attachmentSize: json['attachmentSize'] as int?,
        chartData: json['chartData'] as String?,
      );
}