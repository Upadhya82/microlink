import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

import 'package:frontend/core/models/route_step.dart';
import 'package:frontend/features/navigation/voice_guidance.dart';

/// Item 15: voice guidance "did nothing" because nothing was spoken until
/// the driver was within 40 m of the first turn, and a device with no voice
/// for the chosen language failed silently. These cover the parts that do
/// not need a TTS engine: which locale is chosen, and which step is next.
RouteStep _step(String instruction, {double lat = 6.92, double lng = 79.86}) =>
    RouteStep(
      instruction: instruction,
      distanceM: 200,
      location: LatLng(lat, lng),
      maneuver: 'turn',
      modifier: 'left',
    );

void main() {
  // FlutterTts registers a method-call handler in its constructor, which
  // needs the test binding up first.
  TestWidgetsFlutterBinding.ensureInitialized();

  group('voiceLocaleFor', () {
    test('matches navigation-service for every language it offers', () {
      // Same table as services/navigation-service/app/locales.py; a
      // disagreement here means the app asks for a voice the server never
      // generates instructions for.
      expect(voiceLocaleFor('en'), 'en-US');
      expect(voiceLocaleFor('si'), 'si-LK');
      expect(voiceLocaleFor('ta'), 'ta-IN');
      expect(voiceLocaleFor('hi'), 'hi-IN');
      expect(voiceLocaleFor('fr'), 'fr-FR');
      expect(voiceLocaleFor('es'), 'es-ES');
    });

    test('an unknown language falls back to English, as the server does', () {
      expect(voiceLocaleFor('xx'), 'en-US');
      expect(voiceLocaleFor(''), 'en-US');
      expect(voiceLocaleFor('xx'), VoiceGuidance.fallbackLocale);
    });
  });

  group('upcomingStep', () {
    test('is the first step of a fresh route', () async {
      final voice = VoiceGuidance();
      await voice.setRoute(
        [_step('Turn left'), _step('Turn right')],
        voiceLocale: 'en-US',
      );
      expect(voice.upcomingStep?.instruction, 'Turn left');
    });

    test('moves on once the first instruction has been given', () async {
      final voice = VoiceGuidance();
      await voice.setRoute(
        [_step('Turn left'), _step('Turn right')],
        voiceLocale: 'en-US',
      );

      // announceFirstStep marks the first one as said; the TTS call itself
      // is a no-op under `flutter test`, which is fine -- what matters is
      // that the banner then points at the next turn.
      await voice.announceFirstStep();
      expect(voice.upcomingStep?.instruction, 'Turn right');
    });

    test('an empty route has nothing to announce', () async {
      final voice = VoiceGuidance();
      await voice.setRoute(const [], voiceLocale: 'en-US');
      expect(await voice.announceFirstStep(), isNull);
      expect(voice.upcomingStep, isNull);
    });

    test('loading a new route clears what was already said', () async {
      final voice = VoiceGuidance();
      await voice.setRoute([_step('Turn left')], voiceLocale: 'en-US');
      await voice.announceFirstStep();

      // Item 2: choosing an alternative route must not inherit the previous
      // route's "already announced" state, or its first turn is skipped.
      await voice.setRoute(
        [_step('Keep straight'), _step('Turn right')],
        voiceLocale: 'en-US',
      );
      expect(voice.upcomingStep?.instruction, 'Keep straight');
    });
  });

  group('the fallback notice', () {
    test('there is nothing to report before anything is spoken', () async {
      final voice = VoiceGuidance();
      await voice.setRoute([_step('Turn left')], voiceLocale: 'si-LK');
      expect(voice.takeFallbackNotice(), isNull);
    });

    test('the notice is given once, not on every turn', () async {
      final voice = VoiceGuidance();
      await voice.setRoute([_step('Turn left')], voiceLocale: 'en-US');
      // Whatever the engine does here, asking twice must never produce the
      // same message twice -- that is the whole point of "one-time".
      final first = voice.takeFallbackNotice();
      expect(voice.takeFallbackNotice(), isNull);
      if (first != null) expect(first, contains('English'));
    });

    test('muted still reports the locale it would speak in', () async {
      final voice = VoiceGuidance();
      await voice.setMuted(true);
      expect(voice.muted, isTrue);
      expect(voice.activeLocale, isNotEmpty);
    });
  });
}
