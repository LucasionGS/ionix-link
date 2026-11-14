import "dart:math" as math;
import "dart:ui" show lerpDouble;

import "package:material_ui/material_ui.dart";

import "../link/link.dart";


/// Spacing scale. Pages use these instead of literal paddings so a restyle changes one place.
class IonixSpace {
  IonixSpace._();

  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double xxl = 32;

  /// Smallest comfortable touch target.
  static const double touch = 48;

  /// Widest a single column of content grows to on a large screen.
  static const double maxContent = 560;

  /// Height of a floating bar.
  static const double bar = 44;

  /// What a scrolling page leaves free at its end for the floating dock.
  static const double dockClearance = 104;
}

/// Every token of the desktop's active theme, plus the shapes and surfaces built from them. Widgets read it with
/// [IonixTokens.of] and never name a colour: a new look is a change in this class and in `ui/widgets/`.
class IonixTokens extends ThemeExtension<IonixTokens> {
  const IonixTokens({
    required this.name,
    required this.bgDeep,
    required this.bgWindow,
    required this.bgCard,
    required this.hover,
    required this.border,
    required this.muted,
    required this.text,
    required this.textBright,
    required this.accent,
    required this.accentBright,
    required this.accentLight,
    required this.green,
    required this.orange,
    required this.red,
    required this.cyan,
    required this.link,
    required this.flat,
    required this.radiusSm,
    required this.radiusPill,
    required this.radiusPanel,
  });

  /// Tokens of a desktop theme.
  factory IonixTokens.from(LinkTheme t) {
    final c = t.colors;
    return IonixTokens(
      name: t.name,
      bgDeep: Color(c.bgDeep),
      bgWindow: Color(c.bgWindow),
      bgCard: Color(c.bgCard),
      hover: Color(c.hover),
      border: Color(c.border),
      muted: Color(c.muted),
      text: Color(c.text),
      textBright: Color(c.textBright),
      accent: Color(c.accent),
      accentBright: Color(c.accentBright),
      accentLight: Color(c.accentLight),
      green: Color(c.green),
      orange: Color(c.orange),
      red: Color(c.red),
      cyan: Color(c.cyan),
      link: Color(c.link),
      flat: t.flat,
      radiusSm: t.radiusSm.toDouble(),
      radiusPill: t.radiusPill.toDouble(),
      radiusPanel: t.radiusPanel.toDouble(),
    );
  }

  /// The tokens of the theme in effect.
  static IonixTokens of(BuildContext context) => Theme.of(context).extension<IonixTokens>()!;

  final String name;

  // Surfaces
  final Color bgDeep;
  final Color bgWindow;
  final Color bgCard;
  final Color hover;
  final Color border;

  // Text
  final Color muted;
  final Color text;
  final Color textBright;

  // Accent
  final Color accent;
  final Color accentBright;
  final Color accentLight;

  // Semantic
  final Color green;
  final Color orange;
  final Color red;
  final Color cyan;
  final Color link;

  /// Neutral fills, no glows or gradients, thin controls.
  final bool flat;

  /// Small controls, inputs, thumbnails.
  final double radiusSm;

  /// Buttons and chips.
  final double radiusPill;

  /// Cards, tiles and sheets.
  final double radiusPanel;

  BorderRadius get rSm => BorderRadius.circular(radiusSm);
  BorderRadius get rPanel => BorderRadius.circular(radiusPanel);
  BorderRadius get rPill => BorderRadius.circular(radiusPill);

  /// Readable text colour on top of [background]: whichever of the dark and bright text colours contrasts more.
  Color onColor(Color background) {
    return _contrast(background, bgDeep) >= _contrast(background, textBright) ? bgDeep : textBright;
  }

  /// Text on the primary (accent) surface.
  Color get onAccent => onColor(accentBright);

  /// The thickness of sliders and progress bars.
  double get trackHeight => flat ? 3 : 6;

  /// The font of the whole app, the desktop shell's.
  static const String fontFamily = "JetBrainsMono";

  /// Used until the font asset ships, and for glyphs it lacks.
  static const List<String> fontFallback = ["monospace"];

  /// Small secondary text on glass: the body colour a little dimmed. (`muted` fails contrast at small sizes.)
  Color get dim => text.withValues(alpha: 0.75);

  /// A glass panel (hero, now-playing, lists, sheets): translucent window fill, accent hairline. Flat themes get an
  /// opaque fill and the neutral border.
  BoxDecoration glass({bool selected = false, double? radius}) {
    return BoxDecoration(
      color: flat ? bgWindow : bgWindow.withValues(alpha: 0.82),
      borderRadius: BorderRadius.circular(radius ?? radiusPanel),
      border: Border.all(color: flat ? (selected ? accentBright : border) : accentBright.withValues(alpha: selected ? 0.6 : 0.25)),
    );
  }

  /// A pill, tile or control: half-transparent card fill; selected is a tinted accent.
  BoxDecoration pill({bool selected = false, double? radius}) {
    return BoxDecoration(
      color: selected ? accentBright.withValues(alpha: 0.22) : (flat ? bgCard : bgCard.withValues(alpha: 0.5)),
      borderRadius: BorderRadius.circular(radius ?? radiusPill),
      border: Border.all(color: selected ? accentBright.withValues(alpha: 0.6) : border.withValues(alpha: 0.5)),
    );
  }

  /// A floating bar or dock like the desktop's.
  BoxDecoration bar({double? radius}) {
    return BoxDecoration(
      color: flat ? bgWindow : bgDeep.withValues(alpha: 0.74),
      borderRadius: BorderRadius.circular(radius ?? radiusPill),
      border: Border.all(color: flat ? border : accentBright.withValues(alpha: 0.18)),
    );
  }

  /// The tinted square behind an icon.
  BoxDecoration badge({Color? color, bool circle = false}) {
    final base = color ?? accent;
    return BoxDecoration(
      color: base.withValues(alpha: 0.22),
      shape: circle ? BoxShape.circle : BoxShape.rectangle,
      borderRadius: circle ? null : BorderRadius.circular(radiusPill),
      border: Border.all(color: (color ?? accentBright).withValues(alpha: 0.4)),
    );
  }

  /// A glow for emphasised controls; nothing on flat themes.
  List<BoxShadow>? glow(Color color) {
    if (flat) return null;
    return [BoxShadow(color: color.withValues(alpha: 0.35), blurRadius: 20, spreadRadius: -2)];
  }

  @override
  IonixTokens copyWith() => this;

  @override
  IonixTokens lerp(ThemeExtension<IonixTokens>? other, double t) {
    if (other is! IonixTokens) return this;
    Color c(Color a, Color b) => Color.lerp(a, b, t)!;
    double d(double a, double b) => lerpDouble(a, b, t)!;
    return IonixTokens(
      name: t < 0.5 ? name : other.name,
      bgDeep: c(bgDeep, other.bgDeep),
      bgWindow: c(bgWindow, other.bgWindow),
      bgCard: c(bgCard, other.bgCard),
      hover: c(hover, other.hover),
      border: c(border, other.border),
      muted: c(muted, other.muted),
      text: c(text, other.text),
      textBright: c(textBright, other.textBright),
      accent: c(accent, other.accent),
      accentBright: c(accentBright, other.accentBright),
      accentLight: c(accentLight, other.accentLight),
      green: c(green, other.green),
      orange: c(orange, other.orange),
      red: c(red, other.red),
      cyan: c(cyan, other.cyan),
      link: c(link, other.link),
      flat: t < 0.5 ? flat : other.flat,
      radiusSm: d(radiusSm, other.radiusSm),
      radiusPill: d(radiusPill, other.radiusPill),
      radiusPanel: d(radiusPanel, other.radiusPanel),
    );
  }

  static double _luminance(Color c) => c.computeLuminance();

  static double _contrast(Color a, Color b) {
    final la = _luminance(a);
    final lb = _luminance(b);
    return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
  }
}

/// Builds the app's [ThemeData] (dark or light, whatever the palette is) from the desktop's [LinkTheme].
ThemeData buildTheme(LinkTheme theme) {
  final t = IonixTokens.from(theme);
  final onPrimary = t.onAccent;
  final dark = ThemeData.estimateBrightnessForColor(t.bgWindow) == Brightness.dark;
  final scheme = ColorScheme(
    brightness: dark ? Brightness.dark : Brightness.light,
    primary: t.accentBright,
    onPrimary: onPrimary,
    secondary: t.accent,
    onSecondary: t.onColor(t.accent),
    tertiary: t.accentLight,
    onTertiary: t.onColor(t.accentLight),
    error: t.red,
    onError: t.onColor(t.red),
    surface: t.bgWindow,
    onSurface: t.text,
    onSurfaceVariant: t.muted,
    outline: t.border,
    outlineVariant: t.border.withValues(alpha: 0.5),
    surfaceContainerHighest: t.bgCard,
    surfaceContainerHigh: t.bgCard,
    surfaceContainer: t.bgCard,
    surfaceContainerLow: t.bgWindow,
    surfaceContainerLowest: t.bgDeep,
    inverseSurface: t.textBright,
    onInverseSurface: t.bgDeep,
  );

  final base = ThemeData(
    brightness: scheme.brightness,
    useMaterial3: true,
    colorScheme: scheme,
    fontFamily: IonixTokens.fontFamily,
    fontFamilyFallback: IonixTokens.fontFallback,
  );
  TextStyle style(double size, Color color, [FontWeight weight = FontWeight.w400]) {
    return TextStyle(fontFamily: IonixTokens.fontFamily, fontFamilyFallback: IonixTokens.fontFallback, fontSize: size, color: color, fontWeight: weight, height: 1.35);
  }
  final textTheme = base.textTheme.copyWith(
    displaySmall: style(24, t.textBright, FontWeight.w700),
    headlineSmall: style(18, t.textBright, FontWeight.w700),
    titleLarge: style(18, t.textBright, FontWeight.w700),
    titleMedium: style(14, t.textBright, FontWeight.w700),
    titleSmall: style(13, t.textBright, FontWeight.w700),
    bodyLarge: style(13, t.text),
    bodyMedium: style(12, t.text),
    bodySmall: style(11, t.dim),
    labelLarge: style(12, t.textBright, FontWeight.w700),
    labelMedium: style(11, t.dim, FontWeight.w700),
    labelSmall: style(10, t.dim),
  );
  final shape = RoundedRectangleBorder(borderRadius: t.rPill);
  final inputBorder = OutlineInputBorder(borderRadius: t.rSm, borderSide: BorderSide(color: t.border));

  return base.copyWith(
    extensions: [t],
    scaffoldBackgroundColor: Colors.transparent,
    canvasColor: t.bgWindow,
    dividerColor: t.border.withValues(alpha: 0.5),
    textTheme: textTheme,
    iconTheme: IconThemeData(color: t.accentLight),
    appBarTheme: AppBarThemeData(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      foregroundColor: t.textBright,
    ),
    cardTheme: CardThemeData(color: t.bgCard, elevation: 0, margin: EdgeInsets.zero, shape: RoundedRectangleBorder(borderRadius: t.rPanel, side: BorderSide(color: t.border.withValues(alpha: 0.6)))),
    dialogTheme: DialogThemeData(backgroundColor: t.bgWindow, surfaceTintColor: Colors.transparent, shape: RoundedRectangleBorder(borderRadius: t.rPanel, side: BorderSide(color: t.border))),
    bottomSheetTheme: BottomSheetThemeData(backgroundColor: t.bgWindow, surfaceTintColor: Colors.transparent, shape: RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(t.radiusPanel)))),
    snackBarTheme: SnackBarThemeData(backgroundColor: t.bgCard, contentTextStyle: style(12, t.textBright), behavior: SnackBarBehavior.floating, shape: RoundedRectangleBorder(borderRadius: t.rSm)),
    inputDecorationTheme: InputDecorationThemeData(
      filled: true,
      fillColor: t.bgCard,
      hintStyle: style(12, t.dim),
      border: inputBorder,
      enabledBorder: inputBorder,
      focusedBorder: OutlineInputBorder(borderRadius: t.rSm, borderSide: BorderSide(color: t.accentBright, width: 1.5)),
      contentPadding: const EdgeInsets.symmetric(horizontal: IonixSpace.lg, vertical: IonixSpace.md),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: t.accentBright,
        foregroundColor: onPrimary,
        minimumSize: const Size(64, IonixSpace.touch),
        padding: const EdgeInsets.symmetric(horizontal: IonixSpace.xl),
        shape: shape,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: t.textBright,
        side: BorderSide(color: t.border),
        minimumSize: const Size(64, IonixSpace.touch),
        padding: const EdgeInsets.symmetric(horizontal: IonixSpace.xl),
        shape: shape,
      ),
    ),
    textButtonTheme: TextButtonThemeData(style: TextButton.styleFrom(foregroundColor: t.accentLight, minimumSize: const Size(48, IonixSpace.touch), shape: shape)),
    iconButtonTheme: IconButtonThemeData(style: IconButton.styleFrom(foregroundColor: t.textBright, minimumSize: const Size(IonixSpace.touch, IonixSpace.touch))),
    sliderTheme: SliderThemeData(
      trackHeight: t.trackHeight,
      activeTrackColor: t.accentBright,
      inactiveTrackColor: t.border.withValues(alpha: 0.6),
      thumbColor: t.textBright,
      overlayColor: t.accentBright.withValues(alpha: 0.16),
      thumbShape: RoundSliderThumbShape(enabledThumbRadius: t.flat ? 8 : 10),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? onPrimary : t.muted),
      trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? t.accentBright : t.bgCard),
      trackOutlineColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? Colors.transparent : t.border),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(color: t.accentBright, linearTrackColor: t.border),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: t.bgWindow,
      surfaceTintColor: Colors.transparent,
      indicatorColor: t.accentBright.withValues(alpha: 0.22),
      height: 68,
      labelTextStyle: WidgetStateProperty.resolveWith((s) => style(12, s.contains(WidgetState.selected) ? t.textBright : t.dim, FontWeight.w700)),
      iconTheme: WidgetStateProperty.resolveWith((s) => IconThemeData(color: s.contains(WidgetState.selected) ? t.accentLight : t.muted)),
    ),
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: t.bgWindow,
      indicatorColor: t.accentBright.withValues(alpha: 0.22),
      selectedIconTheme: IconThemeData(color: t.accentLight),
      unselectedIconTheme: IconThemeData(color: t.muted),
      selectedLabelTextStyle: style(12, t.textBright, FontWeight.w700),
      unselectedLabelTextStyle: style(12, t.dim),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: t.bgCard,
      selectedColor: t.accentBright.withValues(alpha: 0.25),
      side: BorderSide(color: t.border),
      labelStyle: style(12, t.text),
      shape: shape,
    ),
    listTileTheme: ListTileThemeData(iconColor: t.accentLight, textColor: t.text, contentPadding: const EdgeInsets.symmetric(horizontal: IonixSpace.lg)),
    textSelectionTheme: TextSelectionThemeData(cursorColor: t.accentBright, selectionColor: t.accentBright.withValues(alpha: 0.35), selectionHandleColor: t.accentBright),
  );
}
