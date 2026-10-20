import 'package:flutter/material.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/l10n/app_strings.dart';
import '../../../core/network/session_manager.dart';
import '../../../core/theme/app_colors_extension.dart';
import '../../../core/theme/app_motion.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/theme_controller.dart';
import '../../../core/widgets/app_card.dart';
import '../../../core/widgets/stagger_in.dart';
import '../../navigation/voice_guidance.dart';
import '../../../core/widgets/branded_app_bar.dart';

/// Settings (SRS use case "Configure Application Settings").
///
/// Language and theme live here because REQ-PERS-1/2/3 treat them as one
/// concern: user-chosen presentation, persisted locally, reapplied on launch.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([
        LanguageController.instance,
        ThemeController.instance,
      ]),
      builder: (context, _) {
        return Scaffold(
          appBar: BrandedAppBar(title: Text(tr('settings.title'))),
          body: ListView(
            padding: const EdgeInsets.all(AppSpacing.lg),
            children: [
              StaggerIn(index: 0, child: _LanguageSection()),
              const SizedBox(height: AppSpacing.lg),
              StaggerIn(index: 1, child: _AppearanceSection()),
              const SizedBox(height: AppSpacing.lg),
              // Item 15: try the voice here, rather than finding out it is
              // silent while driving.
              StaggerIn(index: 2, child: const _VoiceSection()),
              const SizedBox(height: AppSpacing.lg),
              StaggerIn(index: 3, child: _AboutSection()),
              if (SessionManager.instance.isLoggedIn) ...[
                const SizedBox(height: AppSpacing.xl),
                StaggerIn(index: 4, child: _LogoutButton()),
              ],
            ],
          ),
        );
      },
    );
  }
}

class _SectionCard extends StatelessWidget {
  final String title;
  final String? subtitle;
  final Widget child;

  const _SectionCard({required this.title, this.subtitle, required this.child});

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final colors = context.appColors;
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
          if (subtitle != null) ...[
            const SizedBox(height: AppSpacing.xs),
            Text(
              subtitle!,
              style: textTheme.bodySmall?.copyWith(color: colors.textSecondary),
            ),
          ],
          const SizedBox(height: AppSpacing.md),
          child,
        ],
      ),
    );
  }
}

class _LanguageSection extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final current = LanguageController.instance.language;
    final colorScheme = Theme.of(context).colorScheme;
    final colors = context.appColors;
    final coverage = translationCoverage(current.code);

    return _SectionCard(
      title: tr('settings.language'),
      subtitle: tr('settings.language_subtitle'),
      child: Column(
        children: [
          for (final language in AppLanguage.supported)
            _LanguageTile(
              language: language,
              selected: language.code == current.code,
              onTap: () => LanguageController.instance.setLanguage(language),
            ),
          // Honest about partial coverage rather than letting the user find
          // half-English screens by surprise.
          if (coverage < 100) ...[
            const SizedBox(height: AppSpacing.md),
            Container(
              padding: const EdgeInsets.all(AppSpacing.md),
              decoration: BoxDecoration(
                color: colorScheme.secondaryContainer.withValues(alpha: 0.6),
                borderRadius: BorderRadius.circular(AppRadius.input),
              ),
              child: Row(
                children: [
                  Icon(Icons.info_outline, size: 18, color: colors.textSecondary),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: Text(
                      tr('settings.partially_translated'),
                      style: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.copyWith(color: colorScheme.onSecondaryContainer),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _LanguageTile extends StatelessWidget {
  final AppLanguage language;
  final bool selected;
  final VoidCallback onTap;

  const _LanguageTile({
    required this.language,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final colors = context.appColors;

    return AnimatedContainer(
      duration: AppMotion.fast,
      curve: AppMotion.standard,
      margin: const EdgeInsets.only(bottom: AppSpacing.sm),
      decoration: BoxDecoration(
        color: selected
            ? colorScheme.primaryContainer.withValues(alpha: 0.7)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(AppRadius.input),
        border: Border.all(
          color: selected ? colorScheme.primary : colorScheme.outlineVariant,
          width: selected ? 1.5 : 1,
        ),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.input),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md,
            vertical: AppSpacing.md,
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      language.nativeName,
                      style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                          ),
                    ),
                    if (language.nativeName != language.englishName)
                      Text(
                        language.englishName,
                        style: Theme.of(context)
                            .textTheme
                            .bodySmall
                            ?.copyWith(color: colors.textSecondary),
                      ),
                  ],
                ),
              ),
              AnimatedScale(
                duration: AppMotion.fast,
                curve: AppMotion.emphasized,
                scale: selected ? 1 : 0,
                child: Icon(Icons.check_circle, color: colorScheme.primary),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AppearanceSection extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return _SectionCard(
      title: tr('settings.theme'),
      child: SwitchListTile(
        contentPadding: EdgeInsets.zero,
        secondary: AnimatedSwitcher(
          duration: AppMotion.medium,
          transitionBuilder: (child, animation) => RotationTransition(
            turns: Tween(begin: 0.6, end: 1.0).animate(animation),
            child: FadeTransition(opacity: animation, child: child),
          ),
          child: Icon(
            isDark ? Icons.dark_mode_outlined : Icons.light_mode_outlined,
            key: ValueKey(isDark),
          ),
        ),
        title: Text(tr('settings.dark_mode')),
        subtitle: Text(tr('settings.dark_mode_subtitle')),
        value: isDark,
        onChanged: (_) => ThemeController.instance.toggle(Theme.of(context).brightness),
      ),
    );
  }
}

/// Item 15: "Test voice" (REQ-NAV-3).
///
/// Voice guidance was reported as doing nothing, and there was no way to
/// tell a muted app from a device with no voice installed for the chosen
/// language. This speaks one sample sentence in the language that is
/// selected right now, and says plainly when it had to fall back to
/// English.
class _VoiceSection extends StatefulWidget {
  const _VoiceSection();

  @override
  State<_VoiceSection> createState() => _VoiceSectionState();
}

class _VoiceSectionState extends State<_VoiceSection> {
  final VoiceGuidance _voice = VoiceGuidance();
  bool _speaking = false;

  @override
  void dispose() {
    _voice.dispose();
    super.dispose();
  }

  Future<void> _test() async {
    setState(() => _speaking = true);
    try {
      // The route screen gets its locale from navigation-service; here the
      // language the user has chosen is the only thing to go on.
      await _voice.setRoute(
        const [],
        voiceLocale: voiceLocaleFor(LanguageController.instance.code),
      );
      // force: a muted app must still be able to test its own voice.
      await _voice.speak(tr('settings.voice_sample'), force: true);
      if (!mounted) return;
      final notice = _voice.takeFallbackNotice();
      if (notice != null) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(notice)));
      }
    } finally {
      if (mounted) setState(() => _speaking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return _SectionCard(
      title: tr('settings.voice'),
      subtitle: tr('settings.voice_subtitle'),
      child: Align(
        alignment: Alignment.centerLeft,
        child: OutlinedButton.icon(
          onPressed: _speaking ? null : _test,
          icon: Icon(_speaking ? Icons.graphic_eq_rounded : Icons.volume_up_outlined),
          label: Text(
            _speaking ? tr('settings.voice_testing') : tr('settings.test_voice'),
          ),
        ),
      ),
    );
  }
}

class _AboutSection extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return AppCard(
      onTap: () => Navigator.pushNamed(context, AppRoutes.about),
      child: Row(
        children: [
          Icon(Icons.info_outline, color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  tr('settings.about'),
                  style: Theme.of(context)
                      .textTheme
                      .titleSmall
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
                Text(
                  tr('settings.about_subtitle'),
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: context.appColors.textSecondary),
                ),
              ],
            ),
          ),
          const Icon(Icons.chevron_right),
        ],
      ),
    );
  }
}

class _LogoutButton extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return OutlinedButton.icon(
      onPressed: () async {
        final navigator = Navigator.of(context);
        await SessionManager.instance.clearSession();
        navigator.pushNamedAndRemoveUntil(AppRoutes.login, (route) => false);
      },
      icon: const Icon(Icons.logout),
      label: Text(tr('auth.logout')),
      style: OutlinedButton.styleFrom(
        foregroundColor: colorScheme.error,
        side: BorderSide(color: colorScheme.error.withValues(alpha: 0.5)),
        minimumSize: const Size.fromHeight(48),
      ),
    );
  }
}
