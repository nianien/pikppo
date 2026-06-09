import 'package:flutter/material.dart';
import '../models/role.dart';
import '../utils/color_hex.dart';

class RoleChip extends StatelessWidget {
  final Role role;
  final bool selected;
  final VoidCallback? onTap;

  const RoleChip({
    super.key,
    required this.role,
    this.selected = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color = parseHexColor(role.color);
    return ActionChip(
      avatar: Text(role.icon, style: const TextStyle(fontSize: 14)),
      label: Text(role.name),
      labelStyle: TextStyle(
        color: selected ? Colors.white : color,
        fontWeight: selected ? FontWeight.bold : FontWeight.normal,
      ),
      backgroundColor: selected ? color : color.withValues(alpha: 0.1),
      side: BorderSide(color: color.withValues(alpha: 0.3)),
      onPressed: onTap,
    );
  }
}
