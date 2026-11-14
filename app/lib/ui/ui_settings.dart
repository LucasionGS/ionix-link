import "package:flutter/foundation.dart";

/// Settings that only the UI cares about. Held for the session: the link store has no field for them.
class UiSettings {
  UiSettings._();

  /// Touchpad speed: phone logical px to desktop logical px.
  static final ValueNotifier<double> touchSensitivity = ValueNotifier(1.5);
}
