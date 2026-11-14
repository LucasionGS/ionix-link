import "errors.dart";

/// Typed field access for parsing JSON objects. A required field that is missing or of the wrong type throws
/// [LinkFormatException]; an optional one that is missing or `null` reads as null, and one of the wrong type throws.
class JsonRead {
  JsonRead._();

  static Never _bad(String key, String expected) =>
      throw LinkFormatException("The field `$key` is missing or is not $expected.");

  /// A required string.
  static String string(Map<String, dynamic> json, String key) {
    final value = json[key];
    if (value is String) return value;
    _bad(key, "a string");
  }

  /// An optional string.
  static String? optString(Map<String, dynamic> json, String key) {
    final value = json[key];
    if (value == null || value is String) return value as String?;
    _bad(key, "a string");
  }

  /// A required integer. A JSON number with no fraction (`3.0`) counts.
  static int integer(Map<String, dynamic> json, String key) {
    final value = _asInt(json[key]);
    if (value != null) return value;
    _bad(key, "an integer");
  }

  /// An optional integer.
  static int? optInt(Map<String, dynamic> json, String key) {
    final value = json[key];
    if (value == null) return null;
    final parsed = _asInt(value);
    if (parsed != null) return parsed;
    _bad(key, "an integer");
  }

  /// A required number, as a double.
  static double number(Map<String, dynamic> json, String key) {
    final value = json[key];
    if (value is num) return value.toDouble();
    _bad(key, "a number");
  }

  /// An optional number, as a double.
  static double? optNumber(Map<String, dynamic> json, String key) {
    final value = json[key];
    if (value == null) return null;
    if (value is num) return value.toDouble();
    _bad(key, "a number");
  }

  /// A required boolean.
  static bool boolean(Map<String, dynamic> json, String key) {
    final value = json[key];
    if (value is bool) return value;
    _bad(key, "a boolean");
  }

  /// An optional boolean.
  static bool? optBool(Map<String, dynamic> json, String key) {
    final value = json[key];
    if (value == null || value is bool) return value as bool?;
    _bad(key, "a boolean");
  }

  /// A required object.
  static Map<String, dynamic> object(Map<String, dynamic> json, String key) {
    final value = json[key];
    if (value is Map<String, dynamic>) return value;
    _bad(key, "an object");
  }

  /// An optional object.
  static Map<String, dynamic>? optObject(Map<String, dynamic> json, String key) {
    final value = json[key];
    if (value == null) return null;
    if (value is Map<String, dynamic>) return value;
    _bad(key, "an object");
  }

  /// A required array.
  static List<dynamic> list(Map<String, dynamic> json, String key) {
    final value = json[key];
    if (value is List) return value;
    _bad(key, "an array");
  }

  /// An optional array.
  static List<dynamic>? optList(Map<String, dynamic> json, String key) {
    final value = json[key];
    if (value == null) return null;
    if (value is List) return value;
    _bad(key, "an array");
  }

  /// The objects of an array field, each parsed with [parse]. Entries that are not objects or fail to parse are
  /// skipped, so one bad entry from a newer desktop does not hide the rest. A missing field reads as empty.
  static List<T> objects<T>(Map<String, dynamic> json, String key, T Function(Map<String, dynamic> entry) parse) {
    final result = <T>[];
    for (final entry in optList(json, key) ?? const []) {
      if (entry is! Map<String, dynamic>) continue;
      try {
        result.add(parse(entry));
      } on LinkException {
        continue;
      }
    }
    return result;
  }

  static int? _asInt(Object? value) {
    if (value is int) return value;
    if (value is double && value.isFinite && value == value.truncateToDouble()) return value.toInt();
    return null;
  }
}
