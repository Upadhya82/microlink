import 'package:flutter/material.dart';

import '../../../core/l10n/app_strings.dart';
import '../../../core/constants/app_constants.dart';
import '../../../core/network/api_client.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/network/session_manager.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/utils/validators.dart';
import '../../../core/widgets/app_button.dart';
import '../../../core/widgets/app_text_field.dart';

/// The Login screen: email + password sign-in against `POST /auth/login`.
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();

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
                Icon(
                  Icons.storefront_rounded,
                  size: 72,
                  color: colorScheme.primary,
                ),
                const SizedBox(height: AppSpacing.lg),
                Text(
                  AppConstants.appName,
                  textAlign: TextAlign.center,
                  style: textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  tr('auth.welcome_back'),
                  textAlign: TextAlign.center,
                  style: textTheme.bodyMedium,
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
