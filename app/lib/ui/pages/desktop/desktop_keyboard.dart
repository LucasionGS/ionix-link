import "package:flutter/services.dart";

import "../../../link/link.dart";

/// The phone's system keyboard for the Phone desktop: a hidden editable (a [TextInputClient] with no widget) whose
/// edits become `desktop.commit`s. The desktop's text field is the real one; this only carries what was typed.
///
/// The buffer is never the desktop's text. It starts as one invisible sentinel character, so a backspace on an
/// "empty" field still produces an edit, and every change is the difference between the buffer before and after:
/// the code points removed from its end become `deleteBefore`, what follows the common start becomes `text`. A
/// composing word the keyboard rewrites (autocorrect, swipe typing) therefore replaces the desktop's text the same
/// way. Enter is the keyboard's action or an inserted newline; it goes out as [onEnter], not as text.
class DesktopKeyboard implements TextInputClient {
  DesktopKeyboard({required this.onCommit, required this.onEnter, required this.onClosed});

  /// Called for typed text and deletions. [deleteBefore] is in code points and applies first.
  final void Function(String? text, int deleteBefore) onCommit;

  /// Called for Enter.
  final void Function() onEnter;

  /// Called when the system closes the keyboard (back, the hide button), so the page can follow.
  final void Function() onClosed;

  static const String _sentinel = "​";
  static const int _maxBuffer = 512;
  static final TextEditingValue _initial = const TextEditingValue(text: _sentinel, selection: TextSelection.collapsed(offset: _sentinel.length));

  TextInputConnection? _connection;
  TextEditingValue _value = _initial;
  DesktopTextPurpose? _purpose;

  /// Whether the keyboard is up.
  bool get isShown => _connection?.attached ?? false;

  /// Show the keyboard, shaped for [purpose]. Shows it again after a change of purpose.
  void show(DesktopTextPurpose purpose) {
    if (isShown && _purpose == purpose) {
      _connection!.show();
      return;
    }
    hide();
    _purpose = purpose;
    final multiline = purpose == DesktopTextPurpose.normal || purpose == DesktopTextPurpose.terminal;
    _connection = TextInput.attach(
      this,
      TextInputConfiguration(
        inputType: switch (purpose) {
          DesktopTextPurpose.number => const TextInputType.numberWithOptions(decimal: true),
          DesktopTextPurpose.phone => TextInputType.phone,
          DesktopTextPurpose.email => TextInputType.emailAddress,
          DesktopTextPurpose.url => TextInputType.url,
          DesktopTextPurpose.password || DesktopTextPurpose.terminal => TextInputType.visiblePassword,
          DesktopTextPurpose.normal => TextInputType.multiline,
        },
        obscureText: purpose == DesktopTextPurpose.password,
        autocorrect: purpose == DesktopTextPurpose.normal,
        enableSuggestions: purpose == DesktopTextPurpose.normal,
        inputAction: multiline ? TextInputAction.newline : TextInputAction.send,
        textCapitalization: TextCapitalization.none,
        enableIMEPersonalizedLearning: purpose == DesktopTextPurpose.normal,
      ),
    );
    _value = _initial;
    _connection!
      ..setEditingState(_initial)
      ..show();
  }

  /// Hide the keyboard and forget the buffer.
  void hide() {
    final connection = _connection;
    _connection = null;
    _purpose = null;
    _value = _initial;
    if (connection != null && connection.attached) connection.close();
  }

  @override
  TextEditingValue get currentTextEditingValue => _value;

  @override
  AutofillScope? get currentAutofillScope => null;

  @override
  void updateEditingValue(TextEditingValue value) {
    final old = _value.text;
    final text = value.text;
    var prefix = 0;
    while (prefix < old.length && prefix < text.length && old.codeUnitAt(prefix) == text.codeUnitAt(prefix)) {
      prefix++;
    }
    // Never cut a surrogate pair in two.
    if (prefix > 0 && ((prefix < old.length && _isLowSurrogate(old.codeUnitAt(prefix))) || (prefix < text.length && _isLowSurrogate(text.codeUnitAt(prefix))))) {
      prefix--;
    }
    var deleted = old.substring(prefix).runes.length;
    // The sentinel is not text: removing it along with real characters deletes only the characters.
    if (prefix == 0 && old.length > 1 && old.startsWith(_sentinel)) deleted--;
    _value = value;
    _emit(text.substring(prefix).replaceAll(_sentinel, ""), deleted);
    if (_value.text.isEmpty || !_value.text.startsWith(_sentinel) || _value.text.length > _maxBuffer) _reset();
  }

  void _emit(String inserted, int deleted) {
    final parts = inserted.split("\n");
    for (var i = 0; i < parts.length; i++) {
      final part = parts[i];
      final first = i == 0;
      if (part.isNotEmpty || (first && deleted > 0)) onCommit(part.isEmpty ? null : part, first ? deleted : 0);
      if (i < parts.length - 1) onEnter();
    }
  }

  void _reset() {
    _value = _initial;
    _connection?.setEditingState(_initial);
  }

  @override
  void performAction(TextInputAction action) {
    // The newline action arrives as text ("\n"), handled above; the others are an Enter key.
    if (action == TextInputAction.newline) return;
    onEnter();
    _reset();
  }

  @override
  void connectionClosed() {
    _connection = null;
    _purpose = null;
    _value = _initial;
    onClosed();
  }

  static bool _isLowSurrogate(int unit) => unit >= 0xDC00 && unit <= 0xDFFF;

  @override
  void performPrivateCommand(String action, Map<String, dynamic> data) {}

  @override
  void updateFloatingCursor(RawFloatingCursorPoint point) {}

  @override
  void showAutocorrectionPromptRect(int start, int end) {}

  @override
  void showToolbar() {}

  @override
  void insertTextPlaceholder(Size size) {}

  @override
  void removeTextPlaceholder() {}

  @override
  void didChangeInputControl(TextInputControl? oldControl, TextInputControl? newControl) {}

  @override
  void performSelector(String selectorName) {}

  @override
  bool onFocusReceived() => false;

  @override
  void insertContent(KeyboardInsertedContent content) {}
}
