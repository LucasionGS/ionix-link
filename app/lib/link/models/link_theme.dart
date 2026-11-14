/// The desktop's active theme as `theme.changed` / `theme.get` send it (`PROTOCOL.md` 8.8). Parsing is forgiving: a
/// missing or malformed colour or radius falls back to the base value, so whatever a newer desktop sends still gives
/// a usable theme.
class LinkTheme {
  const LinkTheme({
    required this.name,
    required this.colors,
    this.flat = false,
    this.radiusSm = 8,
    this.radiusPill = 12,
    this.radiusPanel = 18,
    this.revision = "",
    this.wallpaper,
  });

  /// The base Ionix theme, used until a desktop has ever sent one.
  static const LinkTheme ionix = LinkTheme(name: "ionix", colors: LinkColors.ionix);

  /// Theme name, for display.
  final String name;

  /// The sixteen palette roles.
  final LinkColors colors;

  /// The theme's flat choice: neutral fills, no glow, thin controls.
  final bool flat;

  /// Small corner radius, logical px.
  final int radiusSm;

  /// Pill (button, chip) radius, logical px.
  final int radiusPill;

  /// Panel and card radius, logical px.
  final int radiusPanel;

  /// The desktop's hash of the fields above; equal revisions are the same theme. Empty for [ionix].
  final String revision;

  /// Hash of the desktop's current wallpaper, null when unknown.
  final String? wallpaper;

  /// The `Theme` object as on the wire.
  Map<String, dynamic> toJson() {
    return {
      "name": name,
      "colors": colors.toJson(),
      "flat": flat,
      "radius": {"sm": radiusSm, "pill": radiusPill, "panel": radiusPanel},
      "revision": revision,
      if (wallpaper != null) "wallpaper": wallpaper,
    };
  }

  /// Parse a `Theme` object. Never throws: anything missing or malformed takes the [ionix] value.
  static LinkTheme fromJson(Map<String, dynamic> json) {
    final colors = json["colors"];
    final radius = json["radius"];
    final radii = radius is Map<String, dynamic> ? radius : const <String, dynamic>{};
    final name = json["name"];
    final revision = json["revision"];
    final wallpaper = json["wallpaper"];
    return LinkTheme(
      name: name is String && name.isNotEmpty ? name : ionix.name,
      colors: colors is Map<String, dynamic> ? LinkColors.fromJson(colors) : LinkColors.ionix,
      flat: json["flat"] == true,
      radiusSm: _radius(radii["sm"], ionix.radiusSm),
      radiusPill: _radius(radii["pill"], ionix.radiusPill),
      radiusPanel: _radius(radii["panel"], ionix.radiusPanel),
      revision: revision is String ? revision : "",
      wallpaper: wallpaper is String && wallpaper.isNotEmpty ? wallpaper : null,
    );
  }

  static int _radius(Object? value, int fallback) {
    if (value is num && value.isFinite && value >= 0 && value <= 1000) return value.round();
    return fallback;
  }

  @override
  bool operator ==(Object other) =>
      other is LinkTheme &&
      other.name == name &&
      other.colors == colors &&
      other.flat == flat &&
      other.radiusSm == radiusSm &&
      other.radiusPill == radiusPill &&
      other.radiusPanel == radiusPanel &&
      other.revision == revision &&
      other.wallpaper == wallpaper;

  @override
  int get hashCode => Object.hash(name, colors, flat, radiusSm, radiusPill, radiusPanel, revision, wallpaper);

  @override
  String toString() => "LinkTheme($name, $revision)";
}

/// The sixteen palette roles of a [LinkTheme], each as an opaque ARGB integer (`0xFFrrggbb`), ready for `Color(...)`
/// in the UI. The link layer does not import `dart:ui`.
class LinkColors {
  const LinkColors({
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
  });

  /// The base Ionix palette (`PROTOCOL.md` 8.8).
  static const LinkColors ionix = LinkColors(
    bgDeep: 0xFF0F0A18,
    bgWindow: 0xFF1A1025,
    bgCard: 0xFF2D2D3F,
    hover: 0xFF3A2D50,
    border: 0xFF4A3D60,
    muted: 0xFF6B5F80,
    text: 0xFFC4B5FD,
    textBright: 0xFFE2D9F3,
    accent: 0xFF9B59B6,
    accentBright: 0xFFA855F7,
    accentLight: 0xFFC084FC,
    green: 0xFF2ECC71,
    orange: 0xFFF39C12,
    red: 0xFFE74C3C,
    cyan: 0xFF48DBFB,
    link: 0xFF7C3AED,
  );

  // Backgrounds
  final int bgDeep;
  final int bgWindow;
  final int bgCard;
  final int hover;
  final int border;

  // Text
  final int muted;
  final int text;
  final int textBright;

  // Accent
  final int accent;
  final int accentBright;
  final int accentLight;

  // Semantic
  final int green;
  final int orange;
  final int red;
  final int cyan;
  final int link;

  /// The roles by wire key, in the order of `PROTOCOL.md` 8.8.
  Map<String, int> get asMap => {
    "bgDeep": bgDeep,
    "bgWindow": bgWindow,
    "bgCard": bgCard,
    "hover": hover,
    "border": border,
    "muted": muted,
    "text": text,
    "textBright": textBright,
    "accent": accent,
    "accentBright": accentBright,
    "accentLight": accentLight,
    "green": green,
    "orange": orange,
    "red": red,
    "cyan": cyan,
    "link": link,
  };

  /// Every role as `"#rrggbb"`, lowercase.
  Map<String, dynamic> toJson() => asMap.map((key, value) => MapEntry(key, formatHex(value)));

  /// Parse a `colors` object. Never throws: a missing or unparseable role takes the [ionix] value.
  static LinkColors fromJson(Map<String, dynamic> json) {
    final base = ionix.asMap;
    int read(String key) => parseHex(json[key]) ?? base[key]!;
    return LinkColors(
      bgDeep: read("bgDeep"),
      bgWindow: read("bgWindow"),
      bgCard: read("bgCard"),
      hover: read("hover"),
      border: read("border"),
      muted: read("muted"),
      text: read("text"),
      textBright: read("textBright"),
      accent: read("accent"),
      accentBright: read("accentBright"),
      accentLight: read("accentLight"),
      green: read("green"),
      orange: read("orange"),
      red: read("red"),
      cyan: read("cyan"),
      link: read("link"),
    );
  }

  /// Parse `#rrggbb` (or `#aarrggbb`, whose alpha is dropped as the protocol says) into an opaque ARGB integer.
  /// Returns null for anything else.
  static int? parseHex(Object? value) {
    if (value is! String) return null;
    final match = RegExp(r"^#?(?:[0-9a-fA-F]{2})?([0-9a-fA-F]{6})$").firstMatch(value.trim());
    if (match == null) return null;
    return 0xFF000000 | int.parse(match.group(1)!, radix: 16);
  }

  /// Format an ARGB integer as `#rrggbb`.
  static String formatHex(int argb) => "#${(argb & 0xFFFFFF).toRadixString(16).padLeft(6, "0")}";

  @override
  bool operator ==(Object other) {
    if (other is! LinkColors) return false;
    final mine = asMap;
    final theirs = other.asMap;
    for (final key in mine.keys) {
      if (mine[key] != theirs[key]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hashAll(asMap.values);
}
