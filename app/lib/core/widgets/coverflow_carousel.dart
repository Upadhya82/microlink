import 'package:flutter/material.dart';

/// A looping carousel that moves its items along a shallow arc: the item at
/// the front is upright, full size and sharp, while the ones either side are
/// smaller, dimmer and angled away as though turning out of view.
///
/// The loop is seamless because position is circular -- an item that leaves
/// one edge is already arriving at the other, so there is no jump back to the
/// start when the sequence completes.
///
/// It advances on its own and keeps going, but a drag takes over: carousels
/// that cannot be pushed are frustrating when the one you want has just gone
/// past. Letting go hands it back to the timer from wherever it was left.
class CoverflowCarousel extends StatefulWidget {
  final int itemCount;

  /// Builds item [index]. Called for the few items near the front on every
  /// frame, so it should be cheap.
  final IndexedWidgetBuilder itemBuilder;

  /// Width of a single item at full size.
  final double itemWidth;

  /// Height of the whole carousel.
  final double height;

  /// Time from one item reaching the front to the next doing so, including
  /// the moment it rests there.
  final Duration step;

  /// The fraction of each [step] spent moving; the rest is the item sitting
  /// still at the front. Lower means a longer look at each card before the
  /// next one comes round.
  final double movePortion;

  /// How far apart neighbouring items sit, as a fraction of [itemWidth].
  /// Below about 0.6 they overlap heavily, which is the coverflow look;
  /// above 1 they separate into a plain row.
  final double spacing;

  /// How far each step away from the front turns an item, in radians.
  final double turn;

  const CoverflowCarousel({
    super.key,
    required this.itemCount,
    required this.itemBuilder,
    this.itemWidth = 190,
    this.height = 246,
    this.step = const Duration(milliseconds: 4200),
    this.movePortion = 0.45,
    this.spacing = 0.72,
    this.turn = 0.5,
  });

  @override
  State<CoverflowCarousel> createState() => _CoverflowCarouselState();
}

class _CoverflowCarouselState extends State<CoverflowCarousel>
    with SingleTickerProviderStateMixin {
  /// Items further than this from the front are not built at all. Three deep
  /// is past the point anything is legible.
  static const int _visibleDepth = 2;

  late final AnimationController _controller =
      AnimationController(vsync: this, duration: widget.step);

  /// Which item is at the front at the start of the current step.
  int _base = 0;

  /// Offset contributed by an in-progress drag, in item positions.
  double _drag = 0;
  bool _dragging = false;

  @override
  void initState() {
    super.initState();
    _controller.addStatusListener(_onStepComplete);
    _start();
  }

  @override
  void didUpdateWidget(CoverflowCarousel oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The list can arrive or change length after the first build.
    if (oldWidget.itemCount != widget.itemCount) {
      _base = widget.itemCount == 0 ? 0 : _base % widget.itemCount;
    }
  }

  void _start() {
    if (widget.itemCount > 1) _controller.forward(from: 0);
  }

  void _onStepComplete(AnimationStatus status) {
    if (status != AnimationStatus.completed) return;
    setState(() => _base = (_base + 1) % widget.itemCount);
    if (!_dragging) _controller.forward(from: 0);
  }

  @override
  void dispose() {
    _controller.removeStatusListener(_onStepComplete);
    _controller.dispose();
    super.dispose();
  }

  /// Where the carousel currently sits, in fractional item positions.
  double get _position {
    final eased = Interval(0, widget.movePortion, curve: Curves.easeInOutCubic)
        .transform(_controller.value);
    return _base + eased + _drag;
  }

  /// How far item [index] is from the front, taking the shorter way round.
  /// This is what makes the loop seamless: an item at one end of the list is
  /// a short distance from one at the other end, not a whole list away.
  double _offsetOf(int index, double position) {
    final count = widget.itemCount;
    var delta = index - position;
    final half = count / 2;
    while (delta > half) {
      delta -= count;
    }
    while (delta < -half) {
      delta += count;
    }
    return delta;
  }

  void _onDragStart(DragStartDetails _) {
    _dragging = true;
    _controller.stop();
  }

  void _onDragUpdate(DragUpdateDetails details) {
    setState(() => _drag -= details.primaryDelta! / (widget.itemWidth * widget.spacing));
  }

  void _onDragEnd(DragEndDetails _) {
    _dragging = false;
    // Fold the drag into the base so the next step starts from where the
    // finger left off rather than snapping back.
    final settled = (_base + _drag).round();
    setState(() {
      _base = settled % widget.itemCount;
      if (_base < 0) _base += widget.itemCount;
      _drag = 0;
    });
    _controller.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    if (widget.itemCount == 0) return SizedBox(height: widget.height);
    // One item has nowhere to travel to; two makes the "shorter way round"
    // ambiguous and the arc reads as a flicker. Below three, show it plainly.
    if (widget.itemCount < 3) {
      return SizedBox(
        height: widget.height,
        child: Center(
          child: SizedBox(width: widget.itemWidth, child: widget.itemBuilder(context, 0)),
        ),
      );
    }

    final reduceMotion = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    if (reduceMotion && _controller.isAnimating) _controller.stop();

    return GestureDetector(
      onHorizontalDragStart: _onDragStart,
      onHorizontalDragUpdate: _onDragUpdate,
      onHorizontalDragEnd: _onDragEnd,
      child: SizedBox(
        height: widget.height,
        child: AnimatedBuilder(
          animation: _controller,
          builder: (context, _) {
            final position = _position;

            // Collect the few items near the front, then draw them furthest
            // first so nearer ones overlap them.
            final entries = <({int index, double offset})>[];
            for (var i = 0; i < widget.itemCount; i++) {
              final offset = _offsetOf(i, position);
              if (offset.abs() <= _visibleDepth) {
                entries.add((index: i, offset: offset));
              }
            }
            entries.sort((a, b) => b.offset.abs().compareTo(a.offset.abs()));

            return Stack(
              alignment: Alignment.center,
              children: [
                for (final entry in entries)
                  _ArcItem(
                    offset: entry.offset,
                    itemWidth: widget.itemWidth,
                    spacing: widget.spacing,
                    turn: widget.turn,
                    child: widget.itemBuilder(context, entry.index),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// One item placed on the arc according to how far it is from the front.
class _ArcItem extends StatelessWidget {
  /// Distance from the front, in item positions. 0 is dead centre, negative
  /// is to the left.
  final double offset;
  final double itemWidth;
  final double spacing;
  final double turn;
  final Widget child;

  const _ArcItem({
    required this.offset,
    required this.itemWidth,
    required this.spacing,
    required this.turn,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final distance = offset.abs();

    // Shrinking and fading with distance is what reads as depth; the scale
    // floor stops a far item collapsing to nothing before it is culled.
    final scale = (1 - 0.16 * distance).clamp(0.6, 1.0);
    final opacity = (1 - 0.34 * distance).clamp(0.0, 1.0);

    // Pulling items slightly towards the centre as they recede bends the row
    // into an arc rather than a straight line.
    final dx = offset * itemWidth * spacing * (1 - 0.08 * distance);
    // ... and lifting them a little sets them back rather than beside.
    final dy = distance * 6;

    return Transform(
      alignment: Alignment.center,
      transform: Matrix4.identity()
        ..setEntry(3, 2, 0.0012)
        ..translateByDouble(dx, dy, 0, 1)
        ..rotateY(-offset * turn)
        ..scaleByDouble(scale, scale, 1, 1),
      child: Opacity(
        opacity: opacity,
        // Only the item at the front takes taps. Without this a tap near the
        // middle can land on a card that is mostly hidden behind it.
        child: IgnorePointer(
          ignoring: distance > 0.5,
          child: SizedBox(width: itemWidth, child: child),
        ),
      ),
    );
  }
}
