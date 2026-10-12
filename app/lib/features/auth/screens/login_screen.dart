import 'package:flutter/material.dart';

import '../../../core/l10n/app_strings.dart';
import '../../../core/constants/app_constants.dart';
import '../../../core/network/api_client.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/network/session_manager.dart';
import '../../../core/theme/app_motion.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/utils/validators.dart';
import '../../../core/widgets/app_button.dart';
import '../../../core/widgets/app_text_field.dart';
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
      Navigator.pushNamedAndRemoveUntil(context, AppRoutes.home, (route) => false);
    } on ApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
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
                AppTextField(
                  controller: _emailController,
                  label: tr('auth.email'),
                  keyboardType: TextInputType.emailAddress,
                  prefixIcon: Icons.email_outlined,
                  validator: Validators.email,
                ),
                const SizedBox(height: AppSpacing.lg),
                AppTextField(
                  controller: _passwordController,
                  label: tr('auth.password'),
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
