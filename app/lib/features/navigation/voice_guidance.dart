import 'package:flutter_tts/flutter_tts.dart';
import 'package:latlong2/latlong.dart';

import '../../core/models/route_step.dart';

/// Voice locale for a language code, mirroring navigation-service's
/// `VOICE_LOCALES` (item 15).
///
/// The route endpoint already returns the right one, so this is for the
/// places that have no route in hand -- the "Test voice" button in Settings.
/// An unknown code falls back to English, which is what the server does.
const Map<String, String> kVoiceLocales = {
  'en': 'en-US',
  'si': 'si-LK',
  'ta': 'ta-IN',
  'hi': 'hi-IN',
  'fr': 'fr-FR',
  'es': 'es-ES',
};

String voiceLocaleFor(String languageCode) =>
    kVoiceLocales[languageCode] ?? VoiceGuidance.fallbackLocale;

/// Speaks turn-by-turn instructions as the user approaches each one
/// (REQ-NAV-3).
///
/// The rule is deliberately simple: announce a step once, when the user comes
/// within [announceWithinMetres] of where it happens. Real navigation apps
/// use heading and dead reckoning to decide this; for a student project a
/// distance threshold gives the right instruction at the right corner without
/// a class of bugs nobody has time to debug.
///
/// Every step is announced at most once, tracked by index, so standing still
/// at a junction does not make the phone repeat itself.
class VoiceGuidance {
  /// What to speak in when the chosen language has no voice installed.
  static const String fallbackLocale = 'en-US';

  final FlutterTts _tts = FlutterTts();

  List<RouteStep> _steps = const [];
  final Set<int> _announced = {};
  bool _muted = false;
  bool _configured = false;
  String _locale = 'en-US';

  /// Item 15: set when the device has no voice for the chosen language and
  /// English was used instead. The screen shows this once, because a driver
  /// hearing English after choosing Sinhala deserves to know why -- and
  /// being told on every single turn would be worse than silence.
  String? _fallbackNotice;
  bool _fallbackNoticeShown = false;

  bool get muted => _muted;

  /// The fallback message, the first time it is asked for. Null afterwards,
  /// and null when the chosen language is available.
  String? takeFallbackNotice() {
    if (_fallbackNotice == null || _fallbackNoticeShown) return null;
    _fallbackNoticeShown = true;
    return _fallbackNotice;
  }

  /// The locale actually being spoken, which may be the English fallback.
  String get activeLocale => _locale;

  /// Load a new route's steps. Clears what has already been said.
  Future<void> setRoute(List<RouteStep> steps, {required String voiceLocale}) async {
    _steps = steps;
    _announced.clear();
    if (voiceLocale != _locale) {
      // A different language has to be re-checked against the device.
      _fallbackNotice = null;
      _fallbackNoticeShown = false;
    }
    _locale = voiceLocale;
    _configured = false;
    await stop();
  }

  /// Picks the language to speak in, falling back to English (item 15).
  ///
  /// `setLanguage` on an unavailable voice does not reliably fail on every
  /// platform -- it can accept the call and then say nothing at all, which
  /// is how "voice guidance does nothing" happens. Asking first is the only
  /// way to know, and to be able to explain it.
  Future<String> _resolveLanguage(String wanted) async {
    try {
      final available = await _tts.isLanguageAvailable(wanted);
      if (available == true) return wanted;
    } catch (_) {
      // An engine that cannot answer is treated as "not available".
    }
    if (wanted.toLowerCase().startsWith('en')) return fallbackLocale;
    _fallbackNotice =
        'Your device has no voice for this language, so directions will be '
        'spoken in English.';
    return fallbackLocale;
  }

  Future<void> _configure() async {
    if (_configured) return;
    _configured = true;
    try {
      _locale = await _resolveLanguage(_locale);
      await _tts.setLanguage(_locale);
      // Slightly under default: navigation instructions are read while the
      // user is driving and a rushed sentence has to be repeated.
      await _tts.setSpeechRate(0.45);
      await _tts.setVolume(1.0);
      await _tts.setPitch(1.0);
    } catch (_) {
      // A device with no voice for this locale still gets the on-screen
      // instruction; speech is an enhancement, never the only channel.
    }
  }

  Future<void> setMuted(bool value) async {
    _muted = value;
    if (value) await stop();
  }

  Future<void> stop() async {
    try {
      await _tts.stop();
    } catch (_) {
      // Nothing useful to do.
    }
  }

  /// Call on every position update. Speaks the nearest unannounced step the
  /// user has come within range of.
  ///
  /// Returns the step that was announced, or null.
  Future<RouteStep?> onPositionChanged(
    LatLng position, {
    double announceWithinMetres = 40,
  }) async {
    if (_muted || _steps.isEmpty) return null;

    final distance = const Distance();
    for (var i = 0; i < _steps.length; i++) {
      if (_announced.contains(i)) continue;
      final step = _steps[i];
      final metres = distance.as(
        LengthUnit.Meter,
        position,
        LatLng(step.location.latitude, step.location.longitude),
      );
      if (metres <= announceWithinMetres) {
        _announced.add(i);
        await _configure();
        try {
          await _tts.speak(step.instruction);
        } catch (_) {
          // Speech failed; the instruction is still on screen.
        }
        return step;
      }
    }
    return null;
  }

  /// Speak an arbitrary sentence, e.g. when the user taps an instruction.
  ///
  /// [force] ignores the mute switch, for the "Test voice" button in
  /// Settings: a muted app that silently refuses to test the voice looks
  /// broken.
  Future<void> speak(String text, {bool force = false}) async {
    if ((_muted && !force) || text.isEmpty) return;
    await _configure();
    try {
      await _tts.speak(text);
    } catch (_) {
      // Ignored on purpose.
    }
  }

  /// Item 15: say the first instruction when navigation starts.
  ///
  /// Before this, nothing was spoken until the driver physically came within
  /// 40 m of the first turn -- so tapping Navigation appeared to do nothing
  /// at all, which is exactly what was reported.
  Future<RouteStep?> announceFirstStep() async {
    if (_steps.isEmpty) return null;
    final step = _steps.first;
    _announced.add(0);
    await speak(step.instruction);
    return step;
  }

  /// The step the user is currently heading towards: the first one not yet
  /// announced, which is what the banner should show.
  RouteStep? get upcomingStep {
    for (var i = 0; i < _steps.length; i++) {
      if (!_announced.contains(i)) return _steps[i];
    }
    return _steps.isEmpty ? null : _steps.last;
  }

  void dispose() {
    stop();
  }
}
