import 'package:flutter/material.dart';

import '../l10n/app_strings.dart';
import 'obscure_reveal_controller.dart';

/// The label for a required field: "Full name *" (item 5).
///
/// One helper so every form marks required fields the same way, and so a
/// screen reader is never left reading out a bare asterisk -- the widgets
/// that use this pair it with a spoken "required" (see [AppTextField]).
String requiredLabel(String label, {bool isRequired = true}) =>
    isRequired ? '$label *' : label;

/// The one text input widget every form should use, so inputs look and
/// behave identically across the app.
///
/// When [obscureText] changes and the field is backed by an
/// [ObscureRevealController], the change is wiped across the text one
/// character at a time rather than applied in a single frame. Pass an
/// ordinary [TextEditingController] and the field toggles instantly, as
/// before.
class AppTextField extends StatefulWidget {
  final TextEditingController controller;
  final String label;
  final String? hint;

  /// Shown under the field, for a rule the label cannot carry on its own.
  final String? helperText;

  /// Item 5: adds " *" to the label and tells a screen reader the field is
  /// required, so the marker is not information only sighted users get.
  final bool isRequired;
  final bool obscureText;
  final TextInputType keyboardType;
  final IconData? prefixIcon;
  final Widget? suffixIcon;
  final String? Function(String?)? validator;
  final int maxLines;
  final bool enabled;
  final void Function(String)? onChanged;

  const AppTextField({
    super.key,
    required this.controller,
    required this.label,
    this.hint,
    this.helperText,
    this.isRequired = false,
    this.obscureText = false,
    this.keyboardType = TextInputType.text,
    this.prefixIcon,
    this.suffixIcon,
    this.validator,
    this.maxLines = 1,
    this.enabled = true,
    this.onChanged,
  });

  @override
  State<AppTextField> createState() => _AppTextFieldState();
}

class _AppTextFieldState extends State<AppTextField> with SingleTickerProviderStateMixin {
  /// Long enough to read as a deliberate wipe rather than a stutter. Each
  /// character takes this divided by the password's length, so a short
  /// password wipes in bigger steps rather than finishing sooner.
  static const Duration _wipeDuration = Duration(milliseconds: 550);

  late final AnimationController _wipe = AnimationController(
    vsync: this,
    duration: _wipeDuration,
  );

  /// Null unless the caller gave us a controller that can draw a partial
  /// mask. Without one the field simply toggles, as it did before.
  ObscureRevealController? get _revealController =>
      widget.controller is ObscureRevealController
          ? widget.controller as ObscureRevealController
          : null;

  @override
  void initState() {
    super.initState();
    // 1 is fully revealed, so a field that starts hidden starts at 0.
    _wipe.value = widget.obscureText ? 0 : 1;
    _wipe.addListener(_applyProgress);
    _wipe.addStatusListener(_onWipeStatus);
  }

  @override
  void didUpdateWidget(AppTextField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.obscureText == widget.obscureText) return;
    final controller = _revealController;
    if (controller == null) return;

    // Hand drawing to the controller for the length of the wipe. Until it
    // finishes the field runs with obscureText false, because the framework's
    // own obscuring would paint over whatever we draw.
    controller.maskingActive = true;
    if (widget.obscureText) {
      _wipe.reverse();
    } else {
      _wipe.forward();
    }
  }

  void _applyProgress() => _revealController?.progress = _wipe.value;

  void _onWipeStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed && status != AnimationStatus.dismissed) {
      return;
    }
    // Settled. Give masking back to the framework so a hidden password is
    // hidden properly rather than only drawn that way.
    _revealController?.maskingActive = false;
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _wipe.removeListener(_applyProgress);
    _wipe.removeStatusListener(_onWipeStatus);
    _wipe.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final wiping = _revealController?.maskingActive ?? false;
    // While wiping, the controller is drawing the dots, so the framework must
    // not also obscure -- it would hide the animation entirely.
    final obscure = wiping ? false : widget.obscureText;

    final field = TextFormField(
      controller: widget.controller,
      obscureText: obscure,
      // A password field must never offer suggestions or autocorrect, and
      // during the wipe `obscureText` is false, which would otherwise turn
      // them back on mid-animation.
      enableSuggestions: !widget.obscureText && !wiping,
      autocorrect: !widget.obscureText && !wiping,
      keyboardType: widget.keyboardType,
      validator: widget.validator,
      maxLines: obscure ? 1 : widget.maxLines,
      enabled: widget.enabled,
      onChanged: widget.onChanged,
      decoration: InputDecoration(
        labelText: requiredLabel(widget.label, isRequired: widget.isRequired),
        hintText: widget.hint,
        helperText: widget.helperText,
        helperMaxLines: 3,
        prefixIcon: widget.prefixIcon != null ? Icon(widget.prefixIcon) : null,
        suffixIcon: widget.suffixIcon,
      ),
    );

    if (!widget.isRequired) return field;
    // The asterisk is a visual convention; this is what a screen reader
    // reads out instead of "Full name star".
    return Semantics(
      textField: true,
      label: '${widget.label}, ${tr("form.required_suffix")}',
      child: field,
    );
  }
}
