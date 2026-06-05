import 'package:flutter/material.dart';

/// Centralized design tokens. Changing values here cascades to every screen.
class AppRadius {
  AppRadius._();
  static const double xs = 8;
  static const double sm = 12;
  static const double md = 16;
  static const double lg = 20;
  static const double xl = 28;
  static const double pill = 999;
}

class AppSpacing {
  AppSpacing._();
  static const double xxs = 4;
  static const double xs = 8;
  static const double sm = 12;
  static const double md = 16;
  static const double lg = 20;
  static const double xl = 24;
  static const double xxl = 32;
  static const double xxxl = 48;
}

class AppDurations {
  AppDurations._();
  static const Duration fast = Duration(milliseconds: 150);
  static const Duration normal = Duration(milliseconds: 250);
  static const Duration slow = Duration(milliseconds: 400);
}

/// Brand colors. Picked to feel contemporary but keep the original green DNA.
class AppPalette {
  AppPalette._();
  static const Color seed = Color(0xFF10B981); // Emerald 500
  static const Color seedDeep = Color(0xFF059669); // Emerald 600
  static const Color seedSoft = Color(0xFFD1FAE5); // Emerald 100
  static const Color accent = Color(0xFF6366F1); // Indigo for highlight
}

/// Common rounded shapes used across the app.
class AppShapes {
  AppShapes._();
  static final RoundedRectangleBorder card = RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(AppRadius.md),
  );
  static final RoundedRectangleBorder cardLg = RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(AppRadius.lg),
  );
  static final RoundedRectangleBorder pill = RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(AppRadius.pill),
  );
}
