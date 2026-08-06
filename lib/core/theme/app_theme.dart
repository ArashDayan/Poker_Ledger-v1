import 'package:flutter/material.dart';

/// A dark, "poker felt" theme designed to be readable under dim bar/casino
/// lighting and fast to tap with a thumb during a live game.
class AppColors {
  static const background = Color(0xFF0B1210); // near-black felt
  static const surface = Color(0xFF141F1B);
  static const surfaceElevated = Color(0xFF1B2A24);
  static const feltGreen = Color(0xFF1F7A4D);
  static const accentGreen = Color(0xFF2ECC71);
  static const gold = Color(0xFFD4AF37);
  static const danger = Color(0xFFE74C3C);
  static const warning = Color(0xFFF39C12);
  static const textPrimary = Color(0xFFF5F7F6);
  static const textSecondary = Color(0xFFA9B8B2);
  static const divider = Color(0xFF243B33);

  // --- Polish tokens -------------------------------------------------
  // Named so every screen reaches for the same values instead of
  // re-inventing near-identical greens and golds inline.

  /// Lighter gold for text/icons that sit on dark felt.
  static const goldLight = Color(0xFFF2D17A);

  /// Deep felt used for hero gradients.
  static const feltDeep = Color(0xFF17402F);

  /// Standard hero gradient (top-left to bottom-right).
  static const heroGradient = LinearGradient(
    colors: [feltDeep, surfaceElevated],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  /// Standard elevation shadow for raised cards.
  static List<BoxShadow> get cardShadow => [
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.28),
          blurRadius: 14,
          offset: const Offset(0, 5),
        ),
      ];
}

/// Shared spacing scale. Using named steps instead of scattered magic
/// numbers is what makes the app feel consistent screen to screen.
class AppSpacing {
  static const xs = 4.0;
  static const sm = 8.0;
  static const md = 12.0;
  static const lg = 16.0;
  static const xl = 24.0;
  static const xxl = 32.0;
}

/// Shared corner radii.
class AppRadius {
  static const sm = 10.0;
  static const md = 14.0;
  static const lg = 18.0;
  static const pill = 999.0;
}

class AppTheme {
  static ThemeData dark() {
    final base = ThemeData.dark(useMaterial3: true);
    return base.copyWith(
      scaffoldBackgroundColor: AppColors.background,
      colorScheme: base.colorScheme.copyWith(
        primary: AppColors.accentGreen,
        secondary: AppColors.gold,
        surface: AppColors.surface,
        error: AppColors.danger,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: AppColors.background,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        foregroundColor: AppColors.textPrimary,
        titleTextStyle: TextStyle(
          fontSize: 17,
          fontWeight: FontWeight.bold,
          letterSpacing: -0.2,
          color: AppColors.textPrimary,
        ),
      ),
      cardTheme: CardThemeData(
        color: AppColors.surfaceElevated,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: AppColors.divider),
        ),
        margin: const EdgeInsets.symmetric(vertical: 6, horizontal: 0),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: AppColors.accentGreen,
          foregroundColor: Colors.black,
          minimumSize: const Size.fromHeight(52),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          textStyle: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: AppColors.accentGreen,
          side: const BorderSide(color: AppColors.accentGreen),
          minimumSize: const Size.fromHeight(52),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: AppColors.surface,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppColors.divider),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppColors.divider),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppColors.accentGreen, width: 2),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      ),
      // Typography: a deliberate hierarchy rather than Flutter's
      // defaults. Headlines are tightened (negative tracking reads as
      // premium at large sizes), labels are widened, and body text is
      // given a comfortable line height for reading under bad lighting.
      textTheme: base.textTheme
          .apply(
            bodyColor: AppColors.textPrimary,
            displayColor: AppColors.textPrimary,
          )
          .copyWith(
            headlineLarge: const TextStyle(
                fontSize: 30, fontWeight: FontWeight.w800, letterSpacing: -0.6),
            headlineMedium: const TextStyle(
                fontSize: 24, fontWeight: FontWeight.bold, letterSpacing: -0.4),
            titleLarge: const TextStyle(
                fontSize: 18, fontWeight: FontWeight.bold, letterSpacing: -0.2),
            titleMedium: const TextStyle(
                fontSize: 15, fontWeight: FontWeight.w600),
            bodyLarge: const TextStyle(fontSize: 14.5, height: 1.35),
            bodyMedium: const TextStyle(fontSize: 13.5, height: 1.35),
            bodySmall: const TextStyle(
                fontSize: 11.5, height: 1.3, color: AppColors.textSecondary),
            labelLarge: const TextStyle(
                fontSize: 13, fontWeight: FontWeight.bold, letterSpacing: 0.3),
            labelSmall: const TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.bold,
                letterSpacing: 1.1,
                color: AppColors.textSecondary),
          ),
      dividerTheme: const DividerThemeData(
          color: AppColors.divider, thickness: 1, space: 1),
      // Chips, dialogs, sheets and the nav bar were previously falling
      // back to Material defaults, which read as grey/purple against the
      // felt palette. Theming them centrally is most of what makes the
      // app feel like one product.
      chipTheme: ChipThemeData(
        backgroundColor: AppColors.surface,
        selectedColor: AppColors.accentGreen.withValues(alpha: 0.18),
        side: const BorderSide(color: AppColors.divider),
        labelStyle: const TextStyle(fontSize: 12, color: AppColors.textPrimary),
        secondaryLabelStyle:
            const TextStyle(fontSize: 12, color: AppColors.accentGreen),
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.sm)),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: AppColors.surfaceElevated,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.lg),
          side: BorderSide(color: AppColors.gold.withValues(alpha: 0.22)),
        ),
        titleTextStyle: const TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.bold,
            color: AppColors.textPrimary),
        contentTextStyle: const TextStyle(
            fontSize: 13.5, height: 1.35, color: AppColors.textPrimary),
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: AppColors.surfaceElevated,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.lg)),
        ),
        showDragHandle: true,
        dragHandleColor: AppColors.divider,
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: AppColors.surfaceElevated,
        surfaceTintColor: Colors.transparent,
        indicatorColor: AppColors.accentGreen.withValues(alpha: 0.18),
        elevation: 0,
        height: 66,
        labelTextStyle: WidgetStateProperty.resolveWith(
          (states) => TextStyle(
            fontSize: 11,
            fontWeight: states.contains(WidgetState.selected)
                ? FontWeight.bold
                : FontWeight.normal,
            color: states.contains(WidgetState.selected)
                ? AppColors.accentGreen
                : AppColors.textSecondary,
          ),
        ),
        iconTheme: WidgetStateProperty.resolveWith(
          (states) => IconThemeData(
            size: 22,
            color: states.contains(WidgetState.selected)
                ? AppColors.accentGreen
                : AppColors.textSecondary,
          ),
        ),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          side: const WidgetStatePropertyAll(
              BorderSide(color: AppColors.divider)),
          shape: WidgetStatePropertyAll(RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppRadius.md))),
          backgroundColor: WidgetStateProperty.resolveWith((states) =>
              states.contains(WidgetState.selected)
                  ? AppColors.accentGreen.withValues(alpha: 0.18)
                  : AppColors.surface),
          foregroundColor: WidgetStateProperty.resolveWith((states) =>
              states.contains(WidgetState.selected)
                  ? AppColors.accentGreen
                  : AppColors.textSecondary),
        ),
      ),
      listTileTheme: const ListTileThemeData(
        iconColor: AppColors.textSecondary,
        textColor: AppColors.textPrimary,
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((states) =>
            states.contains(WidgetState.selected)
                ? AppColors.accentGreen
                : AppColors.textSecondary),
        trackColor: WidgetStateProperty.resolveWith((states) =>
            states.contains(WidgetState.selected)
                ? AppColors.accentGreen.withValues(alpha: 0.35)
                : AppColors.divider),
      ),
      sliderTheme: SliderThemeData(
        activeTrackColor: AppColors.gold,
        inactiveTrackColor: AppColors.divider,
        thumbColor: AppColors.gold,
        overlayColor: AppColors.gold.withValues(alpha: 0.15),
        valueIndicatorColor: AppColors.surfaceElevated,
      ),
      progressIndicatorTheme: const ProgressIndicatorThemeData(
        color: AppColors.accentGreen,
        linearTrackColor: AppColors.divider,
      ),
      floatingActionButtonTheme: const FloatingActionButtonThemeData(
        backgroundColor: AppColors.accentGreen,
        foregroundColor: Colors.black,
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: AppColors.background.withValues(alpha: 0.95),
          borderRadius: BorderRadius.circular(AppRadius.sm),
          border: Border.all(color: AppColors.divider),
        ),
        textStyle: const TextStyle(fontSize: 11.5, color: AppColors.textPrimary),
      ),
      snackBarTheme: const SnackBarThemeData(
        backgroundColor: AppColors.surfaceElevated,
        contentTextStyle: TextStyle(color: AppColors.textPrimary),
        behavior: SnackBarBehavior.floating,
      ),
      // Subtle, premium-feeling transitions instead of the platform default
      // abrupt slide — used across every screen since navigation is driven
      // by MaterialPageRoute throughout the app.
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: _FadeThroughTransitionsBuilder(),
          TargetPlatform.iOS: _FadeThroughTransitionsBuilder(),
          TargetPlatform.macOS: _FadeThroughTransitionsBuilder(),
          TargetPlatform.windows: _FadeThroughTransitionsBuilder(),
          TargetPlatform.linux: _FadeThroughTransitionsBuilder(),
        },
      ),
    );
  }
}

/// A gentle fade + slight scale-up, rather than a hard slide/cut — reads
/// as calm and premium rather than flashy, and stays cheap to render on
/// older tablets/phones used tableside.
class _FadeThroughTransitionsBuilder extends PageTransitionsBuilder {
  const _FadeThroughTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final curved = CurvedAnimation(parent: animation, curve: Curves.easeOut);
    return FadeTransition(
      opacity: curved,
      child: ScaleTransition(
        scale: Tween(begin: 0.98, end: 1.0).animate(curved),
        child: child,
      ),
    );
  }
}
