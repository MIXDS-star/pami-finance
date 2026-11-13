/// Pami visual system: emerald/teal brand, warm neutrals, discreet accents.
/// Status is never conveyed by color alone: amounts carry signs and labels,
/// alerts carry icons and text.
library;

import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/material.dart';

class PamiTokens {
  static const radiusS = 10.0;
  static const radiusM = 16.0;
  static const radiusL = 24.0;
  static const space1 = 4.0;
  static const space2 = 8.0;
  static const space3 = 12.0;
  static const space4 = 16.0;
  static const space5 = 24.0;
  static const space6 = 32.0;
  static const motionFast = Duration(milliseconds: 150);
  static const motion = Duration(milliseconds: 250);

  static const tabular = [FontFeature.tabularFigures()];
}

@immutable
class PamiColors extends ThemeExtension<PamiColors> {
  const PamiColors({
    required this.positive,
    required this.negative,
    required this.warning,
    required this.info,
    required this.muted,
    required this.surfaceSoft,
    required this.border,
    required this.brandSoft,
  });

  final Color positive;
  final Color negative;
  final Color warning;
  final Color info;
  final Color muted;
  final Color surfaceSoft;
  final Color border;
  final Color brandSoft;

  static const light = PamiColors(
    positive: Color(0xFF1E7A4F),
    negative: Color(0xFFB4442F),
    warning: Color(0xFF9A6A00),
    info: Color(0xFF2F6690),
    muted: Color(0xFF6B6760),
    surfaceSoft: Color(0xFFF3F0EA),
    border: Color(0xFFE4DFD6),
    brandSoft: Color(0xFFE1F2EC),
  );

  static const dark = PamiColors(
    positive: Color(0xFF6FCF9F),
    negative: Color(0xFFF08C76),
    warning: Color(0xFFE8C062),
    info: Color(0xFF8DBDE6),
    muted: Color(0xFFA8A39A),
    surfaceSoft: Color(0xFF232624),
    border: Color(0xFF343835),
    brandSoft: Color(0xFF16332B),
  );

  @override
  PamiColors copyWith({Color? positive, Color? negative, Color? warning, Color? info, Color? muted,
          Color? surfaceSoft, Color? border, Color? brandSoft}) =>
      PamiColors(
        positive: positive ?? this.positive,
        negative: negative ?? this.negative,
        warning: warning ?? this.warning,
        info: info ?? this.info,
        muted: muted ?? this.muted,
        surfaceSoft: surfaceSoft ?? this.surfaceSoft,
        border: border ?? this.border,
        brandSoft: brandSoft ?? this.brandSoft,
      );

  @override
  PamiColors lerp(PamiColors? other, double t) {
    if (other == null) return this;
    return PamiColors(
      positive: Color.lerp(positive, other.positive, t)!,
      negative: Color.lerp(negative, other.negative, t)!,
      warning: Color.lerp(warning, other.warning, t)!,
      info: Color.lerp(info, other.info, t)!,
      muted: Color.lerp(muted, other.muted, t)!,
      surfaceSoft: Color.lerp(surfaceSoft, other.surfaceSoft, t)!,
      border: Color.lerp(border, other.border, t)!,
      brandSoft: Color.lerp(brandSoft, other.brandSoft, t)!,
    );
  }
}

extension PamiThemeX on BuildContext {
  PamiColors get pami => Theme.of(this).extension<PamiColors>()!;
  ColorScheme get colors => Theme.of(this).colorScheme;
  TextTheme get text => Theme.of(this).textTheme;
}

const _brand = Color(0xFF0E7C66);

ThemeData buildTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final scheme = ColorScheme.fromSeed(
    seedColor: _brand,
    brightness: brightness,
    primary: dark ? const Color(0xFF5CC8A8) : _brand,
    onPrimary: dark ? const Color(0xFF00382C) : Colors.white,
    secondary: dark ? const Color(0xFFE0B072) : const Color(0xFFA5651E),
    surface: dark ? const Color(0xFF141615) : const Color(0xFFFFFFFF),
    onSurface: dark ? const Color(0xFFECE8E1) : const Color(0xFF1F2421),
    error: dark ? const Color(0xFFF08C76) : const Color(0xFFB4442F),
  );
  final ext = dark ? PamiColors.dark : PamiColors.light;
  final background = dark ? const Color(0xFF0F1110) : const Color(0xFFFAF8F5);
  final base = ThemeData(useMaterial3: true, colorScheme: scheme, brightness: brightness);
  final text = base.textTheme.apply(bodyColor: scheme.onSurface, displayColor: scheme.onSurface).copyWith(
        displaySmall: base.textTheme.displaySmall?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -0.5,
            fontFeatures: PamiTokens.tabular),
        headlineMedium: base.textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -0.3),
        headlineSmall: base.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
        titleLarge: base.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
        titleMedium: base.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
      );

  return base.copyWith(
    scaffoldBackgroundColor: background,
    textTheme: text,
    extensions: [ext],
    appBarTheme: AppBarTheme(
      backgroundColor: background,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0.5,
      centerTitle: false,
      titleTextStyle: text.titleLarge,
    ),
    cardTheme: CardThemeData(
      color: scheme.surface,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(PamiTokens.radiusM),
        side: BorderSide(color: ext.border),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(64, 52),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(PamiTokens.radiusM)),
        textStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(64, 52),
        side: BorderSide(color: ext.border),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(PamiTokens.radiusM)),
        textStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(minimumSize: const Size(48, 44), textStyle: const TextStyle(fontWeight: FontWeight.w600)),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: ext.surfaceSoft,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(PamiTokens.radiusS), borderSide: BorderSide.none),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(PamiTokens.radiusS), borderSide: BorderSide.none),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(PamiTokens.radiusS),
        borderSide: BorderSide(color: scheme.primary, width: 1.6),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(PamiTokens.radiusS),
        borderSide: BorderSide(color: scheme.error, width: 1.2),
      ),
    ),
    chipTheme: base.chipTheme.copyWith(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(PamiTokens.radiusS)),
      side: BorderSide(color: ext.border),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: scheme.surface,
      surfaceTintColor: Colors.transparent,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(PamiTokens.radiusL))),
    ),
    dividerTheme: DividerThemeData(color: ext.border, space: 1, thickness: 1),
    listTileTheme: const ListTileThemeData(contentPadding: EdgeInsets.symmetric(horizontal: 16)),
    snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: scheme.surface,
      indicatorColor: ext.brandSoft,
      surfaceTintColor: Colors.transparent,
      labelTextStyle: WidgetStatePropertyAll(text.labelSmall?.copyWith(fontWeight: FontWeight.w600)),
    ),
    pageTransitionsTheme: const PageTransitionsTheme(builders: {
      TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
      TargetPlatform.android: FadeForwardsPageTransitionsBuilder(),
    }),
  );
}
