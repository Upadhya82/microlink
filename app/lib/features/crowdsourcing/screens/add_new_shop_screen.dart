import 'package:flutter/material.dart';
import '../../../core/widgets/photo_picker_field.dart';
import '../../../core/network/multipart_upload.dart';
import 'package:geolocator/geolocator.dart';

import '../../../core/models/shop.dart';
import '../../../core/network/api_client.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/theme/app_colors_extension.dart';
import '../../../core/theme/app_spacing.dart';
import '../../location/widgets/location_field.dart';
import '../../../core/utils/validators.dart';
import '../../../core/widgets/app_button.dart';
import '../../../core/widgets/app_card.dart';
import '../../../core/widgets/app_text_field.dart';

/// A one-shot crowdsourcing form: lets any signed-in user suggest a shop
/// that isn't on MicroLink yet. Submits to `POST /crowdsource/shop-reports`
/// for the team to review, then shows a clear confirmation instead of just
/// a snackbar since this is a contribution worth acknowledging.
class AddNewShopScreen extends StatefulWidget {
  const AddNewShopScreen({super.key});

  @override
  State<AddNewShopScreen> createState() => _AddNewShopScreenState();
}

class _AddNewShopScreenState extends State<AddNewShopScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _addressController = TextEditingController();
  final _descController = TextEditingController();
  PickedFile? _photo;

  String? _category;
  TimeOfDay? _openingTime;
  TimeOfDay? _closingTime;
  double? _latitude;
  double? _longitude;
  String? _pickedAddress;
  bool _locating = false;
  bool _isSubmitting = false;
  bool _success = false;

  @override
  void dispose() {
    _nameController.dispose();
    _addressController.dispose();
    _descController.dispose();

    super.dispose();
  }

  Future<void> _useCurrentLocation() async {
    setState(() => _locating = true);
    try {
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied || permission == LocationPermission.deniedForever) {
        throw const ApiException('Location permission was denied.');
      }
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        throw const ApiException('Please enable location services and try again.');
      }
      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.high),
      );
      if (!mounted) return;
      setState(() {
        _latitude = position.latitude;
        _longitude = position.longitude;
      });
    } catch (e) {
      if (!mounted) return;
      final message = e is ApiException ? e.message : 'Could not get your current location.';
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
    } finally {
      if (mounted) setState(() => _locating = false);
    }
  }

  Future<void> _pickTime({required bool isOpening}) async {
    final initial = (isOpening ? _openingTime : _closingTime) ?? const TimeOfDay(hour: 9, minute: 0);
    final picked = await showTimePicker(context: context, initialTime: initial);
    if (picked == null) return;
    setState(() {
      if (isOpening) {
        _openingTime = picked;
      } else {
        _closingTime = picked;
      }
    });
  }

  String _formatTime24(TimeOfDay time) =>
      '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';

  Future<void> _submit() async {
    final formState = _formKey.currentState;
    if (formState == null || !formState.validate()) return;
    if (_category == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Select a category.')));
      return;
    }
    if (_latitude == null || _longitude == null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Set the shop location.')));
      return;
    }
    if (_openingTime == null || _closingTime == null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Set opening and closing hours.')));
      return;
    }

    setState(() => _isSubmitting = true);
    try {
      final created = await ApiClient.instance.post(
        '/crowdsource/shop-reports',
        body: {
          'shop_name': _nameController.text.trim(),
          'category': _category,
          'address': _addressController.text.trim(),
          'latitude': _latitude,
          'longitude': _longitude,
          'description': _descController.text.trim(),
          'opening_time': _formatTime24(_openingTime!),
          'closing_time': _formatTime24(_closingTime!),
        },
      ) as Map<String, dynamic>;

      // Separate call: the report is already saved, so a failed photo
      // upload costs the reporter nothing they typed in.
      final photo = _photo;
      if (photo != null) {
        try {
          await MultipartUpload.send(
            path: '/crowdsource/shop-reports/${created['id']}/photo',
            file: photo,
          );
        } catch (_) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Shop reported, but the photo did not upload.'),
              ),
            );
          }
        }
      }
      if (!mounted) return;
      setState(() => _success = true);
    } on ApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  void _reset() {
    _nameController.clear();
    _addressController.clear();
    _descController.clear();
    _photo = null;
    setState(() {
      _category = null;
      _openingTime = null;
      _closingTime = null;
      _latitude = null;
      _longitude = null;
      _success = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new),
          onPressed: () => Navigator.maybePop(context),
        ),
        title: const Text('Suggest a New Shop'),
      ),
      body: SafeArea(
        child: _success ? _buildSuccess(context) : _buildForm(context),
      ),
    );
  }

  Widget _buildForm(BuildContext context) {
    final hasLocation = _latitude != null && _longitude != null;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(AppSpacing.xl),
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Help grow the MicroLink map for your neighbourhood',
              style:
                  Theme.of(context).textTheme.bodyMedium?.copyWith(color: context.appColors.textSecondary),
            ),
            const SizedBox(height: AppSpacing.xl),
            AppTextField(
              controller: _nameController,
              label: 'Shop name',
              hint: 'e.g. Perera Super Grocers',
              validator: (v) => Validators.required(v, field: 'Shop name'),
            ),
            const SizedBox(height: AppSpacing.lg),
            Text('Category', style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: AppSpacing.sm),
            Wrap(
              spacing: AppSpacing.sm,
              runSpacing: AppSpacing.sm,
              children: shopCategories.map((category) {
                final selected = _category == category;
                return _PickerChip(
                  label: formatCategoryLabel(category),
                  selected: selected,
                  onTap: () => setState(() => _category = category),
                );
              }).toList(),
            ),
            const SizedBox(height: AppSpacing.lg),
            Text('Location', style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: AppSpacing.sm),
            LocationField(
              latitude: _latitude,
              longitude: _longitude,
              address: _pickedAddress,
              isLocating: _locating,
              pickerTitle: 'Where is the shop?',
              confirmLabel: 'Use this location',
              onUseMyLocation: _useCurrentLocation,
              onPicked: (picked) => setState(() {
                _latitude = picked.latitude;
                _longitude = picked.longitude;
                _pickedAddress = picked.address;
              }),
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              hasLocation
                  ? 'Lat: ${_latitude!.toStringAsFixed(5)}, Lng: ${_longitude!.toStringAsFixed(5)}'
                  : 'No location set yet',
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: context.appColors.textSecondary),
            ),
            const SizedBox(height: AppSpacing.lg),
            AppTextField(
              controller: _addressController,
              label: 'Address',
              hint: 'e.g. 24 Marine Drive, Wellawatte',
              validator: (v) => Validators.required(v, field: 'Address'),
            ),
            const SizedBox(height: AppSpacing.md),
            AppTextField(
              controller: _descController,
              label: 'Description',
              hint: 'What does this shop sell?',
              maxLines: 3,
              validator: (v) => Validators.required(v, field: 'Description'),
            ),
            const SizedBox(height: AppSpacing.lg),
            Row(
              children: [
                Expanded(
                  child: _TimeField(
                    label: 'Opens',
                    time: _openingTime,
                    onTap: () => _pickTime(isOpening: true),
                  ),
                ),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: _TimeField(
                    label: 'Closes',
                    time: _closingTime,
                    onTap: () => _pickTime(isOpening: false),
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.lg),
            PhotoPickerField(
              file: _photo,
              label: 'Photo of the shop front (optional)',
              enabled: !_isSubmitting,
              onChanged: (f) => setState(() => _photo = f),
            ),
            const SizedBox(height: AppSpacing.xxl),
            AppButton(
              label: 'Submit for Review',
              isLoading: _isSubmitting,
              onPressed: _isSubmitting ? null : _submit,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSuccess(BuildContext context) {
    final colors = context.appColors;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: AppCard(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.check_circle, size: 56, color: colors.success),
              const SizedBox(height: AppSpacing.lg),
              Text(
                'Thanks! Our team will review your suggestion.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: AppSpacing.xl),
              AppButton(label: 'Submit Another Shop', icon: Icons.add, onPressed: _reset),
              const SizedBox(height: AppSpacing.sm),
              AppButton(
                label: 'Back',
                variant: AppButtonVariant.text,
                onPressed: () {
                  if (Navigator.canPop(context)) Navigator.pop(context);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A pill-shaped selectable chip used for the category picker. Purely
/// visual -- selection state lives in the parent screen.
class _PickerChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _PickerChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadius.pill),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.sm),
        decoration: BoxDecoration(
          color: selected ? colorScheme.primary : colorScheme.surface,
          borderRadius: BorderRadius.circular(AppRadius.pill),
          border: Border.all(color: selected ? colorScheme.primary : colorScheme.outlineVariant),
        ),
        child: Text(
          label,
          style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: selected ? colorScheme.onPrimary : context.appColors.textSecondary,
                fontWeight: FontWeight.w600,
              ),
        ),
      ),
    );
  }
}


/// A tap-to-pick time field styled like the app's text inputs, backed by
/// [showTimePicker] in the parent screen.
class _TimeField extends StatelessWidget {
  final String label;
  final TimeOfDay? time;
  final VoidCallback onTap;

  const _TimeField({
    required this.label,
    required this.time,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: textTheme.labelLarge),
        const SizedBox(height: AppSpacing.xs),
        InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(AppRadius.input),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg, vertical: AppSpacing.md),
            decoration: BoxDecoration(
              color: colorScheme.surface,
              borderRadius: BorderRadius.circular(AppRadius.input),
              border: Border.all(color: colorScheme.outlineVariant),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  time != null ? time!.format(context) : 'Select time',
                  style: textTheme.bodyMedium?.copyWith(
                    color: time != null ? colorScheme.onSurface : context.appColors.textSecondary,
                  ),
                ),
                Icon(Icons.access_time, size: 18, color: context.appColors.textSecondary),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
