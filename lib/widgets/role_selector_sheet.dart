import 'package:flutter/material.dart';
import '../models/role.dart';
import '../utils/color_hex.dart';

class RoleSelectorSheet extends StatelessWidget {
  final List<Role> roles;
  final String currentRoleId;
  final ValueChanged<Role> onSelect;

  const RoleSelectorSheet({
    super.key,
    required this.roles,
    required this.currentRoleId,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.only(top: 12, bottom: 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 36,
            height: 4,
            decoration: BoxDecoration(
              color: theme.colorScheme.outlineVariant,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text('选择角色',
                  style: theme.textTheme.titleMedium
                      ?.copyWith(fontWeight: FontWeight.bold)),
            ),
          ),
          const SizedBox(height: 12),
          ...roles.map((role) {
            final isSelected = role.id == currentRoleId;
            final color = parseHexColor(role.color);
            return ListTile(
              leading: CircleAvatar(
                backgroundColor: color.withValues(alpha: 0.15),
                child: Text(role.icon, style: const TextStyle(fontSize: 22)),
              ),
              title: Text(
                role.name,
                style: TextStyle(
                  fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                  color: isSelected ? color : null,
                ),
              ),
              subtitle: Text(role.description),
              trailing: isSelected
                  ? Icon(Icons.check_circle, color: color)
                  : null,
              onTap: () => onSelect(role),
            );
          }),
        ],
      ),
    );
  }
}
