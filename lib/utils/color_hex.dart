import 'package:flutter/material.dart';

/// 把 `#RRGGBB` / `RRGGBB` 形态的十六进制色字符串解析成 [Color]。
/// 默认 alpha = FF。无效输入抛 [FormatException]，调用方应保证传入有效色。
Color parseHexColor(String hex) {
  final cleaned = hex.replaceFirst('#', '');
  if (cleaned.length != 6) {
    throw FormatException('expected 6-digit hex color, got: $hex');
  }
  return Color(int.parse(cleaned, radix: 16) | 0xFF000000);
}
