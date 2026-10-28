import 'package:flutter/material.dart';

import '../../../core/l10n/app_strings.dart';
import '../../../core/constants/app_constants.dart';
import '../../../core/models/app_notification.dart';
import '../../../core/network/api_client.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/network/session_manager.dart';
import '../../../core/theme/app_motion.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/utils/validators.dart';
import '../../../core/widgets/app_button.dart';
import '../../../core/widgets/app_text_field.dart';
import '../../../core/widgets/required_fields_note.dart';
import '../../../core/widgets/dropping_wordmark.dart';
import '../../../core/widgets/obscure_reveal_controller.dart';
import '../../../core/widgets/pop_in.dart';
import '../../../core/widgets/sculpted.dart';
import '../../../core/widgets/spinning_logo.dart';
import '../../../core/widgets/wave_text.dart';

/// The Login screen: email + password sign-in against `POST /auth/login`.
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  // An ObscureRevealController lets AppTextField wipe the mask across the
  // text when the eye is tapped instead of switching it in one frame.
  final _passwordController = ObscureRevealController();

  bool _obscurePassword = true;
  bool _isSubmitting = false;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final formState = _formKey.currentState;
    if (formState == null || !formState.validate()) return;

    setState(() => _isSubmitting = true);

    try {
      final response = await ApiClient.instance.post(
        '/auth/login',
        body: {
          'email': _emailController.text.trim(),
          'password': _passwordController.text,
        },
      ) as Map<String, dynamic>;

      final token = response['access_token'] as String;
      final user = response['user'] as Map<String, dynamic>;

      await SessionManager.instance.saveSession(
        token: token,
        userId: user['id'] as String,
        role: user['role'] as String,
        name: user['full_name'] as String,
      );

      if (!mounted) return;
      await _greetIfJustVerified(user['role'] as String?);
      if (!mounted) return;
      Navigator.pushNamedAndRemoveUntil(context, AppRoutes.home, (route) => false);
    } on ApiException catch (e) {
      if (!mounted) return;
      // An unapproved shop owner or agent is refused here, and this is the
      // only place they can read the admin's decision -- a snackbar is gone
      // before a rejection reason can be read.
      if (e.isForbidden) {
        await _showRefusal(e.message);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
      }
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  Future<void> _showRefusal(String message) {
    final rejected = message.contains('not approved');
    final waiting = message.contains('waiting for admin approval');
    return showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        icon: Icon(
          rejected
              ? Icons.cancel_outlined
              : (waiting ? Icons.hourglass_top_rounded : Icons.block_outlined),
          color: rejected ? Theme.of(dialogContext).colorScheme.error : null,
        ),
        title: Text(
          rejected
              ? 'Application not approved'
              : (waiting ? 'Waiting for approval' : 'Cannot sign in'),
        ),
        content: Text(message),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  /// A shop owner or agent signing in for the first time since an admin
  /// approved them is shown the "Congratulations! You are verified" message
  /// admin-service stored for them (link route "verified"), then it is
  /// marked read so it greets them once. Best effort: never holds up login.
  Future<void> _greetIfJustVerified(String? role) async {
    if (role != 'shop_owner' && role != 'delivery_agent') return;
    try {
      final rows = await ApiClient.instance.get(
        '/notifications/me',
        query: {'unread_only': true, 'limit': 20},
      ) as List;
      final greeting = rows
          .whereType<Map>()
          .map((e) => AppNotification.fromJson(Map<String, dynamic>.from(e)))
          .where((n) => n.linkRoute == 'verified')
          .firstOrNull;
      if (greeting == null || !mounted) return;
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          icon: const Icon(Icons.verified_rounded, size: 40),
          title: Text(greeting.title),
          content: Text(greeting.body),
          actions: [
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Get started'),
            ),
          ],
        ),
      );
      await ApiClient.instance.patch('/notifications/${greeting.id}/read');
    } catch (_) {
      // The message is still waiting in their notifications.
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xl, vertical: AppSpacing.xxxl),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: AppSpacing.xxl),
                // The three pieces arrive in reading order: the mark lands,
                // the name rises under it, then the greeting ripples across.
                // The delays are what make it a sequence rather than three
                // things moving at once.
                PopIn(
                  child: SpinningLogo(
                    // The highlight is driven by the turn, so the bright
                    // streak sweeps the face as it comes round rather than
                    // sitting in one place -- which is what separates
                    // polished metal from paint.
                    builder: (context, turn) => Sculpted(
                      baseColor: colorScheme.primary,
                      depth: 9,
                      highlight: turn,
                      layer: (color) => Icon(
                        Icons.storefront_rounded,
                        size: 72,
                        color: color,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: AppSpacing.xl),
                DroppingWordmark(
                  AppConstants.appName,
                  delay: AppMotion.medium,
                  color: colorScheme.primary,
                  style: textTheme.headlineMedium!.copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: AppSpacing.xs),
                WaveText(
                  tr('auth.welcome_back'),
                  delay: AppMotion.slow,
                  style: textTheme.bodyMedium,
                  repeat: true,
                ),
                const SizedBox(height: AppSpacing.xxxl),
                const RequiredFieldsNote(),
                AppTextField(
                  controller: _emailController,
                  label: tr('auth.email'),
                  isRequired: true,
                  keyboardType: TextInputType.emailAddress,
                  prefixIcon: Icons.email_outlined,
                  validator: Validators.email,
                ),
                const SizedBox(height: AppSpacing.lg),
                AppTextField(
                  controller: _passwordController,
                  label: tr('auth.password'),
                  isRequired: true,
                  obscureText: _obscurePassword,
                  prefixIcon: Icons.lock_outline,
                  validator: (value) => Validators.required(value, field: 'Password'),
                  suffixIcon: IconButton(
                    icon: Icon(
                      _obscurePassword ? Icons.visibility_outlined : Icons.visibility_off_outlined,
                    ),
                    onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
                  ),
                ),
                const SizedBox(height: AppSpacing.xxl),
                AppButton(
                  label: tr('auth.login'),
                  isLoading: _isSubmitting,
                  requiresConnection: true,
                  onPressed: _isSubmitting ? null : _submit,
                ),
                const SizedBox(height: AppSpacing.xl),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text("Don't have an account?", style: textTheme.bodyMedium),
                    TextButton(
                      onPressed: _isSubmitting
                          ? null
                          : () => Navigator.pushNamed(context, AppRoutes.register),
                      child: const Text('Sign up'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
