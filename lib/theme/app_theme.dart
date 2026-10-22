// CupertinoPageTransitionsBuilder moved out of material.dart in Flutter 3.44.
// Imported with `show` so none of cupertino's other names collide with material's.
import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Design tokens for the app's light "liquid glass" look.
///
/// Everything visual should read from here rather than hardcoding colours, so
/// the whole app can be retuned from one place.
abstract final class AppColors {
  // Base surfaces. The app sits on near-white, not pure white, so that the
  // genuinely white glass panels still read as raised above the background.
  static const canvas = Color(0xFFF6F7FB);
  static const glassTint = Color(0xFFFFFFFF);

  // Accents used by the ambient background blobs and primary actions.
  static const primary = Color(0xFF4C6FFF);
  static const violet = Color(0xFF8B5CF6);
  static const teal = Color(0xFF2DD4BF);

  // Text
  static const ink = Color(0xFF0F172A);
  static const inkMuted = Color(0xFF64748B);
  static const inkFaint = Color(0xFF94A3B8);

  // Semantics
  static const success = Color(0xFF10B981);
  static const warning = Color(0xFFF59E0B);
  static const danger = Color(0xFFEF4444);

  static const hairline = Color(0x14000000);
}

/// Corner radii. Glass reads as liquid when the geometry is generously rounded
/// and consistent, so these are deliberately few.
abstract final class AppRadius {
  static const sm = 12.0;
  static const md = 18.0;
  static const lg = 26.0;
  static const xl = 34.0;
  static const pill = 999.0;
}

abstract final class AppSpacing {
  static const xs = 4.0;
  static const sm = 8.0;
  static const md = 16.0;
  static const lg = 24.0;
  static const xl = 32.0;
}

/// Motion. A single easing curve across the app is what makes it feel "smooth"
/// rather than a collection of separately animated widgets.
abstract final class AppMotion {
  static const fast = Duration(milliseconds: 180);
  static const normal = Duration(milliseconds: 280);
  static const slow = Duration(milliseconds: 460);
  static const curve = Curves.easeOutCubic;
  static const emphasized = Cubic(0.2, 0.0, 0.0, 1.0);
}

/// Soft, layered shadows. A single large soft shadow plus a tight contact
/// shadow reads much closer to real glass than one medium shadow.
abstract final class AppShadows {
  static const card = <BoxShadow>[
    BoxShadow(
      color: Color(0x0F1E293B),
      blurRadius: 32,
      offset: Offset(0, 12),
      spreadRadius: -8,
    ),
    BoxShadow(
      color: Color(0x0A1E293B),
      blurRadius: 6,
      offset: Offset(0, 2),
    ),
  ];

  static const raised = <BoxShadow>[
    BoxShadow(
      color: Color(0x1A1E293B),
      blurRadius: 48,
      offset: Offset(0, 20),
      spreadRadius: -12,
    ),
    BoxShadow(
      color: Color(0x0D1E293B),
      blurRadius: 8,
      offset: Offset(0, 3),
    ),
  ];
}

abstract final class AppTheme {
  static const overlayStyle = SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.dark,
    statusBarBrightness: Brightness.light,
    systemNavigationBarColor: AppColors.canvas,
    systemNavigationBarIconBrightness: Brightness.dark,
  );

  static ThemeData light() {
    final scheme = ColorScheme.fromSeed(
      seedColor: AppColors.primary,
      brightness: Brightness.light,
    ).copyWith(
      surface: AppColors.canvas,
      onSurface: AppColors.ink,
      primary: AppColors.primary,
    );

    final base = ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: AppColors.canvas,
      splashFactory: InkSparkle.splashFactory,
    );

    return base.copyWith(
      textTheme: _textTheme(base.textTheme),
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: true,
        systemOverlayStyle: overlayStyle,
        iconTheme: IconThemeData(color: AppColors.ink),
        titleTextStyle: TextStyle(
          color: AppColors.ink,
          fontSize: 18,
          fontWeight: FontWeight.w600,
          letterSpacing: -0.2,
        ),
      ),
      // Page transitions are part of "smooth": the default Android transition
      // is abrupt next to this visual language.
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: FadeForwardsPageTransitionsBuilder(),
          TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
        },
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: AppColors.ink,
          foregroundColor: Colors.white,
          minimumSize: const Size.fromHeight(56),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.md),
          ),
          textStyle: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            letterSpacing: -0.1,
          ),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Colors.white.withValues(alpha: 0.72),
        contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 18),
        hintStyle: const TextStyle(color: AppColors.inkFaint),
        labelStyle: const TextStyle(color: AppColors.inkMuted),
        prefixIconColor: AppColors.inkMuted,
        suffixIconColor: AppColors.inkMuted,
        border: _inputBorder(AppColors.hairline),
        enabledBorder: _inputBorder(AppColors.hairline),
        focusedBorder: _inputBorder(AppColors.primary, width: 1.6),
        errorBorder: _inputBorder(AppColors.danger),
        focusedErrorBorder: _inputBorder(AppColors.danger, width: 1.6),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: AppColors.ink,
        contentTextStyle: const TextStyle(color: Colors.white, fontSize: 14),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.sm),
        ),
      ),
      dividerTheme: const DividerThemeData(
        color: AppColors.hairline,
        thickness: 1,
        space: 1,
      ),
    );
  }

  static OutlineInputBorder _inputBorder(Color color, {double width = 1}) {
    return OutlineInputBorder(
      borderRadius: BorderRadius.circular(AppRadius.md),
      borderSide: BorderSide(color: color, width: width),
    );
  }

  static TextTheme _textTheme(TextTheme base) {
    return base
        .apply(bodyColor: AppColors.ink, displayColor: AppColors.ink)
        .copyWith(
          displaySmall: base.displaySmall?.copyWith(
            fontWeight: FontWeight.w700,
            letterSpacing: -1.0,
          ),
          headlineMedium: base.headlineMedium?.copyWith(
            fontWeight: FontWeight.w700,
            letterSpacing: -0.8,
          ),
          headlineSmall: base.headlineSmall?.copyWith(
            fontWeight: FontWeight.w700,
            letterSpacing: -0.6,
          ),
          titleLarge: base.titleLarge?.copyWith(
            fontWeight: FontWeight.w600,
            letterSpacing: -0.4,
          ),
          titleMedium: base.titleMedium?.copyWith(
            fontWeight: FontWeight.w600,
            letterSpacing: -0.2,
          ),
          bodyMedium: base.bodyMedium?.copyWith(
            color: AppColors.inkMuted,
            height: 1.45,
          ),
          labelLarge: base.labelLarge?.copyWith(
            fontWeight: FontWeight.w600,
            letterSpacing: -0.1,
          ),
        );
  }
}
