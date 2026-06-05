class Memory {
  final String id;
  final String type; // 'semantic' | 'episodic' | 'working'
  final String content;
  final String? roleId;
  final int timestamp;
  final List<String> tags;

  const Memory({
    required this.id,
    required this.type,
    required this.content,
    this.roleId,
    required this.timestamp,
    required this.tags,
  });

  Memory copyWith({
    String? type,
    String? content,
    String? roleId,
    int? timestamp,
    List<String>? tags,
    bool clearRoleId = false,
  }) =>
      Memory(
        id: id,
        type: type ?? this.type,
        content: content ?? this.content,
        roleId: clearRoleId ? null : (roleId ?? this.roleId),
        timestamp: timestamp ?? this.timestamp,
        tags: tags ?? this.tags,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'type': type,
        'content': content,
        'roleId': roleId,
        'timestamp': timestamp,
        'tags': tags,
      };

  factory Memory.fromJson(Map<String, dynamic> json) => Memory(
        id: json['id'] as String,
        type: json['type'] as String,
        content: json['content'] as String,
        roleId: json['roleId'] as String?,
        timestamp: json['timestamp'] as int,
        tags: List<String>.from(json['tags'] as List),
      );
}