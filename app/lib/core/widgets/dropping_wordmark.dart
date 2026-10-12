import 'package:flutter/material.dart';

import 'sculpted.dart';

/// A wordmark whose letters fall in from above the frame one at a time, each
/// landing with a small bounce, until the word stands assembled.
///
/// Every letter is drawn by [Sculpted], so what lands is a solid object with
/// thickness and a lit face rather than flat text. The specular sweeps across
/// the finished word once the last letter is down, which is what stops it
/// looking like a still image afterwards.
class DroppingWordmark extends StatefulWidget {
  final String text;
  final TextStyle style;

  /// The material color for every letter.
  final Color color;

  /// Waited out before the first letter drops.
  final Duration delay;

  /// Gap between one letter starting its fall and the next. The whole word
  /// takes this times its length, so a long word wants a smaller value.
  final Duration perLetter;

  /// How long a single letter takes to fall and settle.
  final Duration letterFall;

  /// How far above its resting place a letter starts, in logical pixels.
  /// Large enough that letters appear to come from outside the frame.
  final double dropHeight;

  /// Extrusion depth handed to [Sculpted].
  final double depth;

  const DroppingWordmark(
    this.text, {
    super.key,
    required this.style,
    required this.color,
    this.delay = Duration.zero,
    this.perLetter = const Duration(milliseconds: 90),
    this.letterFall = const Duration(milliseconds: 620),
    this.dropHeight = 120,
    this.depth = 4,
  });

  @override
  State<DroppingWordmark> createState() => _DroppingWordmarkState();
}

class _DroppingWordmarkState extends State<DroppingWordmark>
    with TickerProviderStateMixin {
  late final List<String> _letters = widget.text.characters.toList();

  /// Drives the fall of every letter; each one reads a different slice.
  late final AnimationController _drop = AnimationController(
    vsync: this,
    duration: widget.letterFall + widget.perLetter * _letters.length,
  );

  /// Sweeps the specular across the assembled word, on a loop. Separate from
  /// [_drop] because it keeps going after the word has landed.
  late final AnimationController _sheen = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2600),
  );

  @override
  void initState() {
    super.initState();
    Future.delayed(widget.delay, () {
      if (!mounted) return;
      _drop.forward();
      _sheen.repeat();
    });
  }

  @override
  void dispose() {
    _drop.dispose();
    _sheen.dispose();
    super.dispose();
  }

  /// The slice of [_drop] during which letter [index] falls.
  Animation<double> _fallOf(int index) {
    final total = _drop.duration!.inMilliseconds;
    final start = (widget.perLetter.inMilliseconds * index) / total;
    final end = start + widget.letterFall.inMilliseconds / total;
    return CurvedAnimation(
      parent: _drop,
      // easeOutBack overshoots slightly past the resting position and comes
      // back: the letter lands with weight instead of gliding to a stop.
      curve: Interval(start, end.clamp(0.0, 1.0), curve: Curves.easeOutBack),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: widget.text,
      excludeSemantics: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          for (var i = 0; i < _letters.length; i++)
            AnimatedBuilder(
              animation: Listenable.merge([_fallOf(i), _sheen]),
              builder: (context, _) {
                final t = _fallOf(i).value;
                // 1 at the start of the fall, 0 once landed.
                final remaining = 1 - t;
                return Transform.translate(
                  offset: Offset(0, -widget.dropHeight * remaining),
                  child: Opacity(
                    // Fades in over the first part of the fall so letters do
                    // not pop into existence at the top of the frame.
                    opacity: t.clamp(0.0, 1.0),
                    child: Sculpted(
                      baseColor: widget.color,
                      depth: widget.depth,
                      steps: 6,
                      // Each letter sits a little further along the sweep
                      // than the one before, so the highlight travels across
                      // the word rather than flashing on all of it at once.
                      highlight: (_sheen.value + i / _letters.length) % 1.0,
                      // One shadow under the whole word would be right, but
                      // per-letter shadows at this size are indistinguishable
                      // and far cheaper than compositing the row.
                      shadow: false,
                      layer: (color) => Text(
                        _letters[i],
                        style: widget.style.copyWith(color: color),
                      ),
                    ),
                  ),
                );
              },
            ),
        ],
      ),
    );
  }
}
