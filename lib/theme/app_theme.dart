import 'package:flutter/material.dart';
import 'design_tokens.dart';

/// Centralized [ThemeData] builder. Keeps Material 3 wired up but tightens the
/// typography, radii, and surface treatments so the app feels less stock.
class AppTheme {
  AppTheme._();

  static ThemeData light() => _build(Brightness.light);
  static ThemeData dark() => _build(Brightness.dark);

  static ThemeData _build(Brightness brightness) {
    // 主题色 = 整套 App 视觉统一性。`scheme.primary` 直接取 [brand]（春绿），
    // 所有走 `scheme.primary` 的 Material 组件（FilledButton、FAB、Switch、
    // focus 边、TabBar 指示线、progress……）一起变成同色，App 才"一体"。
    //
    // 代价：白底/浅底上的纯小字落到 brand 上对比只有 ~2.4:1。对此用**单点
    // override 用 [accentStrong]（4.6:1）兜底**——见 OutlinedButton / TextButton /
    // TabBar labelColor 的覆盖。绝不反过来让整套主题为单点让步。
    final raw = ColorScheme.fromSeed(
      seedColor: AppPalette.brand,
      brightness: brightness,
    );
    final scheme = brightness == Brightness.light
        ? raw.copyWith(
            primary: AppPalette.brand,
            onPrimary: AppPalette.textOnBrand,
            primaryContainer: AppPalette.container,
            onPrimaryContainer: AppPalette.onContainer,
            surface: AppPalette.surface,
            onSurface: AppPalette.textPrimary,
            onSurfaceVariant: AppPalette.textSecondary,
            outlineVariant: AppPalette.textPlaceholder,
            error: AppPalette.danger,
          )
        : raw.copyWith(
            primary: AppPalette.brandDark,
            onPrimary: AppPalette.textOnBrandDark,
            primaryContainer: AppPalette.containerDark,
            onPrimaryContainer: AppPalette.onContainerDark,
            surface: AppPalette.surfaceDark,
            onSurface: AppPalette.textPrimaryDark,
            onSurfaceVariant: AppPalette.textSecondaryDark,
            error: AppPalette.danger,
          );

    // 清新绿：light 模式 scaffold 用暖白偏微黄绿（[bg]）——避免纯白冷硬，营造
    // 晨光感；dark 模式用深炭绿底。
    final scaffoldBg = brightness == Brightness.light
        ? AppPalette.bg
        : AppPalette.bgDark;

    final base = ThemeData(
      colorScheme: scheme,
      useMaterial3: true,
      brightness: brightness,
      scaffoldBackgroundColor: scaffoldBg,
      visualDensity: VisualDensity.standard,
      splashFactory: InkSparkle.splashFactory,
    );

    return base.copyWith(
      textTheme: _textTheme(base.textTheme, scheme),

      appBarTheme: AppBarTheme(
        backgroundColor: scaffoldBg,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: base.textTheme.titleLarge?.copyWith(
          fontWeight: FontWeight.w700,
          letterSpacing: -0.2,
          color: scheme.onSurface,
        ),
        iconTheme: IconThemeData(color: scheme.onSurface),
      ),

      cardTheme: CardThemeData(
        elevation: 0,
        color: scheme.surfaceContainerLow,
        surfaceTintColor: Colors.transparent,
        shape: AppShapes.cardLg,
        margin: EdgeInsets.zero,
      ),

      // 底栏：所有 tab 始终显示 label（对称感）；选中态用 brand 半透明药丸指
      // 示器；图标 28dp（比 M3 默认 24dp 大一档，避免在 76px 高度里显得瘦弱）；
      // 文字 13px、字重略增，让整条底栏视觉重心扎实，呼应"美观大方"。
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: scaffoldBg,
        surfaceTintColor: Colors.transparent,
        indicatorColor: (brightness == Brightness.light
                ? AppPalette.brand
                : AppPalette.brandDark)
            .withValues(alpha: 0.18),
        indicatorShape: const StadiumBorder(),
        elevation: 0,
        height: 76,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          return base.textTheme.labelSmall?.copyWith(
            fontSize: 12.5,
            color: selected ? scheme.primary : scheme.onSurfaceVariant,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            letterSpacing: 0.3,
          );
        }),
        iconTheme: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          return IconThemeData(
            color: selected ? scheme.primary : scheme.onSurfaceVariant,
            size: 28,
          );
        }),
      ),

      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surfaceContainerHighest,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
          borderSide: BorderSide(color: scheme.primary, width: 1.5),
        ),
        labelStyle: base.textTheme.bodyMedium
            ?.copyWith(color: scheme.onSurfaceVariant),
        hintStyle: base.textTheme.bodyMedium
            ?.copyWith(color: scheme.onSurfaceVariant.withValues(alpha: 0.6)),
      ),

      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppRadius.md)),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          textStyle: base.textTheme.labelLarge
              ?.copyWith(fontWeight: FontWeight.w600),
        ),
      ),

      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppRadius.md)),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          textStyle: base.textTheme.labelLarge
              ?.copyWith(fontWeight: FontWeight.w600),
        ),
      ),

      // OutlinedButton 文字落在浅底/白底，必须用 [accentStrong] 而不是 brand 才
      // 能保证小字 4.6:1 对比；边框用 [accent] 提供视觉张力。
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppRadius.md)),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          foregroundColor: brightness == Brightness.light
              ? AppPalette.accentStrong
              : AppPalette.accentStrongDark,
          side: BorderSide(
            color: brightness == Brightness.light
                ? AppPalette.accent
                : AppPalette.accentDark,
            width: 1.5,
          ),
          textStyle: base.textTheme.labelLarge
              ?.copyWith(fontWeight: FontWeight.w600),
        ),
      ),

      // TextButton 同理，文字在浅底，用 accentStrong 兜底正文级对比。
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppRadius.md)),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          foregroundColor: brightness == Brightness.light
              ? AppPalette.accentStrong
              : AppPalette.accentStrongDark,
          textStyle: base.textTheme.labelLarge
              ?.copyWith(fontWeight: FontWeight.w600),
        ),
      ),

      segmentedButtonTheme: SegmentedButtonThemeData(
        style: SegmentedButton.styleFrom(
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppRadius.pill)),
          textStyle: base.textTheme.labelMedium
              ?.copyWith(fontWeight: FontWeight.w600),
        ),
      ),

      chipTheme: ChipThemeData(
        backgroundColor: scheme.surfaceContainerHighest,
        side: BorderSide.none,
        padding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        labelStyle: base.textTheme.labelMedium,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.pill)),
      ),

      dividerTheme: DividerThemeData(
        color: scheme.outlineVariant.withValues(alpha: 0.4),
        thickness: 0.6,
        space: 0.6,
      ),

      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: scaffoldBg,
        surfaceTintColor: Colors.transparent,
        modalBackgroundColor: scheme.surface,
        modalBarrierColor: Colors.black.withValues(alpha: 0.45),
        showDragHandle: true,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
              top: Radius.circular(AppRadius.xl)),
        ),
      ),

      dialogTheme: DialogThemeData(
        backgroundColor: scheme.surfaceContainerHigh,
        surfaceTintColor: Colors.transparent,
        elevation: 4,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.lg)),
        titleTextStyle: base.textTheme.titleLarge
            ?.copyWith(fontWeight: FontWeight.w700),
      ),

      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: scheme.inverseSurface,
        contentTextStyle: base.textTheme.bodyMedium
            ?.copyWith(color: scheme.onInverseSurface),
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.md)),
      ),

      listTileTheme: ListTileThemeData(
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        iconColor: scheme.onSurfaceVariant,
        titleTextStyle: base.textTheme.bodyLarge
            ?.copyWith(fontWeight: FontWeight.w500, color: scheme.onSurface),
        subtitleTextStyle: base.textTheme.bodySmall
            ?.copyWith(color: scheme.onSurfaceVariant),
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.md)),
      ),

      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppRadius.md)),
        ),
      ),

      // FAB 走 scheme.primary（= brand），跟其它实色主操作保持视觉统一。
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: scheme.primary,
        foregroundColor: scheme.onPrimary,
        elevation: 2,
        focusElevation: 3,
        hoverElevation: 3,
        highlightElevation: 4,
        shape: const CircleBorder(),
      ),

      // TabBar 选中态：标签文字用 accentStrong（小字落在 surface 上要 AA），
      // 指示线用 scheme.primary（= brand）保留春绿身份。
      tabBarTheme: TabBarThemeData(
        labelColor: brightness == Brightness.light
            ? AppPalette.accentStrong
            : AppPalette.accentStrongDark,
        unselectedLabelColor: scheme.onSurfaceVariant,
        indicatorColor: scheme.primary,
        indicatorSize: TabBarIndicatorSize.label,
        labelStyle: base.textTheme.titleSmall
            ?.copyWith(fontWeight: FontWeight.w600),
        unselectedLabelStyle: base.textTheme.titleSmall,
        dividerColor: Colors.transparent,
      ),
    );
  }

  /// Slightly tighter / more refined typography vs M3 defaults.
  static TextTheme _textTheme(TextTheme base, ColorScheme scheme) {
    return base.copyWith(
      displayLarge: base.displayLarge?.copyWith(
        fontWeight: FontWeight.w700,
        letterSpacing: -0.5,
      ),
      displayMedium: base.displayMedium?.copyWith(
        fontWeight: FontWeight.w700,
        letterSpacing: -0.4,
      ),
      headlineLarge: base.headlineLarge?.copyWith(
        fontWeight: FontWeight.w700,
        letterSpacing: -0.3,
      ),
      headlineMedium: base.headlineMedium?.copyWith(
        fontWeight: FontWeight.w700,
        letterSpacing: -0.3,
      ),
      headlineSmall: base.headlineSmall?.copyWith(
        fontWeight: FontWeight.w700,
        letterSpacing: -0.2,
      ),
      titleLarge: base.titleLarge?.copyWith(
        fontWeight: FontWeight.w700,
        letterSpacing: -0.2,
      ),
      titleMedium: base.titleMedium?.copyWith(
        fontWeight: FontWeight.w600,
      ),
      bodyLarge: base.bodyLarge?.copyWith(height: 1.45),
      bodyMedium: base.bodyMedium?.copyWith(height: 1.45),
      labelLarge: base.labelLarge?.copyWith(
        fontWeight: FontWeight.w600,
      ),
    );
  }
}
