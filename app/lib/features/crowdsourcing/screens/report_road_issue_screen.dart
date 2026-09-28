import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';

import '../../../core/models/shop.dart' show formatCategoryLabel;
import '../../../core/network/api_client.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/theme/app_colors_extension.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/utils/validators.dart';
import '../../../core/widgets/app_button.dart';
import '../../../core/widgets/app_card.dart';
import '../../../core/widgets/app_text_field.dart';

const Map<String, String> _conditionLabels = {
  'pothole': 'Pothole',
  'flooding': 'Flooding',
  'construction': 'Construction',
  'accident': 'Accident',
  'blocked': 'Road Blocked',
  'other': 'Other',
};

const Map<String, IconData> _conditionIcons = {
  'pothole': Icons.report_problem_outlined,
  'flooding': Icons.water_damage_outlined,
  'construction': Icons.construction_outlined,
  'accident': Icons.car_crash_outlined,
  'blocked': Icons.block,
  'other': Icons.help_outline,
};

const List<String> _severityLevels = ['low', 'medium', 'high'];

/// A one-shot crowdsourcing form: lets any signed-in user report a road
/// condition (pothole, flooding, etc). Submits to
/// `POST /crowdsource/road-reports`, then shows a clear confirmation. Below
/// the confirmation, an optional "recent nearby reports" section can be
/// expanded, backed by `GET /crowdsource/road-reports`.
class ReportRoadIssueScreen extends StatefulWidget {
  const ReportRoadIssueScreen({super.key});

  @override
  State<ReportRoadIssueScreen> createState() => _ReportRoadIssueScreenState();
}

class _ReportRoadIssueScreenState extends State<ReportRoadIssueScreen> {
  final _formKey = GlobalKey<FormState>();
  final _descController = TextEditingController();
  final _photoUrlController = TextEditingController();

  String? _conditionType;
  String _severity = 'medium';
  double? _latitude;
  double? _longitude;
  bool _locating = false;
  bool _isSubmitting = false;
  bool _success = false;

  bool _showNearby = false;
  bool _loadingNearby = false;
  List<Map<String, dynamic>>? _nearbyReports;
  String? _nearbyError;

  @override
  void dispose() {
    _descController.dispose();
    _photoUrlController.dispose();
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

  Future<void> _submit() async {
    final formState = _formKey.currentState;
    if (formState == null || !formState.validate()) return;
    if (_conditionType == null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Select the type of road issue.')));
      return;
    }
    if (_latitude == null || _longitude == null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Set the issue location.')));
      return;
    }

    setState(() => _isSubmitting = true);
    try {
      final photoUrl = _photoUrlController.text.trim();
      await ApiClient.instance.post('/crowdsource/road-reports', body: {
        'latitude': _latitude,
        'longitude': _longitude,
        'condition_type': _conditionType,
        'description': _descController.text.trim(),
        'severity': _severity,
        if (photoUrl.isNotEmpty) 'image_url': photoUrl,
      });
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
    _descController.clear();
    _photoUrlController.clear();
    setState(() {
      _conditionType = null;
      _severity = 'medium';
      _latitude = null;
      _longitude = null;
      _success = false;
      _showNearby = false;
      _nearbyReports = null;
      _nearbyError = null;
    });
  }

  Future<void> _loadNearbyReports() async {
    if (_latitude == null || _longitude == null) return;
    setState(() {
      _loadingNearby = true;
      _nearbyError = null;
    });
    try {
      final response = await ApiClient.instance.get('/crowdsource/road-reports', query: {
        'lat': _latitude,
        'lng': _longitude,
        'radius_km': 5,
      }) as List;
      if (!mounted) return;
      setState(() => _nearbyReports = response.cast<Map<String, dynamic>>());
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _nearbyError = e.message);
    } finally {
      if (mounted) setState(() => _loadingNearby = false);
    }
  }

  Future<void> _toggleNearby() async {
    setState(() => _showNearby = !_showNearby);
    if (_showNearby && _nearbyReports == null) {
      await _loadNearbyReports();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new),
          onPressed: () => Navigator.maybePop(context),
        ),
        title: const Text('Report an Issue'),
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
              'Flag a road or delivery problem near you',
              style:
                  Theme.of(context).textTheme.bodyMedium?.copyWith(color: context.appColors.textSecondary),
            ),
            const SizedBox(height: AppSpacing.xl),
            Text('Issue type', style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: AppSpacing.sm),
            GridView.count(
              crossAxisCount: 3,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              mainAxisSpacing: AppSpacing.sm,
              crossAxisSpacing: AppSpacing.sm,
              childAspectRatio: 1.15,
              children: _conditionLabels.entries.map((entry) {
                final selected = _conditionType == entry.key;
                return _IssueTile(
                  label: entry.value,
                  icon: _conditionIcons[entry.key] ?? Icons.help_outline,
                  selected: selected,
                  onTap: () => setState(() => _conditionType = entry.key),
                );
              }).toList(),
            ),
            const SizedBox(height: AppSpacing.lg),
            Text('Severity', style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: AppSpacing.sm),
            SegmentedButton<String>(
              segments: _severityLevels
                  .map((level) => ButtonSegment(value: level, label: Text(formatCategoryLabel(level))))
                  .toList(),
              selected: {_severity},
              onSelectionChanged: (selection) => setState(() => _severity = selection.first),
            ),
            const SizedBox(height: AppSpacing.lg),
            Text('Location', style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: AppSpacing.sm),
            _MapLocationPreview(
              hasLocation: hasLocation,
              isLocating: _locating,
              actionLabel: 'Use my location',
              onTap: _locating ? null : _useCurrentLocation,
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
              controller: _descController,
              label: 'Description',
              hint: 'Describe what you saw',
              maxLines: 3,
              validator: (v) => Validators.required(v, field: 'Description'),
            ),
            const SizedBox(height: AppSpacing.lg),
            AppTextField(
              controller: _photoUrlController,
              label: 'Photo URL (optional)',
              hint: 'https://…',
              prefixIcon: Icons.image_outlined,
              keyboardType: TextInputType.url,
            ),
            const SizedBox(height: AppSpacing.xxl),
            _DangerButton(
              label: 'Submit Report',
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
    return SingleChildScrollView(
      padding: const EdgeInsets.all(AppSpacing.xl),
      child: Column(
        children: [
          AppCard(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.check_circle, size: 56, color: colors.success),
                const SizedBox(height: AppSpacing.lg),
                Text(
                  'Thanks! Our team will review your report.',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: AppSpacing.xl),
                AppButton(label: 'Report Another Issue', icon: Icons.add, onPressed: _reset),
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
          const SizedBox(height: AppSpacing.xl),
          TextButton.icon(
            onPressed: _toggleNearby,
            icon: Icon(_showNearby ? Icons.expand_less : Icons.expand_more),
            label: Text(_showNearby ? 'Hide nearby reports' : 'View recent nearby reports'),
          ),
          if (_showNearby) _buildNearbySection(context),
        ],
      ),
    );
  }

  Widget _buildNearbySection(BuildContext context) {
    if (_loadingNearby) {
      return const Padding(
        padding: EdgeInsets.all(AppSpacing.lg),
        child: CircularProgressIndicator(),
      );
    }
    if (_nearbyError != null) {
      return Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Text(_nearbyError!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
      );
    }
    final reports = _nearbyReports ?? const [];
    if (reports.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Text('No recent reports nearby.', style: TextStyle(color: context.appColors.textSecondary)),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.md),
      child: Column(
        children: reports.map((report) {
          final conditionType = report['condition_type'] as String? ?? 'other';
          final severity = report['severity'] as String? ?? 'medium';
          final description = report['description'] as String? ?? '';
          final distanceKm = (report['distance_km'] as num?)?.toDouble();
          return Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.md),
            child: AppCard(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    _conditionIcons[conditionType] ?? Icons.help_outline,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${_conditionLabels[conditionType] ?? formatCategoryLabel(conditionType)} · '
                          '${formatCategoryLabel(severity)} severity',
                          style: Theme.of(context)
                              .textTheme
                              .bodyMedium
                              ?.copyWith(fontWeight: FontWeight.w600),
                        ),
                        if (description.isNotEmpty) ...[
                          const SizedBox(height: AppSpacing.xs),
                          Text(description, style: Theme.of(context).textTheme.bodySmall),
                        ],
                        if (distanceKm != null) ...[
                          const SizedBox(height: AppSpacing.xs),
                          Text(
                            '${distanceKm.toStringAsFixed(1)} km away',
                            style: Theme.of(context)
                                .textTheme
                                .bodySmall
                                ?.copyWith(color: context.appColors.textSecondary),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        }).toList(),
      ),
    );
  }
}

/// One tile in the issue-type picker grid: an icon over a label, with a red
/// border/tint when selected. Purely visual -- selection state lives in the
/// parent screen.
class _IssueTile extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  const _IssueTile({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadius.card - 2),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm, vertical: AppSpacing.sm),
        decoration: BoxDecoration(
          color: selected ? colorScheme.errorContainer : colorScheme.surface,
          borderRadius: BorderRadius.circular(AppRadius.card - 2),
          border: Border.all(
            color: selected ? colorScheme.error : colorScheme.outlineVariant,
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 20, color: selected ? colorScheme.error : context.appColors.textSecondary),
            const SizedBox(height: AppSpacing.xs),
            Text(
              label,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context)
                  .textTheme
                  .labelSmall
                  ?.copyWith(fontWeight: FontWeight.w600, color: colorScheme.onSurface),
            ),
          ],
        ),
      ),
    );
  }
}

/// A map-preview-style placeholder for the issue location. Tapping the
/// action chip (or the box itself) triggers whatever location logic the
/// parent screen wires up -- this widget is purely presentational.
class _MapLocationPreview extends StatelessWidget {
  final bool hasLocation;
  final bool isLocating;
  final String actionLabel;
  final VoidCallback? onTap;

  const _MapLocationPreview({
    required this.hasLocation,
    required this.isLocating,
    required this.actionLabel,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final radius = BorderRadius.circular(AppRadius.card - 2);
    return InkWell(
      onTap: onTap,
      borderRadius: radius,
      child: Container(
        height: 130,
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: colorScheme.primaryContainer.withValues(alpha: 0.45),
          borderRadius: radius,
          border: Border.all(color: colorScheme.outlineVariant),
        ),
        child: Stack(
          children: [
            Center(
              child: Icon(
                Icons.location_on,
                size: 34,
                color: hasLocation ? colorScheme.error : colorScheme.error.withValues(alpha: 0.55),
              ),
            ),
            if (isLocating)
              Positioned.fill(
                child: Center(
                  child: SizedBox(
                    height: 22,
                    width: 22,
                    child: CircularProgressIndicator(strokeWidth: 2.4, color: colorScheme.error),
                  ),
                ),
              ),
            Positioned(
              bottom: 10,
              right: 10,
              child: Material(
                color: colorScheme.surface,
                borderRadius: BorderRadius.circular(AppRadius.pill),
                elevation: 1,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.sm),
                  child: Text(
                    actionLabel,
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                          color: colorScheme.onSurface,
                        ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A full-width primary button styled in the app's error color, used for
/// this screen's "Submit Report" action since it's a warning/report flow.
/// Mirrors [AppButton]'s loading behaviour without hardcoding a red hex.
class _DangerButton extends StatelessWidget {
  final String label;
  final bool isLoading;
  final VoidCallback? onPressed;

  const _DangerButton({
    required this.label,
    required this.isLoading,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final effectiveOnPressed = isLoading ? null : onPressed;
    final child = isLoading
        ? SizedBox(
            height: 20,
            width: 20,
            child: CircularProgressIndicator(strokeWidth: 2.4, color: colorScheme.onError),
          )
        : Text(label);

    return SizedBox(
      width: double.infinity,
      child: ElevatedButton(
        onPressed: effectiveOnPressed,
        style: ElevatedButton.styleFrom(
          backgroundColor: colorScheme.error,
          foregroundColor: colorScheme.onError,
          disabledBackgroundColor: colorScheme.error.withValues(alpha: 0.4),
          disabledForegroundColor: colorScheme.onError.withValues(alpha: 0.8),
          elevation: 0,
          minimumSize: const Size.fromHeight(52),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.pill)),
          textStyle: Theme.of(context).textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w600),
        ),
        child: child,
      ),
    );
  }
}
