import 'dart:math' as math;

import 'dart:async';

import 'package:flutter/material.dart';

import '../theme/app_motion.dart';

/// Text that ripples into view, each letter lifting and settling a moment
/// after the one before it -- a wave travelling along the line the way it
/// travels along a flag.
///
/// The wave is a greeting, not a loading state: it plays once, and the line
/// is plain selectable-looking text the moment it finishes.
///
/// Words are kept whole. The letters inside a word animate individually but
/// the word is laid out as one unit, so a line that has to wrap breaks
/// between words like any other text rather than mid-word.
class WaveText extends StatefulWidget {
  final String text;
  final TextStyle? style;
  final TextAlign textAlign;

  /// Waited out before the wave starts, for sequencing after whatever sits
  /// above it.
  final Duration delay;

  /// How far each letter lifts at the peak of the wave, in logical pixels.
  /// Past about 6 it stops reading as a ripple and starts looking like the
  /// letters are falling into place.
  final double amplitude;

  /// Keeps the wave running instead of playing once.
  ///
  /// The letters stay fully visible between passes -- only the lift repeats
  /// -- so the line never flickers back to being unreadable.
  final bool repeat;

  /// Pause at the end of each pass before the next crest starts, so a looping
  /// wave reads as a slow pulse rather than a conveyor belt.
  final Duration repeatPause;

  const WaveText(
    this.text, {
    super.key,
    this.style,
    this.textAlign = TextAlign.center,
    this.delay = Duration.zero,
    this.amplitude = 4,
    this.repeat = false,
    this.repeatPause = const Duration(milliseconds: 900),
  });

  @override
  State<WaveText> createState() => _WaveTextState();
}

class _WaveTextState extends State<WaveText> with SingleTickerProviderStateMixin {
  /// Gap between one letter starting and the next. Much smaller than
  /// [AppMotion.stagger], which is tuned for cards: at 55ms a thirty-letter
  /// line would take over a second and a half to finish.
  static const Duration _perLetter = Duration(milliseconds: 18);

  /// How long a single letter takes to rise and settle.
  static const Duration _letterTravel = Duration(milliseconds: 420);

  late final int _letterCount = widget.text.characters.length;

  /// One crest travelling from the first letter to the last.
  Duration get _wavePass => _letterTravel + _perLetter * _letterCount;

  /// The repeating unit: the pass, plus the pause that follows it. The pause
  /// is part of the controller's duration rather than a separate timer, so
  /// every letter simply sits at rest through the tail of the cycle.
  Duration get _cycle => widget.repeat ? _wavePass + widget.repeatPause : _wavePass;

  late final AnimationController _controller =
      AnimationController(vsync: this, duration: _cycle);

  /// After the first crest the letters are on screen for good; later passes
  /// move them without fading them, or the line would blink out once a cycle.
  bool _firstPassDone = false;

  /// Both held so they can be cancelled on dispose; uncancelled delays stay
  /// pending after the widget is gone, which leaks and trips the widget-test
  /// check for outstanding timers.
  Timer? _startTimer;
  Timer? _firstPassTimer;

  @override
  void initState() {
    super.initState();
    _startTimer = Timer(widget.delay, () {
      if (widget.repeat) {
        _controller.repeat();
        // One cycle in, the fade has served its purpose.
        _firstPassTimer = Timer(_cycle, () {
          setState(() => _firstPassDone = true);
        });
      } else {
        _controller.forward();
      }
    });
  }

  @override
  void dispose() {
    _startTimer?.cancel();
    _firstPassTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  /// The slice of the whole animation during which letter [index] moves.
  Animation<double> _letterAnimation(int index) {
    final total = _controller.duration!.inMilliseconds;
    final start = (_perLetter.inMilliseconds * index) / total;
    final end = start + _letterTravel.inMilliseconds / total;
    return CurvedAnimation(
      parent: _controller,
      curve: Interval(start, end.clamp(0.0, 1.0)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final style = widget.style ?? DefaultTextStyle.of(context).style;

    // Index every letter across the whole line, not per word, so the wave
    // keeps travelling through the spaces instead of restarting each word.
    var letterIndex = 0;
    final words = widget.text.split(' ');

    return Semantics(
      // The line is one sentence; without this a screen reader would read it
      // letter by letter.
      label: widget.text,
      excludeSemantics: true,
      child: Wrap(
        alignment: _wrapAlignment,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          for (var w = 0; w < words.length; w++)
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final letter in words[w].characters)
                  _WaveLetter(
                    letter: letter,
                    style: style,
                    animation: _letterAnimation(letterIndex++),
                    amplitude: widget.amplitude,
                    fadeIn: !_firstPassDone,
                  ),
                // The space that followed this word, carrying its own slot so
                // the wave keeps travelling at the same rate across it. Not
                // after the last word, where it would push the line off
                // centre.
                if (w < words.length - 1)
                  _WaveLetter(
                    letter: ' ',
                    style: style,
                    animation: _letterAnimation(letterIndex++),
                    amplitude: widget.amplitude,
                    fadeIn: !_firstPassDone,
                  ),
              ],
            ),
        ],
      ),
    );
  }

  WrapAlignment get _wrapAlignment => switch (widget.textAlign) {
        TextAlign.left || TextAlign.start => WrapAlignment.start,
        TextAlign.right || TextAlign.end => WrapAlignment.end,
        _ => WrapAlignment.center,
      };
}

/// One letter of a [WaveText]: fades in while riding up and back down.
class _WaveLetter extends StatelessWidget {
  final String letter;
  final TextStyle style;
  final Animation<double> animation;
  final double amplitude;

  /// False once the letter has arrived: later passes lift it without
  /// touching its opacity.
  final bool fadeIn;

  const _WaveLetter({
    required this.letter,
    required this.style,
    required this.animation,
    required this.amplitude,
    required this.fadeIn,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: animation,
      builder: (context, child) {
        final t = animation.value;
        // sin over half a turn: 0 at both ends, 1 in the middle. That is the
        // crest passing through this letter -- it ends where it started,
        // which is what keeps the finished line on its baseline.
        final lift = math.sin(t * math.pi) * amplitude;
        return Transform.translate(
          offset: Offset(0, -lift),
          child: fadeIn
              // Opacity rises faster than the lift so letters are readable at
              // the crest rather than arriving only once they have settled.
              ? Opacity(
                  opacity: Curves.easeOut.transform(t.clamp(0.0, 1.0)),
                  child: child,
                )
              : child,
        );
      },
      child: Text(letter, style: style),
    );
  }
}
