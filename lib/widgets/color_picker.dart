import 'package:flutter/material.dart';

const presetColors = [
  '#3B82F6', // blue
  '#22C55E', // green
  '#F97316', // orange
  '#EF4444', // red
  '#8B5CF6', // purple
  '#EC4899', // pink
  '#06B6D4', // cyan
  '#F59E0B', // amber
];

Color parseColor(String hex) {
  return Color(int.parse(hex.replaceFirst('#', '0xFF')));
}

class ColorPickerWidget extends StatelessWidget {
  final String? selected;
  final ValueChanged<String> onSelect;

  const ColorPickerWidget({super.key, this.selected, required this.onSelect});

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 12,
      runSpacing: 12,
      children: presetColors.map((hex) {
        final color = parseColor(hex);
        final isSelected = hex == selected;
        return GestureDetector(
          onTap: () => onSelect(hex),
          child: Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
              border: isSelected
                  ? Border.all(color: Colors.white, width: 3)
                  : null,
              boxShadow: isSelected
                  ? [BoxShadow(color: color.withValues(alpha: 0.5), blurRadius: 8)]
                  : null,
            ),
            child: isSelected
                ? const Icon(Icons.check, color: Colors.white, size: 20)
                : null,
          ),
        );
      }).toList(),
    );
  }
}
