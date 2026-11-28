import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Colors and type scale mirrored from the Kotlin app's SidequestsTheme
/// (ui/theme/SidequestsTheme.kt): Outfit for headings, DM Sans for body, a
/// purple/teal/amber palette with matching dark-mode variants. Roles the
/// Kotlin theme leaves unset fall back to Material 3's baseline values there,
/// so they are spelled out here with those same baseline values.
abstract final class AppColors {
  /// ExplorerIndigo / ExplorerIndigoLight.
  static const primary = Color(0xFF5B4BDB);
  static const primaryLight = Color(0xFF7B6DE8);

  /// LightSurfaceAlt / DarkSurfaceAlt: surfaceVariant and primaryContainer.
  static const primaryContainerLight = Color(0xFFEEEAFF);
  static const primaryContainerDark = Color(0xFF232140);

  /// DiscoveryTeal / DiscoveryTealDark.
  static const secondary = Color(0xFF2AB7A9);
  static const secondaryDark = Color(0xFF1E9E92);
  static const secondaryContainerLight = Color(0xFFF0FFFE);
  static const secondaryContainerDark = Color(0xFF142824);
  static const onSecondaryContainerLight = Color(0xFF113D36);
  static const onSecondaryContainerDark = Color(0xFF91E6D9);

  /// QuestAmber.
  static const amber = Color(0xFFFFB347);

  /// Material 3 baseline error roles (the Kotlin theme keeps the defaults).
  static const error = Color(0xFFB3261E);
  static const errorDark = Color(0xFFF2B8B5);
  static const errorContainerLight = Color(0xFFF9DEDC);
  static const errorContainerDark = Color(0xFF8C1D18);
  static const onErrorContainerLight = Color(0xFF410E0B);
  static const onErrorContainerDark = Color(0xFFF9DEDC);

  static const backgroundLight = Color(0xFFF6F5FF);
  static const backgroundDark = Color(0xFF0E0D1A);
  static const surfaceLight = Color(0xFFFFFFFF);
  static const surfaceDark = Color(0xFF19182D);

  /// LightBorder / DarkBorder: the `outline` role (card and chip borders).
  static const borderLight = Color(0xFFDDD9FF);
  static const borderDark = Color(0xFF2C2A4A);

  /// LightText / DarkText.
  static const textPrimaryLight = Color(0xFF1A1830);
  static const textPrimaryDark = Color(0xFFEDE9FF);

  /// onSurfaceVariant.
  static const textSecondaryLight = Color(0xFF6B6990);
  static const textSecondaryDark = Color(0xFFA6A3BF);

  /// Material 3 baseline surfaceContainerHighest: what a plain Compose
  /// `Card` (no explicit colors) is filled with in the Kotlin app.
  static const plainCardLight = Color(0xFFE6E0E9);
  static const plainCardDark = Color(0xFF36343B);

  /// Text on a light accent (amber, teal) — Kotlin switches to it above .35 luminance.
  static const onLightAccent = Color(0xFF1A1830);

  /// Kotlin's `contentColor` rule: dark text on light accents, white otherwise.
  static Color onAccent(Color accent) => accent.computeLuminance() > .35 ? onLightAccent : Colors.white;
}

abstract final class AppTheme {
  static ThemeData light = _build(Brightness.light);
  static ThemeData dark = _build(Brightness.dark);

  /// Compose's tonal elevation overlay: the NavigationBar is `surface` at 3 dp,
  /// tinted with the primary color by ((4.5 * ln(dp + 1)) + 2) %.
  static Color _tonal(Color surface, Color tint, double elevation) {
    final alpha = ((4.5 * math.log(elevation + 1)) + 2) / 100;
    return Color.alphaBlend(tint.withValues(alpha: alpha), surface);
  }

  static ThemeData _build(Brightness brightness) {
    final isDark = brightness == Brightness.dark;
    final primary = isDark ? AppColors.primaryLight : AppColors.primary;
    final surface = isDark ? AppColors.surfaceDark : AppColors.surfaceLight;
    final surfaceVariant = isDark ? AppColors.primaryContainerDark : AppColors.primaryContainerLight;
    final textColor = isDark ? AppColors.textPrimaryDark : AppColors.textPrimaryLight;
    final textSecondary = isDark ? AppColors.textSecondaryDark : AppColors.textSecondaryLight;
    final border = isDark ? AppColors.borderDark : AppColors.borderLight;
    final colorScheme = ColorScheme(
      brightness: brightness,
      primary: primary,
      onPrimary: Colors.white,
      primaryContainer: surfaceVariant,
      onPrimaryContainer: textColor,
      secondary: AppColors.secondary,
      onSecondary: Colors.white,
      secondaryContainer: isDark ? AppColors.secondaryContainerDark : AppColors.secondaryContainerLight,
      onSecondaryContainer: isDark ? AppColors.onSecondaryContainerDark : AppColors.onSecondaryContainerLight,
      tertiary: AppColors.amber,
      onTertiary: AppColors.textPrimaryLight,
      error: isDark ? AppColors.errorDark : AppColors.error,
      onError: isDark ? const Color(0xFF601410) : Colors.white,
      errorContainer: isDark ? AppColors.errorContainerDark : AppColors.errorContainerLight,
      onErrorContainer: isDark ? AppColors.onErrorContainerDark : AppColors.onErrorContainerLight,
      surface: surface,
      onSurface: textColor,
      onSurfaceVariant: textSecondary,
      surfaceContainerHighest: isDark ? AppColors.plainCardDark : AppColors.plainCardLight,
      surfaceContainerHigh: isDark ? const Color(0xFF2B2930) : const Color(0xFFECE6F0),
      surfaceContainer: isDark ? const Color(0xFF211F26) : const Color(0xFFF3EDF7),
      surfaceContainerLow: isDark ? const Color(0xFF1D1B20) : const Color(0xFFF7F2FA),
      outline: border,
      outlineVariant: border,
      inverseSurface: isDark ? const Color(0xFFE6E0E9) : const Color(0xFF322F35),
      onInverseSurface: isDark ? const Color(0xFF322F35) : const Color(0xFFF5EFF7),
      inversePrimary: isDark ? AppColors.primary : AppColors.primaryLight,
      surfaceTint: primary,
    );

    final headingFont = GoogleFonts.outfitTextTheme();
    final bodyFont = GoogleFonts.dmSansTextTheme();
    const semiBold = FontWeight.w600;

    final textTheme = bodyFont
        .copyWith(
          displayLarge: headingFont.displayLarge,
          displayMedium: headingFont.displayMedium,
          displaySmall: headingFont.displaySmall?.copyWith(fontWeight: semiBold, fontSize: 32, height: 38 / 32),
          headlineLarge: headingFont.headlineLarge?.copyWith(fontWeight: semiBold),
          headlineMedium: headingFont.headlineMedium?.copyWith(fontWeight: semiBold),
          headlineSmall: headingFont.headlineSmall?.copyWith(fontWeight: semiBold),
          titleLarge: headingFont.titleLarge?.copyWith(fontWeight: semiBold),
          titleMedium: headingFont.titleMedium?.copyWith(fontWeight: semiBold),
          titleSmall: headingFont.titleSmall?.copyWith(fontWeight: semiBold),
          labelLarge: bodyFont.labelLarge?.copyWith(fontWeight: FontWeight.w700),
          labelMedium: bodyFont.labelMedium?.copyWith(fontWeight: semiBold),
          labelSmall: bodyFont.labelSmall?.copyWith(fontWeight: semiBold),
        )
        .apply(bodyColor: textColor, displayColor: textColor);

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: isDark ? AppColors.backgroundDark : AppColors.backgroundLight,
      canvasColor: isDark ? AppColors.backgroundDark : AppColors.backgroundLight,
      // Containers drawn with `cardColor` are Kotlin's surface cards.
      cardColor: surface,
      textTheme: textTheme,
      appBarTheme: AppBarTheme(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        foregroundColor: textColor,
        titleTextStyle: textTheme.titleLarge?.copyWith(color: textColor),
      ),
      // A plain Compose Card: surfaceContainerHighest, 12 dp corners, flat.
      // Screens that use the Kotlin "bordered surface" card set it explicitly.
      cardTheme: CardThemeData(
        color: colorScheme.surfaceContainerHighest,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        margin: EdgeInsets.zero,
      ),
      // Kotlin's ChoiceChip: a pill, surfaceVariant with an outline border
      // when off, filled with the accent (no checkmark, no border) when on.
      chipTheme: ChipThemeData(
        backgroundColor: surfaceVariant,
        selectedColor: primary,
        disabledColor: surfaceVariant,
        showCheckmark: false,
        labelStyle: textTheme.labelLarge?.copyWith(
          color: WidgetStateColor.resolveWith(
            (states) => states.contains(WidgetState.selected) ? Colors.white : textColor,
          ),
        ),
        secondaryLabelStyle: textTheme.labelLarge?.copyWith(color: Colors.white),
        side: WidgetStateBorderSide.resolveWith(
          (states) => states.contains(WidgetState.selected) ? BorderSide.none : BorderSide(color: border),
        ),
        shape: const StadiumBorder(),
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
        labelPadding: const EdgeInsets.symmetric(horizontal: 8),
        elevation: 0,
        pressElevation: 0,
      ),
      // PrimaryButton: full width, 52 dp tall, 16 dp corners, labelLarge.
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: primary,
          foregroundColor: Colors.white,
          disabledBackgroundColor: textColor.withValues(alpha: 0.12),
          disabledForegroundColor: textColor.withValues(alpha: 0.38),
          minimumSize: const Size.fromHeight(52),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          textStyle: textTheme.labelLarge,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: primary,
          minimumSize: const Size.fromHeight(52),
          side: BorderSide(color: border),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          textStyle: textTheme.labelLarge,
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(foregroundColor: primary, textStyle: textTheme.labelLarge),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: _tonal(surface, primary, 3),
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        height: 80,
        indicatorColor: surfaceVariant,
        labelTextStyle: WidgetStateProperty.resolveWith(
          (states) => textTheme.labelSmall?.copyWith(
            color: states.contains(WidgetState.selected) ? primary : textSecondary,
          ),
        ),
        iconTheme: WidgetStateProperty.resolveWith(
          (states) => IconThemeData(
            size: 24,
            color: states.contains(WidgetState.selected) ? primary : textSecondary,
          ),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: surfaceVariant,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide.none,
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: primary,
        linearTrackColor: surfaceVariant,
      ),
      dialogTheme: DialogThemeData(backgroundColor: colorScheme.surfaceContainerHigh),
      snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.fixed),
      dividerTheme: DividerThemeData(color: border),
    );
  }
}
