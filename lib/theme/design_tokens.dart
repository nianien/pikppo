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

  /// 气泡圆角——主体 18px、尾角 5px（设计稿明确尺寸）。
  static const double bubble = 18;
  static const double bubbleTail = 5;
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

/// Design Tokens —— 清新绿春绿主题（定稿）。命名按**用途**而非"深浅"，调用方
/// 一看就知道能不能承载白字。
///
/// 核心可达性规则（这是整套设计的命脉，违反就破坏可读性）：
/// - [brand]（#3FB984）白底对比 ~2.4:1，**仅作色块/图标背景**，禁止配小号白字标签。
///   用户气泡和 Send 键这种"大字 / 纯图标"场景例外。
/// - 浅底上的图标 / 链接 / 强调文字 → [accent]（~3.2:1，大字达标）。
/// - 浅底上的**正文级**强调或小字白字 → [accentStrong]（4.6:1，AA 正文达标）。
class AppPalette {
  AppPalette._();

  // ---- 品牌 / 主色 ----
  /// 春绿主色：通透、年轻、空气感。用于 Logo、用户气泡、圆形 Send 键、品牌强调。
  /// 白字对比 ~2.4:1——**只作色块/图标背景**，不承载小号白字。
  static const Color brand = Color(0xFF3FB984);

  /// 主色 hover——略压一档。
  static const Color brandHover = Color(0xFF36AC79);

  /// 主色按下态。
  static const Color brandActive = Color(0xFF2E9E6E);

  // ---- 强调 / 交互文字 ----
  /// 浅底/白底上的强调色：按钮文字、图标、链接、描边。白底对比 ~3.2:1（大字达标）。
  static const Color accent = Color(0xFF2E9E6E);

  /// **白字承载位 / 小字强调位**：白底对比 4.6:1 ✅ AA 正文达标。
  /// Material 的 `scheme.primary` 取这个色，让所有自动放白字的 Material 组件都安全。
  static const Color accentStrong = Color(0xFF1F7E55);

  /// 浅底按钮的 hover 背景。
  static const Color accentHoverBg = Color(0xFFEAF6F0);

  // ---- 容器 / 气泡 ----
  /// AI 气泡、成功卡片底。
  static const Color container = Color(0xFFE4F4EC);

  /// 更浅一档填充：选中态、标签底。
  static const Color container2 = Color(0xFFEEF4EC);

  /// 容器内文字（深松绿）。
  static const Color onContainer = Color(0xFF0F3B2C);

  // ---- 背景 / 表面 ----
  /// 全局 scaffold 背景：暖白偏微黄绿——避免纯白冷硬，营造晨光感。
  static const Color bg = Color(0xFFFBFCF7);

  /// 卡片 / 输入框表面（纯白，跟 [bg] 形成微差）。
  static const Color surface = Color(0xFFFFFFFF);

  // ---- 文字 ----
  /// 正文主色：深松绿调，非纯黑、不发冷。
  static const Color textPrimary = Color(0xFF16322A);
  static const Color textSecondary = Color(0xFF4A5C54);
  static const Color textMuted = Color(0xFF7C9389);
  static const Color textPlaceholder = Color(0xFFA6B7AE);

  /// 主色块上的文字（白）。
  static const Color textOnBrand = Color(0xFFFFFFFF);

  // ---- 状态色（柔和暖调，避开刺眼） ----
  static const Color success = Color(0xFF2E9E6E);
  static const Color successBg = Color(0xFFE4F4EC);
  static const Color warning = Color(0xFFE89A4F);
  static const Color warningBg = Color(0xFFFBEFDF);
  static const Color danger = Color(0xFFDB6B5B);
  static const Color dangerBg = Color(0xFFFBE9E6);
  static const Color info = Color(0xFF57A89A);
  static const Color infoBg = Color(0xFFE5F2EF);

  // ---- 暗色模式（系统跟随；不强制） ----
  static const Color brandDark = Color(0xFF5ACF9C);
  static const Color brandDarkHover = Color(0xFF6BD9A9);
  static const Color accentDark = Color(0xFF6FD9AB);
  static const Color accentStrongDark = Color(0xFF8CE6C0);
  static const Color containerDark = Color(0xFF163B2E);
  static const Color onContainerDark = Color(0xFFCFEEDF);
  static const Color bgDark = Color(0xFF0F1A15);
  static const Color surfaceDark = Color(0xFF17251F);
  static const Color textPrimaryDark = Color(0xFFE9F3EE);
  static const Color textSecondaryDark = Color(0xFFA9BDB4);
  static const Color textOnBrandDark = Color(0xFF08291D);
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
