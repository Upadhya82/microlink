import 'package:flutter/material.dart';

/// A text controller that can draw a password half-masked, so showing and
/// hiding it can be animated instead of snapping.
///
/// Flutter's `obscureText` is a boolean: the field is either all dots or all
/// characters, and toggling it swaps the two between one frame and the next.
/// To wipe across the text we have to draw the masking ourselves, which is
/// what [buildTextSpan] does here -- the first [revealed] characters are
/// drawn as themselves and the rest as [obscuringCharacter].
///
/// This custom drawing is only used while [maskingActive] is set, which
/// [AppTextField] does for the length of the animation and no longer. Once
/// the wipe finishes the field goes back to a real `obscureText: true`, so a
/// hidden password is hidden by the framework -- and gets the platform's own
/// handling of autofill and screenshots -- rather than by this class.
class ObscureRevealController extends TextEditingController {
  ObscureRevealController({super.text});

  /// The character drawn in place of a hidden one. Matches Flutter's own
  /// default so the field looks no different once settled.
  static const String obscuringCharacter = '•';

  double _progress = 0;
  bool _maskingActive = false;

  /// 0 draws every character masked, 1 draws them all plainly. Values between
  /// mask a proportion of the text from the right.
  double get progress => _progress;

  set progress(double value) {
    final next = value.clamp(0.0, 1.0);
    if (next == _progress) return;
    _progress = next;
    notifyListeners();
  }

  /// Whether this controller draws the mask. False hands drawing back to the
  /// framework.
  bool get maskingActive => _maskingActive;

  set maskingActive(bool value) {
    if (value == _maskingActive) return;
    _maskingActive = value;
    notifyListeners();
  }

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    if (!_maskingActive) {
      return super.buildTextSpan(
        context: context,
        style: style,
        withComposing: withComposing,
      );
    }

    final characters = text.characters.toList();
    if (characters.isEmpty) {
      return TextSpan(style: style, text: '');
    }

    // Round rather than floor so the last character finishes its turn at
    // progress 1 instead of only at the frame after it.
    final revealed = (characters.length * _progress).round().clamp(0, characters.length);

    final buffer = StringBuffer();
    for (var i = 0; i < characters.length; i++) {
      buffer.write(i < revealed ? characters[i] : obscuringCharacter);
    }
    return TextSpan(style: style, text: buffer.toString());
  }
}
