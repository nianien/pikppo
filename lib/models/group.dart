class Group {
  final String id;
  final String name;
  final List<String> roleIds;

  const Group({
    required this.id,
    required this.name,
    required this.roleIds,
  });

  Group copyWith({String? id, String? name, List<String>? roleIds}) {
    return Group(
      id: id ?? this.id,
      name: name ?? this.name,
      roleIds: roleIds ?? this.roleIds,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'roleIds': roleIds,
      };

  factory Group.fromJson(Map<String, dynamic> json) => Group(
        id: json['id'] as String,
        name: json['name'] as String,
        roleIds: List<String>.from(json['roleIds'] as List),
      );
}
