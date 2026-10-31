import 'package:flutter/material.dart';

/// Two looks, following the phone's dark mode setting.
///
/// Dark: black, Threads-like; near-white text on pure black. Colour is used
/// only for errors and the like heart.
///
/// Light: warm cream paper (#FEFAF3) with carnation pink as the accent.
///
/// Secondary text meets WCAG AA on both backgrounds.
abstract final class AppPalette {
  static const carnation = Color(0xFFFFA6C9);

  static const dark = ColorScheme(
    brightness: Brightness.dark,
    primary: Color(0xFFF5F5F5),
    onPrimary: Color(0xFF000000),
    secondary: Color(0xFFF5F5F5),
    onSecondary: Color(0xFF000000),
    error: Color(0xFFFF6B7A),
    onError: Color(0xFF000000),
    surface: Color(0xFF000000),
    onSurface: Color(0xFFF5F5F5),
    onSurfaceVariant: Color(0xFF8E8E8E), // muted text ≈ 6.4:1 on black
    surfaceContainerLow: Color(0xFF101010), // the composer sheet
    surfaceContainerHighest: Color(0xFF181818), // fields, avatars, placeholders
    outline: Color(0xFF3A3A3A),
    outlineVariant: Color(0xFF262626), // hairlines
  );

  static const light = ColorScheme(
    brightness: Brightness.light,
    primary: carnation, // Login / Post buttons, tab indicator, cursor
    onPrimary: Color(0xFF3B1426),
    secondary: carnation,
    onSecondary: Color(0xFF3B1426),
    error: Color(0xFFC2304B),
    onError: Color(0xFFFFFFFF),
    surface: Color(0xFFFEFAF3),
    onSurface: Color(0xFF2A2124),
    onSurfaceVariant: Color(0xFF7A666D), // muted text ≈ 5.4:1 on cream
    surfaceContainerLow: Color(0xFFFFFDF9), // the composer sheet
    surfaceContainerHighest: Color(0xFFF6ECE6), // fields, placeholders
    outline: Color(0xFFDCC7CC),
    outlineVariant: Color(0xFFEFE0DF), // hairlines
  );

  /// The like heart when filled.
  static const like = Color(0xFFFF3040);
}

abstract final class AppFonts {
  static const body = 'GoogleSans';
  static const heading = 'GoogleSansFlex';
  static const logo = 'MomoSignature';

  /// The bundled fonts are variable; set the axis too so every weight renders
  /// on every Android version.
  static List<FontVariation> weight(int w) => [FontVariation('wght', w.toDouble())];
}

/// Short accessors so widgets read the theme instead of fixed colours.
extension AppStyle on BuildContext {
  ColorScheme get colors => Theme.of(this).colorScheme;
  TextTheme get text => Theme.of(this).textTheme;
  Color get muted => colors.onSurfaceVariant;
  Color get hairline => colors.outlineVariant;
}

ThemeData buildAppTheme(Brightness brightness) {
  final scheme = brightness == Brightness.dark ? AppPalette.dark : AppPalette.light;
  final light = brightness == Brightness.light;
  final base = ThemeData(useMaterial3: true, colorScheme: scheme, fontFamily: AppFonts.body);
  final pill = RoundedRectangleBorder(borderRadius: BorderRadius.circular(12));

  TextStyle heading(double size, int weight, {double height = 1.25}) => TextStyle(
    fontFamily: AppFonts.heading,
    fontSize: size,
    fontWeight: FontWeight.values[weight ~/ 100 - 1],
    fontVariations: AppFonts.weight(weight),
    height: height,
  );

  final text = base.textTheme
      .copyWith(
        // Post text (Google Sans)
        bodyLarge: TextStyle(fontSize: 15.5, height: 1.45, fontVariations: AppFonts.weight(400)),
        // Secondary lines (Google Sans)
        bodyMedium: TextStyle(fontSize: 14, height: 1.4, fontVariations: AppFonts.weight(400)),
        bodySmall: TextStyle(fontSize: 12.5, height: 1.35, fontVariations: AppFonts.weight(400)),
        // Names, titles, headings (Google Sans Flex)
        titleSmall: heading(15.5, 600, height: 1.3),
        titleMedium: heading(17, 600),
        headlineSmall: heading(26, 700, height: 1.2),
        labelLarge: TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.w600,
          fontVariations: AppFonts.weight(600),
        ),
      )
      .apply(bodyColor: scheme.onSurface, displayColor: scheme.onSurface);

  return base.copyWith(
    scaffoldBackgroundColor: scheme.surface,
    textTheme: text,
    splashFactory: NoSplash.splashFactory,
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.surface,
      foregroundColor: scheme.onSurface,
      surfaceTintColor: Colors.transparent,
      scrolledUnderElevation: 0,
      elevation: 0,
      centerTitle: true,
      titleTextStyle: text.titleMedium,
    ),
    dividerTheme: DividerThemeData(color: scheme.outlineVariant, thickness: 0.6, space: 0.6),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: scheme.surfaceContainerHighest,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      hintStyle: TextStyle(color: scheme.onSurfaceVariant),
      labelStyle: TextStyle(color: scheme.onSurfaceVariant),
      floatingLabelStyle: TextStyle(color: scheme.onSurface),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: light ? scheme.primary : scheme.outline, width: light ? 1.5 : 1),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: scheme.primary,
        foregroundColor: scheme.onPrimary,
        disabledBackgroundColor: scheme.onSurface.withValues(alpha: 0.12),
        disabledForegroundColor: scheme.onSurface.withValues(alpha: 0.38),
        minimumSize: const Size(64, 48),
        shape: pill,
        textStyle: text.labelLarge,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: scheme.onSurface,
        side: BorderSide(color: scheme.outline),
        minimumSize: const Size(64, 40),
        shape: pill,
        textStyle: text.labelLarge,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: scheme.onSurface,
        minimumSize: const Size(48, 44),
        textStyle: text.labelLarge?.copyWith(fontWeight: FontWeight.w500),
      ),
    ),
    iconTheme: IconThemeData(color: scheme.onSurface),
    progressIndicatorTheme: ProgressIndicatorThemeData(color: scheme.onSurface),
    tabBarTheme: TabBarThemeData(
      labelColor: scheme.onSurface,
      unselectedLabelColor: scheme.onSurfaceVariant,
      indicatorColor: light ? scheme.primary : scheme.onSurface,
      indicatorSize: TabBarIndicatorSize.tab,
      dividerColor: scheme.outlineVariant,
      labelStyle: text.titleSmall,
      unselectedLabelStyle: text.titleSmall,
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: scheme.surface,
      surfaceTintColor: Colors.transparent,
      showDragHandle: true,
    ),
    dialogTheme: DialogThemeData(backgroundColor: scheme.surface, surfaceTintColor: Colors.transparent),
    popupMenuTheme: PopupMenuThemeData(
      color: scheme.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: scheme.outlineVariant),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: scheme.onSurface,
      contentTextStyle: TextStyle(color: scheme.surface, fontSize: 14),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
  );
}
