import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/models/shop.dart' show formatCategoryLabel;
import '../../../core/theme/app_colors_extension.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/utils/category_style.dart';
import '../../../core/utils/media_url.dart';
import '../../../core/utils/route_args.dart';
import 'suggestion_comments.dart';

/// Everything a neighbour needs before answering "is this shop really there?".
///
/// The confirm list showed a name, an address and two buttons. That is not
/// enough to answer honestly: someone who has walked past the junction a
/// hundred times still cannot tell which shop is meant from "Pitipana", and
/// the photo the reporter took -- the one thing that settles it -- was a
/// 56px thumbnail. People were being asked to vouch for a place they could
/// not see, and a wrong yes is worse than no answer at all, because the
/// shop goes onto the map on the strength of it.
///
/// The report already carries the category, hours, phone, description,
/// coordinates and the photo; none of it was being shown. This puts all of
/// it in front of the person before they commit, with the two buttons at
/// the bottom so the answer is the last thing they do, not the first.
Future<void> showShopReportDetails(
  BuildContext context, {
  required Map<String, dynamic> report,
  required bool busy,
  LatLng? here,
  required void Function(bool confirms) onAnswer,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (sheetContext) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.8,
      maxChildSize: 0.95,
      builder: (context, controller) => _Details(
        report: report,
        busy: busy,
        here: here,
        scrollController: controller,
        onAnswer: onAnswer,
      ),
    ),
  );
}

class _Details extends StatelessWidget {
  final Map<String, dynamic> report;
  final bool busy;
  final LatLng? here;
  final ScrollController scrollController;
  final void Function(bool confirms) onAnswer;

  const _Details({
    required this.report,
    required this.busy,
    required this.here,
    required this.scrollController,
    required this.onAnswer,
  });

  String get _name => report['shop_name']?.toString() ?? 'A new shop';
  String get _category => report['category']?.toString() ?? 'other';

  String? get _hours {
    final open = report['opening_time']?.toString();
    final close = report['closing_time']?.toString();
    if (open == null || close == null || open.isEmpty || close.isEmpty) {
      return null;
    }
    return '$open – $close';
  }

  /// Straight-line distance, worked out on the device. The report has
  /// coordinates but the server does not send a distance, and the screen
  /// already knows where the person is.
  String? get _distance {
    final point = here;
    final lat = (report['latitude'] as num?)?.toDouble();
    final lng = (report['longitude'] as num?)?.toDouble();
    if (point == null || lat == null || lng == null) return null;
    final km = const Distance().as(
      LengthUnit.Kilometer,
      point,
      LatLng(lat, lng),
    );
    return km < 1
        ? '${(km * 1000).round()} m away'
        : '${km.toStringAsFixed(1)} km away';
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final colors = context.appColors;
    final tint = categoryColors(context, _category);

    final photo = mediaUrl(report['photo_path']?.toString() ??
        ((report['has_photo'] as bool? ?? false)
            ? '/crowdsource/shop-reports/${report['id']}/photo'
            : null));
    final responses = (report['responses'] as num?)?.toInt() ?? 0;
    final confirmations = (report['confirmations'] as num?)?.toInt() ?? 0;
    final address = report['address']?.toString() ?? '';
    final phone = report['phone']?.toString() ?? '';
    final description = report['description']?.toString() ?? '';

    Widget line(IconData icon, String text, {String? label}) => Padding(
          padding: const EdgeInsets.only(bottom: AppSpacing.md),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, size: 18, color: colors.textSecondary),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (label != null)
                      Text(
                        label,
                        style: textTheme.labelSmall
                            ?.copyWith(color: colors.textSecondary),
                      ),
                    Text(text, style: textTheme.bodyMedium),
                  ],
                ),
              ),
            ],
          ),
        );

    return Column(
      children: [
        Expanded(
          child: SingleChildScrollView(
            controller: scrollController,
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.lg,
              0,
              AppSpacing.lg,
              AppSpacing.lg,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // The photo the reporter took, big enough to recognise a
                // shopfront by, and tappable to fill the screen.
                ClipRRect(
                  borderRadius: BorderRadius.circular(AppRadius.card),
                  child: SizedBox(
                    width: double.infinity,
                    height: 190,
                    child: photo == null
                        ? _NoPhoto(category: _category)
                        : InkWell(
                            onTap: () => _openFullScreen(context, photo),
                            child: Image.network(
                              photo,
                              fit: BoxFit.cover,
                              errorBuilder: (_, _, _) =>
                                  _NoPhoto(category: _category),
                              loadingBuilder: (_, child, progress) =>
                                  progress == null
                                      ? child
                                      : Container(
                                          color: tint.background,
                                          alignment: Alignment.center,
                                          child:
                                              const CircularProgressIndicator(),
                                        ),
                            ),
                          ),
                  ),
                ),
                const SizedBox(height: AppSpacing.md),
                Text(
                  _name,
                  style:
                      textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 4),
                Wrap(
                  spacing: AppSpacing.sm,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    _Pill(
                      icon: categoryIcon(_category),
                      label: formatCategoryLabel(_category),
                      background: tint.background,
                      foreground: tint.foreground,
                    ),
                    if (_distance != null)
                      Text(
                        _distance!,
                        style: textTheme.bodySmall
                            ?.copyWith(color: colors.textSecondary),
                      ),
                  ],
                ),
                if (responses > 0) ...[
                  const SizedBox(height: AppSpacing.sm),
                  Text(
                    confirmations == responses
                        ? (responses == 1
                            ? '1 neighbour has answered, and said yes'
                            : 'All $responses neighbours who answered said yes')
                        : '$confirmations of $responses neighbours said yes',
                    style: textTheme.bodySmall
                        ?.copyWith(color: colors.textSecondary),
                  ),
                ],
                const SizedBox(height: AppSpacing.md),
                const Divider(height: 1),
                const SizedBox(height: AppSpacing.md),
                if (address.isNotEmpty)
                  line(Icons.place_outlined, address, label: 'Address'),
                if (_hours != null)
                  line(Icons.schedule_outlined, _hours!, label: 'Opening hours'),
                if (phone.trim().isNotEmpty)
                  line(Icons.call_outlined, phone, label: 'Phone'),
                if (description.trim().isNotEmpty)
                  line(Icons.notes_outlined, description,
                      label: 'What the reporter said'),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.map_outlined),
                    label: const Text('See where it is on the map'),
                    onPressed: () {
                      final lat = (report['latitude'] as num?)?.toDouble();
                      final lng = (report['longitude'] as num?)?.toDouble();
                      if (lat == null || lng == null) return;
                      Navigator.pop(context);
                      Navigator.pushNamed(
                        context,
                        AppRoutes.liveMap,
                        arguments: LiveMapArgs(
                          destinationLat: lat,
                          destinationLng: lng,
                          destinationLabel: _name,
                        ),
                      );
                    },
                  ),
                ),
                const SizedBox(height: AppSpacing.lg),
                const Divider(height: 1),
                const SizedBox(height: AppSpacing.md),
                // What other neighbours already said, and a box to add to it.
                SuggestionCommentsSection(reportId: report['id'].toString()),
              ],
            ),
          ),
        ),
        // The answer stays pinned at the bottom, after everything above it
        // has had a chance to be read.
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.lg,
              AppSpacing.sm,
              AppSpacing.lg,
              AppSpacing.sm,
            ),
            child: Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: busy
                        ? null
                        : () {
                            Navigator.pop(context);
                            onAnswer(true);
                          },
                    icon: const Icon(Icons.check_rounded, size: 18),
                    label: const Text('Yes, it is there'),
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: busy
                        ? null
                        : () {
                            Navigator.pop(context);
                            onAnswer(false);
                          },
                    icon: const Icon(Icons.close_rounded, size: 18),
                    label: const Text('No'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  void _openFullScreen(BuildContext context, String url) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (viewerContext) => Scaffold(
          backgroundColor: Colors.black,
          appBar: AppBar(
            backgroundColor: Colors.black,
            foregroundColor: Colors.white,
            title: Text(_name),
          ),
          body: Center(
            // Pinch to zoom: a shopfront sign is often the only way to tell
            // one small shop from another.
            child: InteractiveViewer(
              maxScale: 5,
              child: Image.network(
                url,
                fit: BoxFit.contain,
                errorBuilder: (_, _, _) => const Icon(
                  Icons.broken_image_outlined,
                  color: Colors.white54,
                  size: 64,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Shown in place of the photo when the reporter did not attach one.
///
/// Says so in words rather than leaving a blank box, because "no photo" is
/// itself worth knowing before you vouch for a place.
class _NoPhoto extends StatelessWidget {
  final String category;

  const _NoPhoto({required this.category});

  @override
  Widget build(BuildContext context) {
    final tint = categoryColors(context, category);
    return Container(
      color: tint.background,
      alignment: Alignment.center,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(categoryIcon(category), color: tint.foreground, size: 36),
          const SizedBox(height: AppSpacing.sm),
          Text(
            'No photo was attached',
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: tint.foreground),
          ),
        ],
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color background;
  final Color foreground;

  const _Pill({
    required this.icon,
    required this.label,
    required this.background,
    required this.foreground,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(AppRadius.pill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: foreground),
          const SizedBox(width: 4),
          Text(
            label,
            style: Theme.of(context)
                .textTheme
                .labelSmall
                ?.copyWith(color: foreground, fontWeight: FontWeight.w700),
          ),
        ],
      ),
    );
  }
}
