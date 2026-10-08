import 'package:flutter/material.dart';

import '../theme/app_colors_extension.dart';
import '../theme/app_spacing.dart';
import '../utils/view_state.dart';
import 'fade_in.dart';

/// Renders a [ViewState] with the app's standard loading / empty / error
/// treatment so every screen behaves the same way. [isEmpty] decides whether
/// loaded data should be shown via [builder] or via the empty-state UI.
class AsyncStateView<T> extends StatelessWidget {
  final ViewState<T> state;
  final Widget Function(BuildContext context, T data) builder;
  final bool Function(T data)? isEmpty;
  final String emptyTitle;
  final String emptyMessage;
  final IconData emptyIcon;
  final VoidCallback onRetry;
  final Widget? loadingSkeleton;

  const AsyncStateView({
    super.key,
    required this.state,
    required this.builder,
    required this.onRetry,
    this.isEmpty,
    this.emptyTitle = 'Nothing here yet',
    this.emptyMessage = 'Check back later.',
    this.emptyIcon = Icons.inbox_outlined,
    this.loadingSkeleton,
  });

  @override
  Widget build(BuildContext context) {
    final state = this.state;
    return switch (state) {
      ViewLoading<T>() => loadingSkeleton ?? const _DefaultLoading(),
      ViewError<T>(:final message) => _ErrorState(message: message, onRetry: onRetry),
      ViewData<T>(:final data) => (isEmpty?.call(data) ?? false)
          ? _EmptyState(title: emptyTitle, message: emptyMessage, icon: emptyIcon)
          : FadeIn(child: builder(context, data)),
    };
  }
}

class _DefaultLoading extends StatelessWidget {
  const _DefaultLoading();

  @override
  Widget build(BuildContext context) {
    return const Center(child: CircularProgressIndicator());
  }
}

class _EmptyState extends StatelessWidget {
  final String title;
  final String message;
  final IconData icon;

  const _EmptyState({required this.title, required this.message, required this.icon});

  @override
  Widget build(BuildContext context) {
    final colors = context.appColors;
    return FadeIn(
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.xxl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 56, color: colors.textSecondary),
              const SizedBox(height: AppSpacing.lg),
              Text(title, style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: AppSpacing.xs),
              Text(
                message,
                textAlign: TextAlign.center,
                style: Theme.of(context)
                    .textTheme
                    .bodyMedium
                    ?.copyWith(color: colors.textSecondary),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;

  const _ErrorState({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final colors = context.appColors;
    return FadeIn(
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.xxl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.cloud_off_rounded, size: 56, color: Theme.of(context).colorScheme.error),
              const SizedBox(height: AppSpacing.lg),
              Text('Something went wrong', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: AppSpacing.xs),
              Text(
                message,
                textAlign: TextAlign.center,
                style: Theme.of(context)
                    .textTheme
                    .bodyMedium
                    ?.copyWith(color: colors.textSecondary),
              ),
              const SizedBox(height: AppSpacing.lg),
              OutlinedButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('Retry'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
