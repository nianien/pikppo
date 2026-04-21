class Role {
  final String id;
  final String name;
  final String icon;
  final String description;
  final String color;
  final String systemPrompt;

  const Role({
    required this.id,
    required this.name,
    required this.icon,
    required this.description,
    required this.color,
    required this.systemPrompt,
  });

  Role copyWith({
    String? id,
    String? name,
    String? icon,
    String? description,
    String? color,
    String? systemPrompt,
  }) {
    return Role(
      id: id ?? this.id,
      name: name ?? this.name,
      icon: icon ?? this.icon,
      description: description ?? this.description,
      color: color ?? this.color,
      systemPrompt: systemPrompt ?? this.systemPrompt,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'icon': icon,
        'description': description,
        'color': color,
        'systemPrompt': systemPrompt,
      };

  factory Role.fromJson(Map<String, dynamic> json) => Role(
        id: json['id'] as String,
        name: json['name'] as String,
        icon: json['icon'] as String,
        description: json['description'] as String,
        color: json['color'] as String,
        systemPrompt: json['systemPrompt'] as String,
      );
}
