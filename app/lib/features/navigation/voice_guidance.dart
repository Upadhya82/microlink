import 'package:flutter_tts/flutter_tts.dart';
import 'package:latlong2/latlong.dart';

import '../../core/models/route_step.dart';

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
  final FlutterTts _tts = FlutterTts();

  List<RouteStep> _steps = const [];
  final Set<int> _announced = {};
  bool _muted = false;
  bool _configured = false;
  String _locale = 'en-US';

  bool get muted => _muted;

  /// Load a new route's steps. Clears what has already been said.
  Future<void> setRoute(List<RouteStep> steps, {required String voiceLocale}) async {
    _steps = steps;
    _announced.clear();
    _locale = voiceLocale;
    _configured = false;
    await stop();
  }

  Future<void> _configure() async {
    if (_configured) return;
    _configured = true;
    try {
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
  Future<void> speak(String text) async {
    if (_muted || text.isEmpty) return;
    await _configure();
    try {
      await _tts.speak(text);
    } catch (_) {
      // Ignored on purpose.
    }
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
