import 'package:flutter/material.dart';

import '../../../core/location/location_service.dart';
import '../../../core/network/api_client.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/theme/app_colors_extension.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/utils/media_url.dart';
import '../../../core/utils/view_state.dart';
import '../../../core/widgets/app_card.dart';
import '../../../core/widgets/async_state_view.dart';
import '../../../core/widgets/branded_app_bar.dart';
import '../../../core/widgets/skeleton_list.dart';
import '../../../core/widgets/stagger_in.dart';

/// "Confirm shops near you" (item 6).
///
/// crowdsource-service has had `/shop-reports/nearby` and `/confirm` all
/// along, with no screen anywhere in the app -- so a crowd-reported shop
/// could never collect the confirmations it needs and sat in the admin queue
/// as one person's unsupported claim.
///
/// Only offered to accounts that may actually confirm (item 7); the server
/// decides that and says so on `/crowdsource/trust-score/me`, which is also
/// what hides the entry point on the home screen.
class ConfirmShopsScreen extends StatefulWidget {
  const ConfirmShopsScreen({super.key});

  @override
  State<ConfirmShopsScreen> createState() => _ConfirmShopsScreenState();
}

class _ConfirmShopsScreenState extends State<ConfirmShopsScreen> {
  ViewState<List<Map<String, dynamic>>> _state = const ViewLoading();

  /// Reports being answered, so a double tap cannot send two answers.
  final Set<String> _answering = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _state = const ViewLoading());
    try {
      final location = await LocationService.instance.currentPosition();
      if (!location.isReal) {
        // Falling back to Colombo here would ask people to vouch for shops
        // on the other side of the country, which is worse than saying so.
        if (!mounted) return;
        setState(
          () => _state = const ViewError(
            'MicroLink needs your location to find shops reported near you.',
          ),
        );
        return;
      }
      final point = location.position;
      final response = await ApiClient.instance.get(
        '/crowdsource/shop-reports/nearby'
        '?lat=${point.latitude}&lng=${point.longitude}&radius_km=3',
      );
      final rows = (response as List)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
      if (!mounted) return;
      setState(() => _state = ViewData(rows));
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _state = ViewError(e.message));
    } catch (_) {
      if (!mounted) return;
      setState(
        () => _state = const ViewError('Could not load shops near you.'),
      );
    }
  }

  Future<void> _answer(Map<String, dynamic> report, bool confirms) async {
    final id = report['id'] as String;
    if (_answering.contains(id)) return;
    setState(() => _answering.add(id));
    try {
      await ApiClient.instance.post(
        '/crowdsource/shop-reports/$id/confirm',
        body: {'confirms': confirms},
      );
      if (!mounted) return;
      // Answered reports drop off the server's list, so take it off this one
      // too rather than re-fetching and making the user wait.
      final current = _state;
      if (current is ViewData<List<Map<String, dynamic>>>) {
        setState(() {
          _state = ViewData(
            current.data.where((row) => row['id'] != id).toList(),
          );
        });
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            confirms ? 'Thanks — marked as there.' : 'Thanks — marked as not there.',
          ),
        ),
      );
    } on ApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => _answering.remove(id));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: const BrandedAppBar(title: Text('Confirm shops near you')),
      body: RefreshIndicator(
        onRefresh: _load,
        child: AsyncStateView<List<Map<String, dynamic>>>(
          state: _state,
          onRetry: _load,
          isEmpty: (data) => data.isEmpty,
          emptyTitle: 'Nothing to confirm',
          emptyMessage:
              'No one has reported a new shop near you, or you have already '
              'answered about the ones there are.',
          emptyIcon: Icons.how_to_reg_outlined,
          loadingSkeleton: const SkeletonList(itemCount: 3, itemHeight: 120),
          builder: (context, reports) => ListView.separated(
            padding: const EdgeInsets.all(AppSpacing.lg),
            itemCount: reports.length + 1,
            separatorBuilder: (_, _) => const SizedBox(height: AppSpacing.md),
            itemBuilder: (context, index) {
              if (index == 0) {
                return Padding(
                  padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                  child: Text(
                    'Neighbours reported these shops. Telling us whether they '
                    'are really there is what gets them onto the map.',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: context.appColors.textSecondary,
                        ),
                  ),
                );
              }
              final report = reports[index - 1];
              return StaggerIn(
                index: index,
                child: _ReportCard(
                  report: report,
                  busy: _answering.contains(report['id']),
                  onAnswer: (confirms) => _answer(report, confirms),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _ReportCard extends StatelessWidget {
  final Map<String, dynamic> report;
  final bool busy;
  final void Function(bool confirms) onAnswer;

  const _ReportCard({
    required this.report,
    required this.busy,
    required this.onAnswer,
  });

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final colors = context.appColors;
    final hasPhoto = report['has_photo'] as bool? ?? false;
    final photoUrl = hasPhoto
        ? mediaUrl('/crowdsource/shop-reports/${report['id']}/photo')
        : null;
    final confirmations = (report['confirmations'] as num?)?.toInt() ?? 0;

    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (photoUrl != null)
                ClipRRect(
                  borderRadius: BorderRadius.circular(AppRadius.input),
                  child: Image.network(
                    photoUrl,
                    width: 56,
                    height: 56,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) =>
                        const Icon(Icons.storefront_outlined, size: 56),
                  ),
                )
              else
                Icon(Icons.storefront_outlined, size: 56, color: colors.textSecondary),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      report['shop_name'] as String? ?? 'A new shop',
                      style: textTheme.titleSmall
                          ?.copyWith(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      report['address'] as String? ?? '',
                      style: textTheme.bodySmall
                          ?.copyWith(color: colors.textSecondary),
                    ),
                    if (confirmations > 0) ...[
                      const SizedBox(height: 2),
                      Text(
                        confirmations == 1
                            ? '1 neighbour has answered'
                            : '$confirmations neighbours have answered',
                        style: textTheme.labelSmall
                            ?.copyWith(color: colors.textSecondary),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: busy ? null : () => onAnswer(true),
                  icon: const Icon(Icons.check_rounded, size: 18),
                  label: const Text('Yes, it is there'),
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: busy ? null : () => onAnswer(false),
                  icon: const Icon(Icons.close_rounded, size: 18),
                  label: const Text('No'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
