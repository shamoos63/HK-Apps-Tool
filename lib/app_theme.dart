import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Light: clean white surfaces with blue accents.
/// Dark: near-black surfaces with neon cyan / magenta / violet accents and a soft glow.

const _lightBlue = Color(0xFF1665FF);

ColorScheme _lightScheme() {
  final base = ColorScheme.fromSeed(seedColor: _lightBlue, brightness: Brightness.light);
  return base.copyWith(
    primary: _lightBlue,
    onPrimary: Colors.white,
    primaryContainer: const Color(0xFFDCE8FF),
    onPrimaryContainer: const Color(0xFF002A78),
    secondary: const Color(0xFF0EA5E9),
    secondaryContainer: const Color(0xFFE0F2FE),
    onSecondaryContainer: const Color(0xFF07466A),
    tertiary: const Color(0xFF6366F1),
    tertiaryContainer: const Color(0xFFE6E7FF),
    onTertiaryContainer: const Color(0xFF26277A),
    surface: Colors.white,
    onSurface: const Color(0xFF0F1B33),
    onSurfaceVariant: const Color(0xFF5A6B8C),
    surfaceContainerLowest: Colors.white,
    surfaceContainerLow: const Color(0xFFF7FAFF),
    surfaceContainer: const Color(0xFFF1F6FF),
    surfaceContainerHigh: const Color(0xFFEAF1FE),
    surfaceContainerHighest: const Color(0xFFE2EBFC),
    outline: const Color(0xFF8A9BBD),
    outlineVariant: const Color(0xFFD6E2F7),
  );
}

ColorScheme _darkScheme() => const ColorScheme(
      brightness: Brightness.dark,
      primary: Color(0xFF00E5FF), // neon cyan
      onPrimary: Color(0xFF00161A),
      primaryContainer: Color(0xFF00343B),
      onPrimaryContainer: Color(0xFFA6F7FF),
      secondary: Color(0xFFFF3DF2), // neon magenta
      onSecondary: Color(0xFF1F0020),
      secondaryContainer: Color(0xFF3A0B3A),
      onSecondaryContainer: Color(0xFFFFB8FA),
      tertiary: Color(0xFFA97BFF), // neon violet
      onTertiary: Color(0xFF14002E),
      tertiaryContainer: Color(0xFF2A1752),
      onTertiaryContainer: Color(0xFFDCC8FF),
      error: Color(0xFFFF4D6D),
      onError: Color(0xFF2B0008),
      errorContainer: Color(0xFF3D0D17),
      onErrorContainer: Color(0xFFFFB3C1),
      surface: Color(0xFF0B0E13),
      onSurface: Color(0xFFE8F1FF),
      onSurfaceVariant: Color(0xFF8E9BB3),
      surfaceContainerLowest: Color(0xFF06080B),
      surfaceContainerLow: Color(0xFF0E1218),
      surfaceContainer: Color(0xFF12171F),
      surfaceContainerHigh: Color(0xFF171D27),
      surfaceContainerHighest: Color(0xFF1D2430),
      outline: Color(0xFF4A5568),
      outlineVariant: Color(0xFF1E2633),
      shadow: Colors.black,
      scrim: Colors.black,
      inverseSurface: Color(0xFFE8F1FF),
      onInverseSurface: Color(0xFF0B0E13),
      inversePrimary: Color(0xFF006876),
    );

ThemeData buildAppTheme() => _build(_lightScheme(), background: const Color(0xFFF2F6FD));

ThemeData buildAppDarkTheme() => _build(_darkScheme(), background: const Color(0xFF050608));

ThemeData _build(ColorScheme scheme, {required Color background}) {
  final dark = scheme.brightness == Brightness.dark;
  final radius = BorderRadius.circular(14);
  // Neon glow under primary buttons in dark mode, a soft blue shadow in light mode.
  final glow = dark ? scheme.primary.withValues(alpha: 0.55) : scheme.primary.withValues(alpha: 0.25);

  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: background,
    canvasColor: background,
    visualDensity: VisualDensity.standard,
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: dark ? scheme.surfaceContainerLowest : scheme.surface,
      elevation: 0,
      labelType: NavigationRailLabelType.all,
      minWidth: 88,
      indicatorColor: dark ? scheme.primary.withValues(alpha: 0.16) : scheme.primaryContainer,
      indicatorShape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: dark ? BorderSide(color: scheme.primary.withValues(alpha: 0.55)) : BorderSide.none,
      ),
      selectedIconTheme: IconThemeData(color: dark ? scheme.primary : scheme.onPrimaryContainer),
      unselectedIconTheme: IconThemeData(color: scheme.onSurfaceVariant),
      selectedLabelTextStyle: TextStyle(color: scheme.primary, fontWeight: FontWeight.w700, fontSize: 12),
      unselectedLabelTextStyle: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
          color: dark ? scheme.primary.withValues(alpha: 0.10) : scheme.outlineVariant,
        ),
      ),
      color: scheme.surface,
      margin: EdgeInsets.zero,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: dark ? scheme.surfaceContainerLow : scheme.surface,
      border: OutlineInputBorder(borderRadius: radius),
      enabledBorder: OutlineInputBorder(
        borderRadius: radius,
        borderSide: BorderSide(color: dark ? scheme.outlineVariant : scheme.outlineVariant),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: radius,
        borderSide: BorderSide(color: scheme.primary, width: 1.6),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: ButtonStyle(
        padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 18, vertical: 12)),
        shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: radius)),
        shadowColor: WidgetStatePropertyAll(glow),
        elevation: WidgetStateProperty.resolveWith((s) {
          if (s.contains(WidgetState.disabled)) return 0;
          if (s.contains(WidgetState.hovered)) return dark ? 10 : 4;
          return dark ? 6 : 2;
        }),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        shape: RoundedRectangleBorder(borderRadius: radius),
        side: BorderSide(color: dark ? scheme.primary.withValues(alpha: 0.5) : scheme.outline),
      ),
    ),
    chipTheme: ChipThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      side: BorderSide(color: dark ? scheme.primary.withValues(alpha: 0.35) : scheme.outlineVariant),
      selectedColor: dark ? scheme.primary.withValues(alpha: 0.18) : scheme.primaryContainer,
      checkmarkColor: dark ? scheme.primary : scheme.onPrimaryContainer,
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? (dark ? scheme.primary : Colors.white) : null,
      ),
      trackColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected)
            ? (dark ? scheme.primary.withValues(alpha: 0.35) : scheme.primary)
            : null,
      ),
    ),
    snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: scheme.primary,
      linearTrackColor: scheme.primary.withValues(alpha: dark ? 0.15 : 0.18),
      // ignore: deprecated_member_use
      year2023: false,
    ),
    appBarTheme: AppBarTheme(
      centerTitle: false,
      elevation: 0,
      scrolledUnderElevation: 0,
      backgroundColor: background,
      titleTextStyle: TextStyle(
        color: scheme.onSurface,
        fontSize: 20,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.2,
      ),
    ),
    dividerTheme: DividerThemeData(color: scheme.outlineVariant),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: dark ? scheme.surfaceContainerHighest : const Color(0xFF0F1B33),
        borderRadius: BorderRadius.circular(8),
        border: dark ? Border.all(color: scheme.primary.withValues(alpha: 0.4)) : null,
      ),
      textStyle: TextStyle(color: dark ? scheme.onSurface : Colors.white, fontSize: 12),
    ),
  );
}

/// Success colours that work in both themes (Material has no built-in "success" role).
extension AppStatusColors on ColorScheme {
  Color get success => brightness == Brightness.light ? const Color(0xFF0F9D58) : const Color(0xFF39FF88);
  Color get successContainer =>
      brightness == Brightness.light ? const Color(0xFFDDF7E8) : const Color(0xFF0B2E1B);
}

/// The user's Light / Dark / System choice, persisted across launches.
class ThemeController extends ValueNotifier<ThemeMode> {
  ThemeController._() : super(ThemeMode.system);

  static final ThemeController instance = ThemeController._();
  static const _key = 'theme_mode';

  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      value = ThemeMode.values.firstWhere((m) => m.name == prefs.getString(_key), orElse: () => ThemeMode.system);
    } catch (_) {}
  }

  Future<void> set(ThemeMode mode) async {
    value = mode;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_key, mode.name);
    } catch (_) {}
  }

  /// Flip between light and dark based on what is showing now.
  Future<void> toggle(Brightness current) =>
      set(current == Brightness.dark ? ThemeMode.light : ThemeMode.dark);
}
