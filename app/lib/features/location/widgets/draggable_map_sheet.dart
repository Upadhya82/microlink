import 'package:flutter/material.dart';

import '../../../core/theme/app_motion.dart';
import '../../../core/theme/app_spacing.dart';

/// A bottom sheet over a map that can be pulled down out of the way and
/// pulled back up again.
///
/// The map is the point of the screen and the sheet covers the bottom third
/// of it. Anyone comparing two shops on opposite sides of a junction needs
/// that space back, which is why this exists rather than the sheet being a
/// fixed panel.
///
/// Collapsed it leaves the handle and a one-line summary, so the sheet is
/// never actually gone -- someone who drags it away by accident can still
/// see where to get it back. Dragging either way works, and so does tapping
/// the bar, because a tap is easier than a deliberate drag and people try it
/// first.
class DraggableMapSheet extends StatefulWidget {
  const DraggableMapSheet({
    super.key,
    required this.child,
    required this.collapsedLabel,
    this.collapsedIcon = Icons.storefront_outlined,
  });

  final Widget child;

  /// What the bar says while the sheet is down, e.g. "4 shops near you".
  final String collapsedLabel;

  final IconData collapsedIcon;

  @override
  State<DraggableMapSheet> createState() => _DraggableMapSheetState();
}

class _DraggableMapSheetState extends State<DraggableMapSheet> {
  /// How much of the body is showing: 1 open, 0 collapsed. Held as a
  /// fraction rather than a pixel height so the drag maths does not care
  /// how tall the particular sheet happens to be -- a route sheet is much
  /// taller than a shop rail.
  double _extent = 1;

  bool _dragging = false;

  final GlobalKey _bodyKey = GlobalKey();

  /// Height of the content being revealed, measured from the laid-out body.
  /// Only used to turn finger pixels into a fraction, so the fallback just
  /// needs to be the right order of magnitude.
  double get _bodyHeight {
    final box = _bodyKey.currentContext?.findRenderObject() as RenderBox?;
    final height = box?.hasSize == true ? box!.size.height : 0.0;
    return height > 1 ? height : 200;
  }

  void _onDragUpdate(DragUpdateDetails details) {
    setState(() {
      // Dragging down reveals less of the sheet.
      _extent = (_extent - details.delta.dy / _bodyHeight).clamp(0.0, 1.0);
    });
  }

  void _onDragEnd(DragEndDetails details) {
    final velocity = details.velocity.pixelsPerSecond.dy;
    setState(() {
      _dragging = false;
      // A flick decides on its own, regardless of how far it travelled:
      // that is what the gesture means, and waiting for the halfway point
      // makes it feel sticky.
      if (velocity.abs() > 400) {
        _extent = velocity > 0 ? 0 : 1;
      } else {
        _extent = _extent >= 0.5 ? 1 : 0;
      }
    });
  }

  bool get _isCollapsed => _extent < 0.5;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    // The sheet may never take more than this much of the screen. Without a
    // ceiling a long shop rail pushes its own cards off the bottom edge on a
    // short window, which is exactly what it looks like: content cut off.
    final maxBody = MediaQuery.sizeOf(context).height * 0.42;

    return Material(
      color: colorScheme.surface,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(AppRadius.card + 6)),
      elevation: 8,
      shadowColor: Colors.black.withValues(alpha: 0.15),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            GestureDetector(
              onVerticalDragStart: (_) => setState(() => _dragging = true),
              onVerticalDragUpdate: _onDragUpdate,
              onVerticalDragEnd: _onDragEnd,
              onTap: () => setState(() => _extent = _isCollapsed ? 1 : 0),
              behavior: HitTestBehavior.opaque,
              child: _Handle(
                collapsed: _isCollapsed,
                label: widget.collapsedLabel,
                icon: widget.collapsedIcon,
              ),
            ),
            // Align with a height factor reveals the body without re-laying it
            // out: the child is measured once at full size and the parent just
            // shows part of it, which is what keeps the drag smooth.
            ClipRect(
              child: AnimatedAlign(
                alignment: Alignment.topCenter,
                heightFactor: _extent,
                duration: _dragging ? Duration.zero : AppMotion.medium,
                curve: AppMotion.emphasized,
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxHeight: maxBody),
                  child: SingleChildScrollView(
                    child: KeyedSubtree(key: _bodyKey, child: widget.child),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The grab area: the handle, plus a summary line that appears once the
/// sheet is down and the real header has gone with it.
class _Handle extends StatelessWidget {
  const _Handle({required this.collapsed, required this.label, required this.icon});

  final bool collapsed;
  final String label;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
          child: Container(
            width: 38,
            height: 4,
            decoration: BoxDecoration(
              color: colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(AppRadius.pill),
            ),
          ),
        ),
        AnimatedSize(
          duration: AppMotion.medium,
          curve: AppMotion.emphasized,
          child: collapsed
              ? Padding(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpacing.lg,
                    0,
                    AppSpacing.lg,
                    AppSpacing.md,
                  ),
                  child: Row(
                    children: [
                      Icon(icon, size: 18, color: colorScheme.onSurfaceVariant),
                      const SizedBox(width: AppSpacing.sm),
                      Expanded(
                        child: Text(
                          label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: textTheme.titleSmall,
                        ),
                      ),
                      Icon(
                        Icons.keyboard_arrow_up_rounded,
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ],
                  ),
                )
              : const SizedBox(width: double.infinity),
        ),
      ],
    );
  }
}
