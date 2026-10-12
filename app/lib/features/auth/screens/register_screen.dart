import 'package:flutter/material.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/models/user.dart';
import '../../../core/network/api_client.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/network/multipart_upload.dart';
import '../../../core/network/session_manager.dart';
import '../../../core/theme/app_colors_extension.dart';
import '../../../core/theme/app_motion.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/utils/validators.dart';
import '../../../core/widgets/app_button.dart';
import '../../../core/widgets/app_text_field.dart';
import '../../../core/widgets/obscure_reveal_controller.dart';
import '../../../core/widgets/stagger_in.dart';
import '../../account/document_types.dart';
import '../../../core/widgets/branded_app_bar.dart';

class _RoleOption {
  final String value;
  final String label;
  final String description;
  final IconData icon;

  /// Whether an admin must approve the account before it can be used.
  final bool needsApproval;

  const _RoleOption({
    required this.value,
    required this.label,
    required this.description,
    required this.icon,
    this.needsApproval = false,
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
    needsApproval: true,
  ),
  _RoleOption(
    value: roleDeliveryAgent,
    label: 'Delivery Agent',
    description: 'Deliver orders and earn',
    icon: Icons.local_shipping_outlined,
    needsApproval: true,
  ),
];

/// Registration, in two steps: pick what kind of account you want, then fill
/// in the form for it.
///
/// One combined form used to ask everyone the same questions and mention
/// approval only in a snackbar after the fact. Splitting it means a delivery
/// agent is told up front which documents they will need, and is taken
/// straight to uploading them -- which is also the only moment they are
/// holding a token, since an unapproved owner or agent cannot log back in
/// (REQ-AUTH-4).
class RegisterScreen extends StatefulWidget {
  const RegisterScreen({super.key});

  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends State<RegisterScreen> {
  _RoleOption? _role;

  @override
  Widget build(BuildContext context) {
    final role = _role;
    return Scaffold(
      appBar: BrandedAppBar(
        title: Text(role == null ? 'Create account' : 'Sign up as ${role.label}'),
        leading: role == null
            ? null
            : IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: () => setState(() => _role = null),
              ),
      ),
      body: AnimatedSwitcher(
        duration: AppMotion.medium,
        switchInCurve: AppMotion.enter,
        child: role == null
            ? _RolePicker(
                key: const ValueKey('role-picker'),
                onSelected: (option) => setState(() => _role = option),
              )
            : _RegisterForm(key: ValueKey(role.value), role: role),
      ),
    );
  }
}

// ---------------------------------------------------------------- step 1

class _RolePicker extends StatelessWidget {
  final ValueChanged<_RoleOption> onSelected;

  const _RolePicker({super.key, required this.onSelected});

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final colors = context.appColors;

    return ListView(
      padding: const EdgeInsets.all(AppSpacing.lg),
      children: [
        Text(
          'How will you use MicroLink?',
          style: textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: AppSpacing.xs),
        Text(
          'You can only pick one. Shop owners and delivery agents are checked '
          'by an admin before their account is activated.',
          style: textTheme.bodySmall?.copyWith(color: colors.textSecondary),
        ),
        const SizedBox(height: AppSpacing.lg),
        for (var i = 0; i < _roleOptions.length; i++)
          StaggerIn(
            index: i,
            child: Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.md),
              child: _RoleCard(
                option: _roleOptions[i],
                onTap: () => onSelected(_roleOptions[i]),
              ),
            ),
          ),
      ],
    );
  }
}

class _RoleCard extends StatelessWidget {
  final _RoleOption option;
  final VoidCallback onTap;

  const _RoleCard({required this.option, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final colors = context.appColors;
    final textTheme = Theme.of(context).textTheme;

    return Material(
      color: colorScheme.surface,
      elevation: 1,
      borderRadius: BorderRadius.circular(AppRadius.card),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.card),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.all(AppSpacing.md),
                decoration: BoxDecoration(
                  color: colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(AppRadius.input),
                ),
                child: Icon(option.icon, color: colorScheme.primary),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      option.label,
                      style: textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                    ),
                    Text(
                      option.description,
                      style: textTheme.bodySmall?.copyWith(color: colors.textSecondary),
                    ),
                    if (requiredDocLabelsFor(option.value).isNotEmpty) ...[
                      const SizedBox(height: AppSpacing.sm),
                      Wrap(
                        spacing: AppSpacing.xs,
                        runSpacing: AppSpacing.xs,
                        children: [
                          for (final requirement
                              in requiredDocLabelsFor(option.value))
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: AppSpacing.sm,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: colorScheme.surfaceContainerHighest,
                                borderRadius: BorderRadius.circular(AppRadius.pill),
                              ),
                              child: Text(
                                requirement,
                                style: textTheme.labelSmall
                                    ?.copyWith(color: colors.textSecondary),
                              ),
                            ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
              const Icon(Icons.chevron_right),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- step 2

class _RegisterForm extends StatefulWidget {
  final _RoleOption role;

  const _RegisterForm({super.key, required this.role});

  @override
  State<_RegisterForm> createState() => _RegisterFormState();
}

class _RegisterFormState extends State<_RegisterForm> {
  final _formKey = GlobalKey<FormState>();
  final _fullNameController = TextEditingController();
  final _emailController = TextEditingController();
  final _phoneController = TextEditingController();
  // See login_screen.dart: these drive the animated show/hide wipe.
  final _passwordController = ObscureRevealController();
  final _confirmPasswordController = ObscureRevealController();

  /// Shop owners name their business; agents say what they drive. Collected
  /// here so the admin reviewing the application has context beyond a name.
  final _businessNameController = TextEditingController();
  String _vehicleType = 'bike';

  bool _obscurePassword = true;
  bool _obscureConfirmPassword = true;
  bool _isSubmitting = false;

  /// Documents chosen on this form, held in memory until there is a token to
  /// upload them with. Picking needs no auth; uploading does, so the files
  /// wait here and go up immediately after the account is created.
  final Map<String, PickedFile> _documents = {};

  static const _vehicleTypes = ['bike', 'scooter', 'car', 'van'];

  bool get _isShopOwner => widget.role.value == roleShopOwner;
  bool get _isAgent => widget.role.value == roleDeliveryAgent;

  @override
  void dispose() {
    _fullNameController.dispose();
    _emailController.dispose();
    _phoneController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    _businessNameController.dispose();
    super.dispose();
  }

  List<String> get _requiredDocs =>
      kRequiredDocsByRole[widget.role.value] ?? const <String>[];

  List<String> get _missingDocs =>
      _requiredDocs.where((v) => !_documents.containsKey(v)).toList();

  Future<void> _pickDocument(DocType type) async {
    try {
      final picked = await MultipartUpload.pick(
        allowedExtensions: MultipartUpload.documentExtensions,
      );
      if (picked == null || !mounted) return;
      setState(() => _documents[type.value] = picked);
    } on ApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Could not read that file.')));
    }
  }

  String? _validateConfirmPassword(String? value) {
    if (value != _passwordController.text) return 'Passwords do not match';
    return null;
  }

  Future<void> _submit() async {
    final formState = _formKey.currentState;
    if (formState == null || !formState.validate()) return;

    final missing = _missingDocs;
    if (missing.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Please attach: ${missing.map((v) => docTypeFor(v).label).join(', ')}.',
          ),
        ),
      );
      return;
    }

    setState(() => _isSubmitting = true);
    try {
      final phone = _phoneController.text.trim();
      final business = _businessNameController.text.trim();

      if (widget.role.needsApproval) {
        // Account and documents travel together: the server writes all of it
        // or none of it, so a failure here leaves nothing to clean up and no
        // half-made account the applicant cannot log into.
        final ordered = _requiredDocs.where(_documents.containsKey).toList();
        final response = await MultipartUpload.sendMany(
          path: '/auth/register-application',
          files: [for (final value in ordered) _documents[value]!],
          fields: {
            'email': _emailController.text.trim(),
            'password': _passwordController.text,
            'full_name': _fullNameController.text.trim(),
            'role': widget.role.value,
            if (phone.isNotEmpty) 'phone': phone,
            if (_isShopOwner && business.isNotEmpty) 'business_name': business,
          },
          repeatedFields: {'doc_types': ordered},
        );

        final user = response['user'] as Map<String, dynamic>;
        // Held only long enough to record the vehicle; the applicant cannot
        // log in again until an admin approves them.
        await SessionManager.instance.saveSession(
          token: response['access_token'] as String,
          userId: user['id'] as String,
          role: user['role'] as String,
          name: user['full_name'] as String,
        );
        if (_isAgent) {
          try {
            await ApiClient.instance.post(
              '/delivery/agents/profile',
              body: {'vehicle_type': _vehicleType},
            );
          } catch (_) {
            // They can set it later from Driver Home.
          }
        }
        if (!mounted) return;
        await _sendToAdminQueue();
        return;
      }

      final response = await ApiClient.instance.post(
        '/auth/register',
        body: {
          'email': _emailController.text.trim(),
          'password': _passwordController.text,
          'full_name': _fullNameController.text.trim(),
          if (phone.isNotEmpty) 'phone': phone,
          'role': widget.role.value,
        },
      ) as Map<String, dynamic>;

      final user = response['user'] as Map<String, dynamic>;
      await SessionManager.instance.saveSession(
        token: response['access_token'] as String,
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

  /// Hand the application to the admin queue and sign out.
  ///
  /// There is nothing an unapproved owner or agent can do in the app and
  /// REQ-AUTH-4 blocks them at login anyway, so dropping them on a home
  /// screen they have no access to would just look broken.
  Future<void> _sendToAdminQueue() async {
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    await SessionManager.instance.clearSession();
    navigator.pushNamedAndRemoveUntil(AppRoutes.login, (route) => false);
    messenger.showSnackBar(
      const SnackBar(
        content: Text(
          'Application sent for review. You can sign in once an admin has '
          'approved your account.',
        ),
        duration: Duration(seconds: 6),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final colors = context.appColors;
    final textTheme = Theme.of(context).textTheme;

    return Form(
      key: _formKey,
      child: ListView(
        padding: const EdgeInsets.all(AppSpacing.lg),
        children: [
          if (widget.role.needsApproval)
            Container(
              padding: const EdgeInsets.all(AppSpacing.md),
              margin: const EdgeInsets.only(bottom: AppSpacing.lg),
              decoration: BoxDecoration(
                color: colorScheme.secondaryContainer,
                borderRadius: BorderRadius.circular(AppRadius.card),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.info_outline, color: colorScheme.onSecondaryContainer),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: Text(
                      'Fill in your details and attach the documents below. '
                      'An admin reviews your application, and you can sign in '
                      'once it is approved.',
                      style: textTheme.bodySmall
                          ?.copyWith(color: colorScheme.onSecondaryContainer),
                    ),
                  ),
                ],
              ),
            ),
          AppTextField(
            controller: _fullNameController,
            label: 'Full name',
            prefixIcon: Icons.person_outline,
            validator: (v) => Validators.required(v, field: 'Full name'),
          ),
          if (_isShopOwner) ...[
            const SizedBox(height: AppSpacing.lg),
            AppTextField(
              controller: _businessNameController,
              label: 'Business name',
              hint: 'The name customers will see',
              prefixIcon: Icons.storefront_outlined,
              validator: (v) => Validators.required(v, field: 'Business name'),
            ),
          ],
          const SizedBox(height: AppSpacing.lg),
          AppTextField(
            controller: _emailController,
            label: 'Email',
            keyboardType: TextInputType.emailAddress,
            prefixIcon: Icons.mail_outline,
            validator: Validators.email,
          ),
          const SizedBox(height: AppSpacing.lg),
          AppTextField(
            controller: _phoneController,
            label: _isAgent ? 'Phone number' : 'Phone number (optional)',
            keyboardType: TextInputType.phone,
            prefixIcon: Icons.phone_outlined,
            // An agent with no phone cannot be reached by the customer whose
            // order they are carrying, so it is required for them.
            validator: _isAgent
                ? (v) => Validators.required(v, field: 'Phone number') ?? Validators.phone(v)
                : Validators.phone,
          ),
          if (_isAgent) ...[
            const SizedBox(height: AppSpacing.lg),
            Text('What do you deliver with?', style: textTheme.labelLarge),
            const SizedBox(height: AppSpacing.sm),
            Wrap(
              spacing: AppSpacing.sm,
              children: [
                for (final type in _vehicleTypes)
                  ChoiceChip(
                    label: Text(type[0].toUpperCase() + type.substring(1)),
                    selected: _vehicleType == type,
                    onSelected: (_) => setState(() => _vehicleType = type),
                  ),
              ],
            ),
          ],
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
          const SizedBox(height: AppSpacing.xs),
          Text(
            'At least 8 characters, with one uppercase letter and one number.',
            style: textTheme.labelSmall?.copyWith(color: colors.textSecondary),
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
          if (_requiredDocs.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.xxl),
            Text(
              'Required documents',
              style: textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              'Images or PDF, up to 8MB each.',
              style: textTheme.labelSmall?.copyWith(color: colors.textSecondary),
            ),
            const SizedBox(height: AppSpacing.sm),
            for (final value in _requiredDocs)
              _DocumentField(
                type: docTypeFor(value),
                file: _documents[value],
                enabled: !_isSubmitting,
                onPick: () => _pickDocument(docTypeFor(value)),
                onRemove: () => setState(() => _documents.remove(value)),
              ),
          ],
          const SizedBox(height: AppSpacing.xxl),
          AppButton(
            label: widget.role.needsApproval ? 'Submit application' : 'Create account',
            isLoading: _isSubmitting,
            onPressed: _isSubmitting ? null : _submit,
          ),
          const SizedBox(height: AppSpacing.md),
          Center(
            child: TextButton(
              onPressed: _isSubmitting
                  ? null
                  : () => Navigator.pushNamed(context, AppRoutes.login),
              child: const Text('I already have an account'),
            ),
          ),
        ],
      ),
    );
  }
}


// ---------------------------------------------------------------- documents

/// One document slot on the signup form: tap to attach, tap the X to swap it
/// out. Shows the file name and size once something is attached so the
/// applicant can tell at a glance that the right file went in.
class _DocumentField extends StatelessWidget {
  final DocType type;
  final PickedFile? file;
  final bool enabled;
  final VoidCallback onPick;
  final VoidCallback onRemove;

  const _DocumentField({
    required this.type,
    required this.file,
    required this.enabled,
    required this.onPick,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final colors = context.appColors;
    final textTheme = Theme.of(context).textTheme;
    final attached = file;

    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: Material(
        color: colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(AppRadius.input),
        child: InkWell(
          borderRadius: BorderRadius.circular(AppRadius.input),
          onTap: enabled ? onPick : null,
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.md),
            child: Row(
              children: [
                Icon(
                  attached == null ? type.icon : Icons.check_circle,
                  color: attached == null ? colors.textSecondary : Colors.green,
                ),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        type.label,
                        style: textTheme.bodyMedium
                            ?.copyWith(fontWeight: FontWeight.w600),
                      ),
                      Text(
                        attached == null
                            ? type.help
                            : '${attached.name} '
                                '(${(attached.sizeBytes / 1024).round()} KB)',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: textTheme.labelSmall
                            ?.copyWith(color: colors.textSecondary),
                      ),
                    ],
                  ),
                ),
                if (attached == null)
                  Text(
                    'Attach',
                    style: textTheme.labelMedium
                        ?.copyWith(color: colorScheme.primary),
                  )
                else
                  IconButton(
                    icon: const Icon(Icons.close, size: 18),
                    tooltip: 'Remove',
                    onPressed: enabled ? onRemove : null,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
