import 'package:flutter/material.dart';

class MemoryTag extends StatelessWidget {
  final String label;
  final Color? color;

  const MemoryTag({super.key, required this.label, this.color});

  @override
  Widget build(BuildContext context) {
    final tagColor = color ?? Theme.of(context).colorScheme.primary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: tagColor.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: tagColor.withValues(alpha: 0.3)),
      ),
      child: Text(
        label,
        style: TextStyle(fontSize: 12, color: tagColor),
      ),
    );
  }
}
