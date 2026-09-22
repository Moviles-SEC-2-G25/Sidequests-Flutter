import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Colors and type scale reverse-engineered from the Figma reference
/// (https://beaver-undo-90237796.figma.site) — extracted from its compiled
/// stylesheet: Outfit for headings, DM Sans for body, a purple/teal/amber
/// palette with matching dark-mode variants.
abstract final class AppColors {
  static const primary = Color(0xFF5B4BDB);
  static const primaryLight = Color(0xFF7B6DE8);
  static const primaryContainerLight = Color(0xFFEEEAFF);
  static const primaryContainerDark = Color(0xFF232140);

  static const secondary = Color(0xFF2AB7A9);
  static const secondaryDark = Color(0xFF1E9E92);
  static const secondaryContainerLight = Color(0xFFF0FFFE);
  static const secondaryContainerDark = Color(0xFF142824);

  static const amber = Color(0xFFFFB347);

  static const error = Color(0xFFE05252);
  static const errorContainerLight = Color(0xFFFFCCCC);
  static const errorContainerDark = Color(0xFF4A1E1E);

  static const backgroundLight = Color(0xFFF6F5FF);
  static const backgroundDark = Color(0xFF0E0D1A);
  static const surfaceLight = Color(0xFFFFFFFF);
  static const surfaceDark = Color(0xFF19182D);

  static const textPrimaryLight = Color(0xFF232140);
  static const textPrimaryDark = Color(0xFFF6F5FF);
  static const textSecondaryLight = Color(0xFF6B6990);
  static const textSecondaryDark = Color(0xFF8B8AAA);
}

abstract final class AppTheme {
  static ThemeData light = _build(Brightness.light);
  static ThemeData dark = _build(Brightness.dark);

  static ThemeData _build(Brightness brightness) {
    final isDark = brightness == Brightness.dark;
    final colorScheme = ColorScheme(
      brightness: brightness,
      primary: AppColors.primary,
      onPrimary: Colors.white,
      secondary: AppColors.secondary,
      onSecondary: Colors.white,
      tertiary: AppColors.amber,
      onTertiary: AppColors.textPrimaryLight,
      error: AppColors.error,
      onError: Colors.white,
      surface: isDark ? AppColors.surfaceDark : AppColors.surfaceLight,
      onSurface: isDark ? AppColors.textPrimaryDark : AppColors.textPrimaryLight,
      surfaceContainerHighest: isDark
          ? AppColors.primaryContainerDark
          : AppColors.primaryContainerLight,
      outline: isDark ? AppColors.textSecondaryDark : AppColors.textSecondaryLight,
    );

    final headingFont = GoogleFonts.outfitTextTheme();
    final bodyFont = GoogleFonts.dmSansTextTheme();
    final textColor = isDark ? AppColors.textPrimaryDark : AppColors.textPrimaryLight;

    final textTheme = bodyFont
        .copyWith(
          displayLarge: headingFont.displayLarge,
          displayMedium: headingFont.displayMedium,
          displaySmall: headingFont.displaySmall,
          headlineLarge: headingFont.headlineLarge,
          headlineMedium: headingFont.headlineMedium,
          headlineSmall: headingFont.headlineSmall,
          titleLarge: headingFont.titleLarge,
          titleMedium: headingFont.titleMedium,
          titleSmall: headingFont.titleSmall,
        )
        .apply(bodyColor: textColor, displayColor: textColor);

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: isDark ? AppColors.backgroundDark : AppColors.backgroundLight,
      textTheme: textTheme,
      appBarTheme: AppBarTheme(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        foregroundColor: textColor,
        titleTextStyle: headingFont.titleLarge?.copyWith(color: textColor),
      ),
      cardTheme: CardThemeData(
        color: isDark ? AppColors.surfaceDark : AppColors.surfaceLight,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        margin: EdgeInsets.zero,
      ),
      chipTheme: ChipThemeData(
        backgroundColor: isDark ? AppColors.primaryContainerDark : AppColors.primaryContainerLight,
        selectedColor: AppColors.primary,
        labelStyle: bodyFont.labelLarge?.copyWith(color: textColor),
        secondaryLabelStyle: bodyFont.labelLarge?.copyWith(color: Colors.white),
        side: BorderSide.none,
        shape: const StadiumBorder(),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: AppColors.primary,
          foregroundColor: Colors.white,
          minimumSize: const Size.fromHeight(52),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          textStyle: bodyFont.labelLarge?.copyWith(fontWeight: FontWeight.w700),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: textColor,
          minimumSize: const Size.fromHeight(52),
          side: BorderSide(color: colorScheme.outline.withValues(alpha: 0.4)),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: isDark ? AppColors.surfaceDark : AppColors.surfaceLight,
        indicatorColor: AppColors.primaryContainerLight.withValues(alpha: isDark ? 0.3 : 1),
        labelTextStyle: WidgetStateProperty.resolveWith(
          (states) => bodyFont.labelSmall?.copyWith(
            color: states.contains(WidgetState.selected) ? AppColors.primary : colorScheme.outline,
            fontWeight: FontWeight.w600,
          ),
        ),
        iconTheme: WidgetStateProperty.resolveWith(
          (states) => IconThemeData(
            color: states.contains(WidgetState.selected) ? AppColors.primary : colorScheme.outline,
          ),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: isDark ? AppColors.primaryContainerDark : AppColors.primaryContainerLight,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide.none,
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      ),
    );
  }
}
