import 'package:flutter/material.dart';

/// Hipersign design tokens, the same as the Hipersign mobile app:
/// navy #0A3C6E, white, blue #1783C1, charcoal #333333. Change colours here only.
class HsColors {
  static const navy = Color(0xFF0A3C6E);
  static const blue = Color(0xFF1783C1);
  static const charcoal = Color(0xFF333333);

  static const background = Color(0xFFFFFFFF);
  static const card = Color(0xFFF2F6FA); // soft blue-grey panel on white
  static const cardHigh = Color(0xFFE3ECF5);
  static const border = Color(0xFFDDE6EF);
  static const accent = navy;
  static const onAccent = Color(0xFFFFFFFF);
  static const textPrimary = charcoal;
  static const textSecondary = Color(0xFF6B7785);
  static const danger = Color(0xFFC62828);
  static const dangerBg = Color(0xFFFDECEC);
  static const warning = Color(0xFFB26A00);
  static const warningBg = Color(0xFFFFF4DC);

  // HiperTracker states
  static const onDuty = Color(0xFF1E8E3E); // checked in / tracking
  static const onDutyBg = Color(0xFFCDEED6);
  static const offDutyBg = Color(0xFFDADFE5);
  static const checkOut = Color(0xFFC62828);
}

ThemeData buildTheme() {
  final scheme = ColorScheme.fromSeed(seedColor: HsColors.navy, brightness: Brightness.light).copyWith(
    primary: HsColors.navy,
    onPrimary: HsColors.onAccent,
    secondary: HsColors.blue,
    onSecondary: Colors.white,
    surface: HsColors.background,
    onSurface: HsColors.textPrimary,
    onSurfaceVariant: HsColors.textSecondary,
    surfaceContainerHighest: HsColors.card,
    outline: HsColors.border,
    outlineVariant: HsColors.border,
    error: HsColors.danger,
    errorContainer: HsColors.dangerBg,
    onErrorContainer: HsColors.danger,
    surfaceTint: Colors.transparent,
  );

  final base = ThemeData(useMaterial3: true, colorScheme: scheme, brightness: Brightness.light);
  return base.copyWith(
    scaffoldBackgroundColor: HsColors.background,
    textTheme: base.textTheme.apply(bodyColor: HsColors.textPrimary, displayColor: HsColors.textPrimary),
    appBarTheme: const AppBarTheme(
      backgroundColor: HsColors.background,
      foregroundColor: HsColors.navy,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 1,
      shadowColor: Color(0x1A0A3C6E),
      centerTitle: false,
      titleTextStyle: TextStyle(color: HsColors.navy, fontSize: 20, fontWeight: FontWeight.w700),
    ),
    cardTheme: CardThemeData(
      color: HsColors.card,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
    ),
    dividerTheme: const DividerThemeData(color: HsColors.border, space: 1),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: HsColors.card,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
      enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: HsColors.border)),
      focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: HsColors.blue, width: 1.6)),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: HsColors.navy,
        foregroundColor: HsColors.onAccent,
        minimumSize: const Size(48, 48),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: HsColors.navy,
        side: const BorderSide(color: HsColors.border),
        minimumSize: const Size(48, 48),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
    ),
    textButtonTheme: TextButtonThemeData(style: TextButton.styleFrom(foregroundColor: HsColors.blue)),
    progressIndicatorTheme: const ProgressIndicatorThemeData(color: HsColors.blue, linearTrackColor: HsColors.cardHigh),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? Colors.white : null),
      trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? HsColors.blue : null),
    ),
    dialogTheme: const DialogThemeData(backgroundColor: HsColors.background, surfaceTintColor: Colors.transparent),
    bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: HsColors.background, surfaceTintColor: Colors.transparent),
    bottomAppBarTheme: const BottomAppBarThemeData(
        color: HsColors.background, surfaceTintColor: Colors.transparent, elevation: 8, shadowColor: Color(0x330A3C6E)),
    snackBarTheme: const SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: HsColors.charcoal,
      contentTextStyle: TextStyle(color: Colors.white),
      actionTextColor: Color(0xFF8CCBF0),
    ),
    listTileTheme: const ListTileThemeData(iconColor: HsColors.navy, textColor: HsColors.textPrimary),
  );
}

/// Rounded soft panel used for every card in the app (Hipersign style).
class HsPanel extends StatelessWidget {
  const HsPanel({super.key, required this.child, this.color, this.padding = const EdgeInsets.all(16)});

  final Widget child;
  final Color? color;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: padding,
      decoration: BoxDecoration(color: color ?? HsColors.card, borderRadius: BorderRadius.circular(18)),
      child: child,
    );
  }
}

/// Info / error strip, as on the Hipersign sign-in screen.
class HsBanner extends StatelessWidget {
  const HsBanner({super.key, required this.text, this.error = false});
  final String text;
  final bool error;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: error ? HsColors.dangerBg : HsColors.warningBg,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(text, style: TextStyle(color: error ? HsColors.danger : HsColors.textPrimary)),
    );
  }
}

/// Settings-style row used on the More screen.
class HsTile extends StatelessWidget {
  const HsTile({super.key, required this.icon, required this.title, required this.onTap, this.subtitle, this.danger = false});

  final IconData icon;
  final String title;
  final String? subtitle;
  final VoidCallback onTap;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        tileColor: HsColors.card,
        leading: Icon(icon, color: danger ? HsColors.danger : HsColors.accent),
        title: Text(title, style: TextStyle(color: danger ? HsColors.danger : null)),
        subtitle: subtitle == null ? null : Text(subtitle!, style: const TextStyle(color: HsColors.textSecondary)),
        trailing: danger ? null : const Icon(Icons.chevron_right),
        onTap: onTap,
      ),
    );
  }
}
