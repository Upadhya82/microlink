import 'package:flutter/material.dart';

import '../../../core/l10n/app_strings.dart';
import '../../../core/theme/app_colors_extension.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/widgets/app_card.dart';
import '../../../core/widgets/stagger_in.dart';

/// "View App Information" (SRS use case). A plain, honest description of what
/// the app is for and who built it -- no marketing copy, and no claims about
/// features that are not in the build.
class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  static const String _version = '1.0.0 (MVP)';

  static const List<({IconData icon, String title, String body})> _capabilities = [
    (
      icon: Icons.storefront_outlined,
      title: 'Find micro-businesses',
      body: 'Search shops by name, category or landmark anywhere in Sri Lanka, '
          'and see whether they are open right now.',
    ),
    (
      icon: Icons.auto_awesome_outlined,
      title: 'Personalised suggestions',
      body: 'Recommendations that weigh distance, community trust and whether '
          'the shop can actually deliver.',
    ),
    (
      icon: Icons.map_outlined,
      title: 'Live map and navigation',
      body: 'Your live location, shops around you, and road routes with '
          'distance and travel time.',
    ),
    (
      icon: Icons.local_shipping_outlined,
      title: 'Community delivery',
      body: 'Order from a shop and let a registered local agent bring it to a '
          'delivery point you choose on the map.',
    ),
    (
      icon: Icons.people_outline,
      title: 'Built by the community',
      body: 'Report new shops, suggest corrections and flag road conditions so '
          'the data stays accurate.',
    ),
  ];


  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final colorScheme = Theme.of(context).colorScheme;
    final colors = context.appColors;

    return Scaffold(
      appBar: AppBar(title: Text(tr('about.title'))),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.lg),
        children: [
          StaggerIn(
            index: 0,
            child: Column(
              children: [
                Container(
                  width: 72,
                  height: 72,
                  decoration: BoxDecoration(
                    color: colorScheme.primaryContainer,
                    borderRadius: BorderRadius.circular(AppRadius.card + 4),
                  ),
                  child: Icon(
                    Icons.storefront_rounded,
                    size: 38,
                    color: colorScheme.primary,
                  ),
                ),
                const SizedBox(height: AppSpacing.md),
                Text(
                  tr('app.name'),
                  style: textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  tr('about.tagline'),
                  textAlign: TextAlign.center,
                  style: textTheme.bodyMedium?.copyWith(color: colors.textSecondary),
                ),
                const SizedBox(height: AppSpacing.sm),
                Text(
                  '${tr('about.version')} $_version',
                  style: textTheme.labelSmall?.copyWith(color: colors.textSecondary),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.xl),
          StaggerIn(
            index: 1,
            child: Text(
              tr('about.what_it_does'),
              style: textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          for (var i = 0; i < _capabilities.length; i++)
            StaggerIn(
              index: 2 + i,
              child: Padding(
                padding: const EdgeInsets.only(bottom: AppSpacing.md),
                child: AppCard(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(_capabilities[i].icon, color: colorScheme.primary, size: 22),
                      const SizedBox(width: AppSpacing.md),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _capabilities[i].title,
                              style: textTheme.bodyMedium
                                  ?.copyWith(fontWeight: FontWeight.w700),
                            ),
                            const SizedBox(height: AppSpacing.xs),
                            Text(
                              _capabilities[i].body,
                              style: textTheme.bodySmall
                                  ?.copyWith(color: colors.textSecondary),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          const SizedBox(height: AppSpacing.lg),
          StaggerIn(
            index: 7,
            child: AppCard(
              child: Text(
                'Institute of Technology, University of Moratuwa — Group 13',
                style: textTheme.labelSmall?.copyWith(color: colors.textSecondary),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
