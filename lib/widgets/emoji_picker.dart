import 'package:flutter/material.dart';

const presetEmojis = [
  '💼', '🌿', '💰', '❤️', '📚', '🎨', '🎮', '🏠',
  '✈️', '🍳', '🏋️', '🎵', '📷', '🔧', '🐱', '🌍',
  '⚡', '🎯', '🧠', '💡',
];

class EmojiPicker extends StatelessWidget {
  final String? selected;
  final ValueChanged<String> onSelect;

  const EmojiPicker({super.key, this.selected, required this.onSelect});

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: presetEmojis.map((emoji) {
        final isSelected = emoji == selected;
        return GestureDetector(
          onTap: () => onSelect(emoji),
          child: Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: isSelected
                  ? Theme.of(context).colorScheme.primaryContainer
                  : Theme.of(context).colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(10),
              border: isSelected
                  ? Border.all(
                      color: Theme.of(context).colorScheme.primary, width: 2)
                  : null,
            ),
            alignment: Alignment.center,
            child: Text(emoji, style: const TextStyle(fontSize: 22)),
          ),
        );
      }).toList(),
    );
  }
}
