import 'package:flutter/material.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/models/user.dart';
import '../../../core/network/api_client.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/network/session_manager.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/utils/validators.dart';
import '../../../core/widgets/app_button.dart';
import '../../../core/widgets/app_card.dart';
import '../../../core/widgets/app_text_field.dart';

class _RoleOption {
  final String value;
  final String label;
  final String description;
  final IconData icon;

  const _RoleOption({
    required this.value,
    required this.label,
    required this.description,
    required this.icon,
  });
}

const List<_RoleOption> _roleOptions = [
  _RoleOption(
    value: roleUser,
    label: 'Customer',
    description: 'Browse and order from local shops',
    icon: Icons.shopping_bag_outlined,
  ),
  _RoleOption(
    value: roleShopOwner,
    label: 'Shop Owner',
    description: 'List and manage your shop',
    icon: Icons.storefront_outlined,
  ),
  _RoleOption(
    value: roleDeliveryAgent,
    label: 'Delivery Agent',
    description: 'Deliver orders and earn',
    icon: Icons.local_shipping_outlined,
  ),
];

/// The Register screen: creates a new account via `POST /auth/register`,
/// letting the user pick their account type (customer / shop owner /
/// delivery agent -- never admin, which cannot self-register).
class RegisterScreen extends StatefulWidget {
  const RegisterScreen({super.key});

  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends State<RegisterScreen> {
  final _formKey = GlobalKey<FormState>();
  final _fullNameController = TextEditingController();
  final _emailController = TextEditingController();
  final _phoneController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();

  String _selectedRole = roleUser;
  bool _obscurePassword = true;
  bool _obscureConfirmPassword = true;
  bool _isSubmitting = false;

  @override
  void dispose() {
    _fullNameController.dispose();
    _emailController.dispose();
    _phoneController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
  }

  String? _validateConfirmPassword(String? value) {
    if (value == null || value.isEmpty) return 'Please confirm your password';
    if (value != _passwordController.text) return 'Passwords do not match';
    return null;
  }

  Future<void> _submit() async {
    final formState = _formKey.currentState;
    if (formState == null || !formState.validate()) return;

    setState(() => _isSubmitting = true);

    try {
      final phone = _phoneController.text.trim();
      final response = await ApiClient.instance.post(
        '/auth/register',
        body: {
          'email': _emailController.text.trim(),
          'password': _passwordController.text,
          'full_name': _fullNameController.text.trim(),
          if (phone.isNotEmpty) 'phone': phone,
          'role': _selectedRole,
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

      if (_selectedRole == roleShopOwner || _selectedRole == roleDeliveryAgent) {
        final noun = _selectedRole == roleShopOwner ? 'list a shop' : 'accept deliveries';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Your account will need admin approval before you can $noun.'),
            duration: const Duration(seconds: 5),
          ),
        );
      }

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
    final textTheme = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(title: const Text('Create Account')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xl, vertical: AppSpacing.xl),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Join MicroLink',
                  style: textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  'Create an account to get started.',
                  style: textTheme.bodyMedium,
                ),
                const SizedBox(height: AppSpacing.xxl),
                AppTextField(
                  controller: _fullNameController,
                  label: 'Full name',
                  prefixIcon: Icons.person_outline,
                  validator: (value) => Validators.required(value, field: 'Full name'),
                ),
                const SizedBox(height: AppSpacing.lg),
                AppTextField(
                  controller: _emailController,
                  label: 'Email',
                  keyboardType: TextInputType.emailAddress,
                  prefixIcon: Icons.email_outlined,
                  validator: Validators.email,
                ),
                const SizedBox(height: AppSpacing.lg),
                AppTextField(
                  controller: _phoneController,
                  label: 'Phone (optional)',
                  keyboardType: TextInputType.phone,
                  prefixIcon: Icons.phone_outlined,
                  validator: Validators.phone,
                ),
                const SizedBox(height: AppSpacing.lg),
                AppTextField(
                  controller: _passwordController,
                  label: 'Password',
                  obscureText: _obscurePassword,
                  prefixIcon: Icons.lock_outline,
                  validator: Validators.password,
                  suffixIcon: IconButton(
                    icon: Icon(
                      _obscurePassword ? Icons.visibility_outlined : Icons.visibility_off_outlined,
                    ),
                    onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
                  ),
                ),
                const SizedBox(height: AppSpacing.lg),
                AppTextField(
                  controller: _confirmPasswordController,
                  label: 'Confirm password',
                  obscureText: _obscureConfirmPassword,
                  prefixIcon: Icons.lock_outline,
                  validator: _validateConfirmPassword,
                  suffixIcon: IconButton(
                    icon: Icon(
                      _obscureConfirmPassword
                          ? Icons.visibility_outlined
                          : Icons.visibility_off_outlined,
                    ),
                    onPressed: () =>
                        setState(() => _obscureConfirmPassword = !_obscureConfirmPassword),
                  ),
                ),
                const SizedBox(height: AppSpacing.xxl),
                Text(
                  'I am signing up as a...',
                  style: textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: AppSpacing.md),
                RadioGroup<String>(
                  groupValue: _selectedRole,
                  onChanged: (value) {
                    if (!_isSubmitting && value != null) setState(() => _selectedRole = value);
                  },
                  child: Column(children: _roleOptions.map(_buildRoleCard).toList()),
                ),
                const SizedBox(height: AppSpacing.xl),
                AppButton(
                  label: 'Create Account',
                  isLoading: _isSubmitting,
                  onPressed: _isSubmitting ? null : _submit,
                ),
                const SizedBox(height: AppSpacing.xl),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text('Already have an account?', style: textTheme.bodyMedium),
                    TextButton(
                      onPressed: _isSubmitting
                          ? null
                          : () => Navigator.pushNamed(context, AppRoutes.login),
                      child: const Text('Log in'),
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

  Widget _buildRoleCard(_RoleOption option) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final isSelected = _selectedRole == option.value;

    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.md),
      child: AppCard(
        onTap: _isSubmitting ? null : () => setState(() => _selectedRole = option.value),
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Row(
          children: [
            Icon(
              option.icon,
              color: isSelected ? colorScheme.primary : colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    option.label,
                    style: textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: isSelected ? colorScheme.primary : null,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    option.description,
                    style: textTheme.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
            Radio<String>(
              value: option.value,
              enabled: !_isSubmitting,
              activeColor: colorScheme.primary,
            ),
          ],
        ),
      ),
    );
  }
}
