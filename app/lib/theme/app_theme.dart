import 'package:flutter/material.dart';

import 'colors.dart';
import 'palette.dart';
import 'spacing.dart';
import 'typography.dart';

/// Thèmes de l'app. Le clair est celui des maquettes ; le sombre en reprend
/// l'orange et le vert sur le bleu nuit de l'encre.
abstract final class MpTheme {
  static final ThemeData light = _build(_lightScheme, MpColors.light);
  static final ThemeData dark = _build(_darkScheme, MpColors.dark);

  static const _lightScheme = ColorScheme(
    brightness: Brightness.light,
    primary: MpPalette.orange,
    onPrimary: MpPalette.ink,
    primaryContainer: MpPalette.orangeSoft,
    onPrimaryContainer: MpPalette.ink,
    secondary: MpPalette.muted,
    onSecondary: MpPalette.card,
    secondaryContainer: MpPalette.segment,
    onSecondaryContainer: MpPalette.ink,
    error: MpPalette.redText,
    onError: MpPalette.card,
    surface: MpPalette.page,
    onSurface: MpPalette.ink,
    onSurfaceVariant: MpPalette.muted,
    surfaceContainerLowest: MpPalette.card,
    surfaceContainerLow: MpPalette.card,
    surfaceContainer: MpPalette.card,
    surfaceContainerHigh: MpPalette.segment,
    surfaceContainerHighest: MpPalette.bubble,
    outline: MpPalette.faint,
    outlineVariant: MpPalette.line,
    inverseSurface: MpPalette.ink,
    onInverseSurface: MpPalette.card,
    inversePrimary: MpPalette.orange,
    shadow: MpPalette.ink,
    surfaceTint: Colors.transparent,
  );

  static const _darkScheme = ColorScheme(
    brightness: Brightness.dark,
    primary: MpPalette.orange,
    onPrimary: MpPalette.ink,
    primaryContainer: Color(0xFF3A2A12),
    onPrimaryContainer: MpPalette.orange,
    secondary: MpPalette.faint,
    onSecondary: MpPalette.night,
    secondaryContainer: MpPalette.nightRaised,
    onSecondaryContainer: MpPalette.snow,
    error: MpPalette.redNight,
    onError: MpPalette.night,
    surface: MpPalette.night,
    onSurface: MpPalette.snow,
    onSurfaceVariant: MpPalette.faint,
    surfaceContainerLowest: MpPalette.nightCard,
    surfaceContainerLow: MpPalette.nightCard,
    surfaceContainer: MpPalette.nightCard,
    surfaceContainerHigh: MpPalette.nightRaised,
    surfaceContainerHighest: MpPalette.nightRaised,
    outline: MpPalette.faint,
    outlineVariant: MpPalette.nightLine,
    inverseSurface: MpPalette.snow,
    onInverseSurface: MpPalette.night,
    inversePrimary: MpPalette.orangeText,
    shadow: Colors.black,
    surfaceTint: Colors.transparent,
  );

  static ThemeData _build(ColorScheme scheme, MpColors mp) {
    final text = MpTypography.textTheme.apply(
      fontFamily: MpFonts.text,
      bodyColor: scheme.onSurface,
      displayColor: scheme.onSurface,
    );
    const controlShape = RoundedRectangleBorder(borderRadius: MpRadius.control);
    const controlSize = Size(64, 52);

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      fontFamily: MpFonts.text,
      textTheme: text,
      scaffoldBackgroundColor: scheme.surface,
      extensions: [mp],
      appBarTheme: AppBarThemeData(
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: text.titleLarge,
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: scheme.surfaceContainerLowest,
        indicatorColor: Colors.transparent,
        height: 72,
        labelTextStyle: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? text.labelMedium!.copyWith(
                  color: mp.accentText,
                  fontWeight: FontWeight.w700,
                )
              : text.labelMedium!.copyWith(color: mp.textMuted),
        ),
        iconTheme: WidgetStateProperty.resolveWith(
          (states) => IconThemeData(
            color: states.contains(WidgetState.selected)
                ? scheme.primary
                : mp.textMuted,
          ),
        ),
      ),
      cardTheme: CardThemeData(
        color: scheme.surfaceContainer,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: MpRadius.card,
          side: BorderSide(color: scheme.outlineVariant),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: controlSize,
          shape: controlShape,
          textStyle: text.labelLarge,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: controlSize,
          shape: controlShape,
          textStyle: text.labelLarge,
          backgroundColor: scheme.surfaceContainerLowest,
          foregroundColor: scheme.onSurface,
          side: BorderSide(color: scheme.outlineVariant),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          shape: controlShape,
          textStyle: text.labelLarge,
          foregroundColor: mp.accentText,
        ),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: scheme.primary,
        foregroundColor: scheme.onPrimary,
        elevation: 0,
        focusElevation: 0,
        hoverElevation: 0,
        highlightElevation: 0,
        shape: const CircleBorder(),
      ),
      drawerTheme: DrawerThemeData(
        backgroundColor: scheme.surfaceContainerLowest,
      ),
      listTileTheme: ListTileThemeData(
        iconColor: mp.textMuted,
        contentPadding: const EdgeInsets.symmetric(horizontal: MpSpace.gutter),
      ),
      dividerTheme: DividerThemeData(
        color: scheme.outlineVariant,
        thickness: 1,
        space: 1,
      ),
      inputDecorationTheme: InputDecorationThemeData(
        filled: true,
        fillColor: scheme.surfaceContainerLowest,
        border: OutlineInputBorder(
          borderRadius: MpRadius.control,
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: MpRadius.control,
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: MpRadius.control,
          borderSide: BorderSide(color: scheme.primary, width: 2),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: scheme.surfaceContainerLowest,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(MpRadius.xl)),
        ),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: scheme.surfaceContainerLowest,
        showDragHandle: true,
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: scheme.inverseSurface,
        contentTextStyle: text.bodyMedium!.copyWith(
          color: scheme.onInverseSurface,
        ),
        shape: controlShape,
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(color: scheme.primary),
    );
  }
}
