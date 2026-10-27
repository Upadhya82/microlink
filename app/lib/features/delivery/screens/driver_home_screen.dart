import 'dart:async';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/models/order.dart';
import '../../../core/network/api_client.dart';
import '../../../core/network/offline_cache.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/network/multipart_upload.dart';
import '../../../core/network/session_manager.dart';
import '../../../core/theme/app_colors_extension.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/utils/app_router.dart';
import '../../../core/utils/view_state.dart';
import '../../../core/widgets/app_button.dart';
import '../../../core/widgets/app_card.dart';
import '../../../core/utils/validators.dart';
import '../../../core/widgets/app_text_field.dart';
import '../../../core/widgets/required_fields_note.dart';
import '../../../core/widgets/async_state_view.dart';
import '../../../core/widgets/list_filter_bar.dart';
import '../../../core/widgets/order_filters.dart';
import '../../../core/widgets/rating_chip.dart';
import '../../../core/widgets/skeleton_list.dart';
import '../../../core/widgets/status_badge.dart';
import '../../../core/widgets/branded_app_bar.dart';
import '../../account/document_types.dart';
import '../../account/widgets/document_tile.dart';

const List<String> _vehicleTypes = ['bike', 'scooter', 'car', 'van'];

/// SRS REQ-AGENT-1: the documents the driver profile needs. They are stored
/// in user-service, where the admin reviews them, and the profile keeps a
/// link to each.
const List<String> _profileDocTypes = ['national_id', 'driving_licence', 'police_clearance'];

enum _ProfileLoadState { loading, needsSetup, error, loaded }

/// The delivery agent's home base: profile setup (if none exists yet),
/// availability toggle, live location update, performance stats, their
/// currently-assigned orders, and nearby unassigned orders they can accept.
class DriverHomeScreen extends StatefulWidget {
  const DriverHomeScreen({super.key});

  @override
  State<DriverHomeScreen> createState() => _DriverHomeScreenState();
}

class _DriverHomeScreenState extends State<DriverHomeScreen> {
  /// Filter on the Available deliveries list (see order_filters.dart).
  String _jobFilter = 'all';
  _ProfileLoadState _profileLoadState = _ProfileLoadState.loading;
  String _profileError = '';
  Map<String, dynamic>? _profile;

  final _vehicleTypeController = ValueNotifier<String>('bike');
  final _licensePlateController = TextEditingController();
  final _phoneController = TextEditingController();
  // The driver's uploaded documents, by doc_type.
  Map<String, Map<String, dynamic>> _documents = {};
  final Set<String> _uploadingDocs = {};
  bool _submittingProfile = false;

  bool _availabilityBusy = false;
  bool _locationBusy = false;
  DateTime? _lastLocationUpdate;

  ViewState<Map<String, dynamic>> _performanceState = const ViewLoading();
  ViewState<List<DeliveryOrder>> _activeOrdersState = const ViewLoading();
  ViewState<List<DeliveryOrder>> _availableOrdersState = const ViewLoading();

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  @override
  void dispose() {
    _stopLocationUpdates();
    _licensePlateController.dispose();
    _phoneController.dispose();
    _vehicleTypeController.dispose();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    await _loadProfile();
    // Item 13: already online from a previous session, so keep the position
    // fresh without waiting for them to toggle anything.
    if (mounted && (_profile?['is_available'] as bool? ?? false)) {
      await _updateLocation(quiet: true);
      _startLocationUpdates();
    }
  }

  Future<void> _loadProfile() async {
    setState(() => _profileLoadState = _ProfileLoadState.loading);
    try {
      final response = await ApiClient.instance.get('/delivery/agents/me');
      _profile = Map<String, dynamic>.from(response as Map);
      if (!mounted) return;
      setState(() => _profileLoadState = _ProfileLoadState.loaded);
      unawaited(_loadDashboard());
    } on ApiException catch (e) {
      if (!mounted) return;
      if (e.isNotFound) {
        setState(() => _profileLoadState = _ProfileLoadState.needsSetup);
        unawaited(_loadDocuments());
      } else {
        setState(() {
          _profileError = e.message;
          _profileLoadState = _ProfileLoadState.error;
        });
      }
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _profileError = 'Something went wrong. Please try again.';
        _profileLoadState = _ProfileLoadState.error;
      });
    }
  }

  Future<void> _loadDashboard() async {
    await Future.wait([
      _loadPerformance(),
      _loadActiveOrders(),
      _loadAvailableOrders(),
    ]);
  }

  Future<void> _loadPerformance() async {
    setState(() => _performanceState = const ViewLoading());
    final userId = SessionManager.instance.userId;
    if (userId == null) {
      setState(() => _performanceState = const ViewError('No signed-in user.'));
      return;
    }
    try {
      final response = await ApiClient.instance.get('/delivery/agents/$userId/performance');
      if (!mounted) return;
      setState(() => _performanceState = ViewData(Map<String, dynamic>.from(response as Map)));
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _performanceState = ViewError(e.message));
    } catch (_) {
      if (!mounted) return;
      setState(() => _performanceState = const ViewError('Could not load performance stats.'));
    }
  }

  Future<void> _loadActiveOrders() async {
    setState(() => _activeOrdersState = const ViewLoading());
    try {
      final response = await ApiClient.instance.get('/delivery/orders/me');
      final rows = (response as List)
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
      final orders = rows
          .map(DeliveryOrder.fromJson)
          .where((o) => o.status != 'delivered' && o.status != 'cancelled')
          .toList();
      if (!mounted) return;
      setState(() => _activeOrdersState = ViewData(orders));
      // Item 14: a driver halfway up a lane with no signal still needs the
      // address, the codes and the route steps of the delivery they are on.
      final activeRows = rows.where((row) {
        final status = row['status'];
        return status != 'delivered' && status != 'cancelled';
      }).toList();
      unawaited(
        OfflineCache.save(OfflineCache.activeDeliveryKey, activeRows),
      );
    } on ApiException catch (e) {
      if (!mounted) return;
      if (!await _showCachedActiveOrders()) {
        if (mounted) setState(() => _activeOrdersState = ViewError(e.message));
      }
    } catch (_) {
      if (!mounted) return;
      if (!await _showCachedActiveOrders()) {
        if (mounted) {
          setState(
            () => _activeOrdersState =
                const ViewError('Could not load your orders.'),
          );
        }
      }
    }
  }

  /// Item 14: the active delivery as this phone last saw it, including its
  /// route steps. True when there was something to show.
  Future<bool> _showCachedActiveOrders() async {
    final cached = await OfflineCache.loadList(OfflineCache.activeDeliveryKey);
    if (cached == null || cached.rows.isEmpty || !mounted) return false;
    setState(
      () => _activeOrdersState =
          ViewData(cached.rows.map(DeliveryOrder.fromJson).toList()),
    );
    return true;
  }

  /// Why the available-orders list is empty (item 13).
  ///
  /// The server filters by distance from the position the driver last
  /// shared, so an empty list usually means that position is stale or was
  /// never shared at all -- which is exactly what the message now says.
  String _emptyOrdersReason() {
    if (!(_profile?['is_available'] as bool? ?? false)) {
      return 'You are offline. Go Online to start receiving orders.';
    }

    final radius = (_profile?['service_radius_km'] as num?)?.toStringAsFixed(0);
    final within = radius == null ? 'your area' : '$radius km';
    final shared = _locationSharedAt();

    if (shared == null) {
      return 'No orders within $within. Share your location so orders near '
          'you can be matched.';
    }
    return 'No orders within $within of where you were ${sharedAgo(shared)}. '
        'Tap the location button to share where you are now.';
  }

  /// When the server last heard where this driver is, preferring what this
  /// session shared over the stored timestamp.
  DateTime? _locationSharedAt() {
    if (_lastLocationUpdate != null) return _lastLocationUpdate;
    final raw = _profile?['location_updated_at'] as String?;
    if (raw == null) return null;
    return DateTime.tryParse(raw);
  }

  Future<void> _loadAvailableOrders() async {
    setState(() => _availableOrdersState = const ViewLoading());
    try {
      final response = await ApiClient.instance.get('/delivery/orders/available');
      final orders = (response as List)
          .map((e) => DeliveryOrder.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList();
      if (!mounted) return;
      setState(() => _availableOrdersState = ViewData(orders));
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _availableOrdersState = ViewError(e.message));
    } catch (_) {
      if (!mounted) return;
      setState(() => _availableOrdersState = const ViewError('Could not load available orders.'));
    }
  }

  /// The documents already sent -- at signup, or from the verification
  /// screen -- so the form shows them as done instead of asking again.
  Future<void> _loadDocuments() async {
    try {
      final response = await ApiClient.instance.get('/users/me/documents');
      final byType = <String, Map<String, dynamic>>{};
      for (final row in (response as List).whereType<Map>()) {
        final document = Map<String, dynamic>.from(row);
        byType[document['doc_type'] as String? ?? ''] = document;
      }
      if (!mounted) return;
      setState(() => _documents = byType);
    } catch (_) {
      // Not fatal: every document simply shows Upload.
    }
  }

  /// Pick an image (JPG, PNG, WebP) or a PDF and store it straight away, so
  /// the driver sees it ticked off before submitting the form.
  Future<void> _uploadDocument(DocType type) async {
    setState(() => _uploadingDocs.add(type.value));
    try {
      final picked = await MultipartUpload.pick(
        allowedExtensions: MultipartUpload.documentExtensions,
      );
      if (picked == null) return;
      final document = await MultipartUpload.send(
        path: '/users/me/documents',
        file: picked,
        fields: {'doc_type': type.value},
      );
      if (!mounted) return;
      setState(() => _documents[type.value] = document);
    } on ApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Could not upload that file.')));
    } finally {
      if (mounted) setState(() => _uploadingDocs.remove(type.value));
    }
  }

  String? _documentLink(String docType) {
    final id = _documents[docType]?['id'];
    return id == null ? null : '/users/documents/$id/file';
  }

  Future<void> _submitProfile() async {
    final plate = _licensePlateController.text.trim();
    final phone = _phoneController.text.trim();
    final idDoc = _documentLink('national_id');
    final licenseDoc = _documentLink('driving_licence');
    final policeDoc = _documentLink('police_clearance');
    // SRS REQ-AGENT-1: phone + ID document + driver's licence photo + police report.
    if (phone.isEmpty || idDoc == null || licenseDoc == null || policeDoc == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please enter your phone number and upload all three documents.'),
        ),
      );
      return;
    }
    setState(() => _submittingProfile = true);
    try {
      await ApiClient.instance.post(
        '/delivery/agents/profile',
        body: {
          'vehicle_type': _vehicleTypeController.value,
          if (plate.isNotEmpty) 'license_plate': plate,
          'phone': phone,
          'id_document_url': idDoc,
          'license_photo_url': licenseDoc,
          'police_report_url': policeDoc,
        },
      );
      if (!mounted) return;
      await _loadProfile();
    } on ApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Could not save your profile.')));
    } finally {
      if (mounted) setState(() => _submittingProfile = false);
    }
  }

  void _editProfile() {
    final p = _profile ?? const <String, dynamic>{};
    _vehicleTypeController.value = (p['vehicle_type'] as String?) ?? 'bike';
    _licensePlateController.text = (p['license_plate'] as String?) ?? '';
    _phoneController.text = (p['phone'] as String?) ?? '';
    setState(() => _profileLoadState = _ProfileLoadState.needsSetup);
    unawaited(_loadDocuments());
  }

  Future<void> _toggleAvailability(bool value) async {
    final previous = _profile?['is_available'] as bool? ?? false;
    setState(() {
      _profile = {...?_profile, 'is_available': value};
      _availabilityBusy = true;
    });
    try {
      await ApiClient.instance.patch(
        '/delivery/agents/me/availability',
        body: {'is_available': value},
      );
      if (!mounted) return;
      // Item 13: the job list is filtered against the last position the
      // driver shared, and sharing it was a button nobody pressed -- so a
      // driver in Colombo saw no Colombo orders. Going Online now shares it
      // straight away, and keeps it fresh while they stay online.
      if (value) {
        await _updateLocation(quiet: true);
        _startLocationUpdates();
      } else {
        _stopLocationUpdates();
      }
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _profile = {...?_profile, 'is_available': previous});
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } catch (_) {
      if (!mounted) return;
      setState(() => _profile = {...?_profile, 'is_available': previous});
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Could not update availability.')));
    } finally {
      if (mounted) setState(() => _availabilityBusy = false);
    }
  }

  /// How often to re-share the position while the driver is online. Often
  /// enough that the list follows them across town, rare enough not to sit
  /// on the GPS all shift.
  static const Duration _locationInterval = Duration(minutes: 3);

  Timer? _locationTimer;

  void _startLocationUpdates() {
    _locationTimer?.cancel();
    _locationTimer = Timer.periodic(_locationInterval, (_) {
      // Stop if they went offline or left the screen in the meantime.
      if (!mounted || !(_profile?['is_available'] as bool? ?? false)) {
        _stopLocationUpdates();
        return;
      }
      _updateLocation(quiet: true);
    });
  }

  void _stopLocationUpdates() {
    _locationTimer?.cancel();
    _locationTimer = null;
  }

  /// Shares the driver's position. [quiet] for the automatic shares, which
  /// must not interrupt with a snackbar on every success or failure.
  Future<void> _updateLocation({bool quiet = false}) async {
    if (!quiet) setState(() => _locationBusy = true);
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
        throw const ApiException('Location services are turned off.');
      }
      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.high),
      );
      await ApiClient.instance.patch(
        '/delivery/agents/me/location',
        body: {'lat': position.latitude, 'lng': position.longitude},
      );
      if (!mounted) return;
      setState(() => _lastLocationUpdate = DateTime.now());
      // An automatic share refreshes the list rather than announcing itself.
      if (quiet) {
        await _loadAvailableOrders();
        return;
      }
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Location updated.')));
      await _loadAvailableOrders();
    } on ApiException catch (e) {
      if (!mounted || quiet) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } catch (_) {
      if (!mounted || quiet) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Could not get your location.')));
    } finally {
      if (mounted && !quiet) setState(() => _locationBusy = false);
    }
  }

  Future<void> _acceptOrder(DeliveryOrder order) async {
    try {
      await ApiClient.instance.patch('/delivery/orders/${order.id}/accept');
      if (!mounted) return;
      final current = _availableOrdersState;
      if (current is ViewData<List<DeliveryOrder>>) {
        setState(() {
          _availableOrdersState =
              ViewData(current.data.where((o) => o.id != order.id).toList());
        });
      }
      Navigator.pushNamed(
        context,
        AppRoutes.deliveryTracking,
        arguments: DeliveryTrackingArgs(order.id),
      );
    } on ApiException catch (e) {
      if (!mounted) return;
      // 409 can mean "someone else took it" or "you already have an active
      // delivery"; the server's message says which.
      final message = e.message;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
      unawaited(_loadAvailableOrders());
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Could not accept this order.')));
      unawaited(_loadAvailableOrders());
    }
  }

  void _removeAvailable(String orderId) {
    final current = _availableOrdersState;
    if (current is ViewData<List<DeliveryOrder>>) {
      setState(() {
        _availableOrdersState =
            ViewData(current.data.where((o) => o.id != orderId).toList());
      });
    }
  }

  // SRS "Accept / Reject Order": tapping Reject (or the 30-second timer running
  // out) tells the backend, so the offer disappears from THIS agent's list and
  // is left for the next available agent.
  Future<void> _rejectOrder(DeliveryOrder order, {required String reason}) async {
    _removeAvailable(order.id);
    try {
      await ApiClient.instance.post(
        '/delivery/orders/${order.id}/reject',
        body: {'reason': reason},
      );
    } on ApiException catch (e) {
      // 409 = somebody else already took it. The card is gone either way.
      if (!mounted || e.statusCode == 409) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } catch (_) {
      // Nothing more to do: the offer is already hidden on this screen.
    }
  }

  Future<void> _openOrder(DeliveryOrder order) async {
    await Navigator.pushNamed(
      context,
      AppRoutes.deliveryTracking,
      arguments: DeliveryTrackingArgs(order.id),
    );
    // The order may have finished -- or been handed back -- while that
    // screen was open, and either frees this agent to take a new one, so
    // both lists have to be read again.
    if (!mounted) return;
    await _loadActiveOrders();
    await _loadAvailableOrders();
  }

  Future<void> _refreshAll() async {
    if (_profileLoadState == _ProfileLoadState.loaded) {
      await _loadDashboard();
    } else {
      await _loadProfile();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: BrandedAppBar(title: const Text('Driver Home')),
      body: RefreshIndicator(
        onRefresh: _refreshAll,
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: _buildBody(context),
        ),
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    switch (_profileLoadState) {
      case _ProfileLoadState.loading:
        return const SizedBox(
          height: 400,
          child: Center(child: CircularProgressIndicator()),
        );
      case _ProfileLoadState.error:
        return SizedBox(
          height: 400,
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.cloud_off_rounded, size: 48, color: Theme.of(context).colorScheme.error),
                const SizedBox(height: AppSpacing.md),
                Text(_profileError, textAlign: TextAlign.center),
                const SizedBox(height: AppSpacing.lg),
                AppButton(label: 'Retry', onPressed: _loadProfile, expand: false),
              ],
            ),
          ),
        );
      case _ProfileLoadState.needsSetup:
        return _buildProfileSetupForm(context);
      case _ProfileLoadState.loaded:
        return _buildDashboard(context);
    }
  }

  Widget _buildProfileSetupForm(BuildContext context) {
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Set up your driver profile', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: AppSpacing.xs),
          Text(
            'Tell us how you get around and send your documents. An admin checks them before you can accept deliveries.',
            style: Theme.of(context)
                .textTheme
                .bodyMedium
                ?.copyWith(color: context.appColors.textSecondary),
          ),
          const SizedBox(height: AppSpacing.lg),
          ValueListenableBuilder<String>(
            valueListenable: _vehicleTypeController,
            builder: (context, value, _) => DropdownButtonFormField<String>(
              initialValue: value,
              decoration: const InputDecoration(labelText: 'Vehicle type'),
              items: _vehicleTypes
                  .map((v) => DropdownMenuItem(value: v, child: Text(_vehicleLabel(v))))
                  .toList(),
              onChanged: (v) {
                if (v != null) _vehicleTypeController.value = v;
              },
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          const RequiredFieldsNote(),
          AppTextField(
            controller: _licensePlateController,
            label: 'License plate (optional)',
            hint: 'e.g. ABC-1234',
          ),
          const SizedBox(height: AppSpacing.lg),
          AppTextField(
            controller: _phoneController,
            // Item 5: required because this is a driver -- the customer
            // whose order they are carrying has to be able to reach them.
            label: 'Phone number',
            isRequired: true,
            hint: 'e.g. 0771234567',
            keyboardType: TextInputType.phone,
            prefixIcon: Icons.phone_outlined,
            validator: (v) =>
                Validators.required(v, field: 'Phone number') ?? Validators.phone(v),
          ),
          const SizedBox(height: AppSpacing.lg),
          Text('Documents', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: AppSpacing.xs),
          Text(
            'A photo (JPG or PNG) or a PDF for each, up to 8MB.',
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: context.appColors.textSecondary),
          ),
          const SizedBox(height: AppSpacing.sm),
          for (final docType in _profileDocTypes)
            DocumentTile(
              type: docTypeFor(docType),
              document: _documents[docType],
              uploading: _uploadingDocs.contains(docType),
              onUpload: _uploadDocument,
            ),
          const SizedBox(height: AppSpacing.lg),
          AppButton(
            label: 'Submit application',
            isLoading: _submittingProfile,
            onPressed: _submitProfile,
          ),
          if (_profile != null)
            Center(
              child: TextButton(
                onPressed: () => setState(() => _profileLoadState = _ProfileLoadState.loaded),
                child: const Text('Cancel'),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildDashboard(BuildContext context) {
    final isAvailable = _profile?['is_available'] as bool? ?? false;
    final activeState = _activeOrdersState;
    // SRS REQ-AGENT-3: an agent can hold only one active delivery at a time.
    final hasActiveOrder =
        activeState is ViewData<List<DeliveryOrder>> && activeState.data.isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Welcome back',
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(color: context.appColors.textSecondary),
                  ),
                  Text(
                    SessionManager.instance.userName ?? 'Driver',
                    style: Theme.of(context)
                        .textTheme
                        .titleLarge
                        ?.copyWith(fontWeight: FontWeight.w800),
                  ),
                ],
              ),
            ),
            const SizedBox(width: AppSpacing.md),
            _AvailabilityPill(
              isAvailable: isAvailable,
              busy: _availabilityBusy,
              onTap: () => _toggleAvailability(!isAvailable),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.md),
        Row(
          children: [
            Icon(Icons.my_location_outlined, size: 14, color: context.appColors.textSecondary),
            const SizedBox(width: AppSpacing.xs),
            Expanded(
              child: Text(
                _lastLocationUpdate == null
                    ? 'Location not shared yet this session'
                    : 'Location last updated ${_formatTime(_lastLocationUpdate!)}',
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: context.appColors.textSecondary),
              ),
            ),
            _locationBusy
                ? const Padding(
                    padding: EdgeInsets.symmetric(horizontal: AppSpacing.sm),
                    child: SizedBox(
                      height: 14,
                      width: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                : TextButton(
                    onPressed: _updateLocation,
                    child: const Text('Update'),
                  ),
          ],
        ),
        const SizedBox(height: AppSpacing.lg),
        AppCard(child: _buildPerformanceRow(context)),
        if (_profile?['application_status'] == 'rejected') ...[
          const SizedBox(height: AppSpacing.md),
          AppCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Your application was rejected',
                  style: Theme.of(context)
                      .textTheme
                      .titleSmall
                      ?.copyWith(color: Theme.of(context).colorScheme.error),
                ),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  (_profile?['review_note'] as String?)?.isNotEmpty == true
                      ? 'Reason: ${_profile!['review_note']}'
                      : 'The admin did not give a reason.',
                ),
                const SizedBox(height: AppSpacing.md),
                AppButton(
                  label: 'Update my details',
                  variant: AppButtonVariant.outlined,
                  expand: false,
                  onPressed: _editProfile,
                ),
              ],
            ),
          ),
        ],
        if (_profile?['documents_complete'] == false) ...[
          const SizedBox(height: AppSpacing.md),
          AppCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Your application is incomplete',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  'Add your phone number and documents so an admin can verify you.',
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: context.appColors.textSecondary),
                ),
                const SizedBox(height: AppSpacing.md),
                AppButton(
                  label: 'Add my details',
                  variant: AppButtonVariant.outlined,
                  expand: false,
                  onPressed: _editProfile,
                ),
              ],
            ),
          ),
        ],
        const SizedBox(height: AppSpacing.xl),
        Text('My active orders', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: AppSpacing.sm),
        SizedBox(
          height: 260,
          child: AsyncStateView<List<DeliveryOrder>>(
            state: _activeOrdersState,
            onRetry: _loadActiveOrders,
            isEmpty: (data) => data.isEmpty,
            emptyTitle: 'No active orders',
            emptyMessage: 'Accept an order below to get started.',
            emptyIcon: Icons.local_shipping_outlined,
            loadingSkeleton: const SkeletonList(itemCount: 2, itemHeight: 80),
            builder: (context, orders) => ListView.separated(
              itemCount: orders.length,
              separatorBuilder: (_, _) => const SizedBox(height: AppSpacing.sm),
              itemBuilder: (context, index) {
                final order = orders[index];
                return _ActiveOrderTile(order: order, onTap: () => _openOrder(order));
              },
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.xl),
        Text('Available deliveries', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: AppSpacing.sm),
        if (hasActiveOrder) ...[
          AppCard(
            child: Row(
              children: [
                Icon(Icons.info_outline, size: 18, color: context.appColors.textSecondary),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text(
                    'You already have an active delivery. Finish it before accepting another one.',
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(color: context.appColors.textSecondary),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
        ],
        SizedBox(
          height: 360,
          child: AsyncStateView<List<DeliveryOrder>>(
            state: _availableOrdersState,
            onRetry: _loadAvailableOrders,
            isEmpty: (data) => data.isEmpty,
            emptyTitle: 'No orders nearby',
            // Item 13: say WHY the list is empty. It is filtered against the
            // last position shared, so a driver who had moved saw nothing
            // and had no way to tell that was the reason.
            emptyMessage: _emptyOrdersReason(),
            emptyIcon: Icons.explore_off_outlined,
            loadingSkeleton: const SkeletonList(itemCount: 3, itemHeight: 96),
            builder: (context, allOrders) {
              final orders = filterAvailableJobs(allOrders, _jobFilter);
              return Column(
                children: [
                  ListFilterBar<String>(
                    padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                    options: availableJobFilterOptions(allOrders),
                    selected: _jobFilter,
                    onSelected: (value) => setState(() => _jobFilter = value),
                  ),
                  if (orders.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(AppSpacing.lg),
                      child: Text('No deliveries match this filter.'),
                    ),
                  Expanded(
                    child: ListView.separated(
                      itemCount: orders.length,
                      separatorBuilder: (_, _) => const SizedBox(height: AppSpacing.sm),
                      itemBuilder: (context, index) {
                        final order = orders[index];
                        return _AvailableOrderTile(
                          key: ValueKey(order.id),
                          order: order,
                          canAccept: !hasActiveOrder,
                          onAccept: () => _acceptOrder(order),
                          onDecline: () => _rejectOrder(order, reason: 'declined'),
                          onTimeout: () => _rejectOrder(order, reason: 'timeout'),
                        );
                      },
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }

  // A lighter-weight inline treatment (rather than AsyncStateView, which is
  // sized for full sections) so this compact stats row never risks
  // overflowing a fixed height in its error state.
  Widget _buildPerformanceRow(BuildContext context) {
    final state = _performanceState;
    return switch (state) {
      ViewLoading<Map<String, dynamic>>() => const Padding(
          padding: EdgeInsets.symmetric(vertical: AppSpacing.sm),
          child: SizedBox(
            height: 20,
            width: 20,
            child: CircularProgressIndicator(strokeWidth: 2.4),
          ),
        ),
      ViewError<Map<String, dynamic>>(:final message) => Row(
          children: [
            Expanded(
              child: Text(
                message,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
            TextButton(onPressed: _loadPerformance, child: const Text('Retry')),
          ],
        ),
      ViewData<Map<String, dynamic>>(:final data) => _buildPerformanceStats(context, data),
    };
  }

  // SRS REQ-AGENT-5: total deliveries, average rating, on-time %, and the
  // computed performance score (1-5).
  Widget _buildPerformanceStats(BuildContext context, Map<String, dynamic> data) {
    final divider = Container(
      width: 1,
      height: 34,
      color: Theme.of(context).colorScheme.outlineVariant,
    );
    final onTime = (data['on_time_percentage'] as num?)?.toDouble();
    final score = (data['performance_score'] as num?)?.toDouble();
    return Row(
      children: [
        Expanded(
          child: _StatColumn(value: '${data['total_deliveries'] ?? 0}', label: 'Deliveries'),
        ),
        divider,
        Expanded(
          child: _StatColumn(
            ratingValue: (data['rating_avg'] as num?)?.toDouble() ?? 0.0,
            label: 'Rating',
          ),
        ),
        divider,
        Expanded(
          child: _StatColumn(
            value: onTime == null ? '-' : '${onTime.toStringAsFixed(0)}%',
            label: 'On time',
          ),
        ),
        divider,
        Expanded(
          child: _StatColumn(
            value: score == null ? '-' : score.toStringAsFixed(1),
            label: 'Score',
          ),
        ),
      ],
    );
  }
}

/// A tappable pill showing the driver's online/offline state, wired to the
/// same [DriverHomeScreen._toggleAvailability] call as before.
class _AvailabilityPill extends StatelessWidget {
  final bool isAvailable;
  final bool busy;
  final VoidCallback onTap;

  const _AvailabilityPill({required this.isAvailable, required this.busy, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final colors = context.appColors;
    final background = isAvailable ? colorScheme.primaryContainer : colorScheme.surfaceContainerHighest;
    final foreground = isAvailable ? colors.success : colors.textSecondary;
    return InkWell(
      borderRadius: BorderRadius.circular(AppRadius.pill),
      onTap: busy ? null : onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.sm),
        decoration: BoxDecoration(color: background, borderRadius: BorderRadius.circular(AppRadius.pill)),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (busy)
              SizedBox(
                height: 8,
                width: 8,
                child: CircularProgressIndicator(strokeWidth: 1.5, color: foreground),
              )
            else
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(color: foreground, shape: BoxShape.circle),
              ),
            const SizedBox(width: AppSpacing.sm),
            Text(
              isAvailable ? 'Online' : 'Offline',
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: foreground,
                    fontWeight: FontWeight.w700,
                  ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatColumn extends StatelessWidget {
  final String? value;
  final double? ratingValue;
  final String label;

  const _StatColumn({this.value, this.ratingValue, required this.label});

  @override
  Widget build(BuildContext context) {
    final valueStyle =
        Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800);
    return Column(
      children: [
        ratingValue != null
            ? RatingChip(rating: ratingValue!, iconSize: 16, textStyle: valueStyle)
            : Text(value ?? '-', style: valueStyle),
        const SizedBox(height: 2),
        Text(
          label,
          style: Theme.of(context)
              .textTheme
              .bodySmall
              ?.copyWith(color: context.appColors.textSecondary),
        ),
      ],
    );
  }
}

class _ActiveOrderTile extends StatelessWidget {
  final DeliveryOrder order;
  final VoidCallback onTap;

  const _ActiveOrderTile({required this.order, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return AppCard(
      onTap: onTap,
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _shortOrderId(order.id),
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  order.deliveryAddress,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: context.appColors.textSecondary),
                ),
                const SizedBox(height: AppSpacing.sm),
                StatusBadge(
                  label: formatOrderStatusLabel(order.status),
                  background: colorScheme.primaryContainer,
                  foreground: colorScheme.primary,
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

/// One "available deliveries" card (SRS REQ-AGENT-2): order reference, the fee
/// the customer offers, pickup -> drop addresses with distances, a 30-second
/// countdown, and Reject / Accept. When the timer reaches zero the offer is
/// reported to the backend as a timeout (hidden from this agent for a while).
class _AvailableOrderTile extends StatefulWidget {
  final DeliveryOrder order;
  final bool canAccept;
  final VoidCallback onAccept;
  final VoidCallback onDecline;
  final VoidCallback onTimeout;

  const _AvailableOrderTile({
    super.key,
    required this.order,
    required this.canAccept,
    required this.onAccept,
    required this.onDecline,
    required this.onTimeout,
  });

  @override
  State<_AvailableOrderTile> createState() => _AvailableOrderTileState();
}

class _AvailableOrderTileState extends State<_AvailableOrderTile> {
  static const _offerSeconds = 30;

  Timer? _timer;
  int _secondsLeft = _offerSeconds;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      if (_secondsLeft <= 1) {
        timer.cancel();
        widget.onTimeout();
        return;
      }
      setState(() => _secondsLeft--);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final order = widget.order;
    final colorScheme = Theme.of(context).colorScheme;
    final colors = context.appColors;
    final fee = order.totalAmount > 0
        ? 'Rs. ${order.totalAmount.toStringAsFixed(2)}'
        : 'Fee to be agreed';
    final pickupText = (order.pickupAddress != null && order.pickupAddress!.isNotEmpty)
        ? order.pickupAddress!
        : 'Pickup at the shop';
    final awayText =
        order.distanceKm != null ? ' · ${order.distanceKm!.toStringAsFixed(1)} km away' : '';
    final tripText = order.tripDistanceKm != null
        ? ' · ${order.tripDistanceKm!.toStringAsFixed(1)} km trip'
        : '';
    final note = order.itemDescription;

    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  _shortOrderId(order.id),
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700),
                ),
              ),
              Text(
                fee,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                      color: colorScheme.primary,
                    ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            'Respond within ${_secondsLeft}s',
            style: Theme.of(context).textTheme.labelSmall?.copyWith(color: colors.warning),
          ),
          const SizedBox(height: AppSpacing.md),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _RouteDot(color: colorScheme.primary),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text.rich(
                  TextSpan(
                    text: pickupText,
                    style: Theme.of(context).textTheme.bodyMedium,
                    children: awayText.isNotEmpty
                        ? [
                            TextSpan(
                              text: awayText,
                              style: TextStyle(color: colors.textSecondary),
                            ),
                          ]
                        : const [],
                  ),
                ),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(left: 3.75),
            child: _DashedConnector(color: colorScheme.outlineVariant),
          ),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _RouteDot(color: colorScheme.error),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text.rich(
                  TextSpan(
                    text: order.deliveryAddress,
                    style: Theme.of(context).textTheme.bodyMedium,
                    children: tripText.isNotEmpty
                        ? [
                            TextSpan(
                              text: tripText,
                              style: TextStyle(color: colors.textSecondary),
                            ),
                          ]
                        : const [],
                  ),
                ),
              ),
            ],
          ),
          if (note != null && note.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.sm),
            Text(
              'Note: $note',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: colors.textSecondary),
            ),
          ],
          const SizedBox(height: AppSpacing.lg),
          Row(
            children: [
              Expanded(
                child: AppButton(
                  label: 'Reject',
                  variant: AppButtonVariant.outlined,
                  expand: false,
                  onPressed: widget.onDecline,
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: AppButton(
                  label: 'Accept',
                  expand: false,
                  onPressed: widget.canAccept ? widget.onAccept : null,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// A small filled circle marking one end of the pickup/dropoff route.
class _RouteDot extends StatelessWidget {
  final Color color;

  const _RouteDot({required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 9,
      height: 9,
      margin: const EdgeInsets.symmetric(vertical: 2),
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }
}

/// The short dashed vertical line connecting the pickup and dropoff dots.
class _DashedConnector extends StatelessWidget {
  final Color color;

  const _DashedConnector({required this.color});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 16,
      width: 1.5,
      child: CustomPaint(painter: _DashedLinePainter(color: color)),
    );
  }
}

class _DashedLinePainter extends CustomPainter {
  final Color color;

  const _DashedLinePainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = size.width;
    const dashHeight = 3.0;
    const dashSpace = 3.0;
    var y = 0.0;
    while (y < size.height) {
      canvas.drawLine(Offset(size.width / 2, y), Offset(size.width / 2, y + dashHeight), paint);
      y += dashHeight + dashSpace;
    }
  }

  @override
  bool shouldRepaint(covariant _DashedLinePainter oldDelegate) => oldDelegate.color != color;
}

/// Shortens a UUID order id into a compact, display-friendly reference (the
/// backend has no separate human-readable order number).
String _shortOrderId(String id) {
  final cleaned = id.replaceAll('-', '').toUpperCase();
  final tail = cleaned.length > 6 ? cleaned.substring(cleaned.length - 6) : cleaned;
  return 'Order #$tail';
}

String _vehicleLabel(String value) {
  return switch (value) {
    'bike' => 'Bike',
    'scooter' => 'Scooter',
    'car' => 'Car',
    'van' => 'Van',
    _ => value,
  };
}

/// How long ago the driver's position was shared, in words (item 13).
///
/// Top-level and named without an underscore so the empty-list wording can
/// be unit tested; the sentence it goes into is
/// "...where you were 2 hours ago".
String sharedAgo(DateTime moment, {DateTime? now}) {
  final difference = (now ?? DateTime.now()).difference(moment);
  if (difference.isNegative || difference.inMinutes < 1) return 'just now';
  if (difference.inMinutes < 60) {
    final minutes = difference.inMinutes;
    return minutes == 1 ? '1 minute ago' : '$minutes minutes ago';
  }
  if (difference.inHours < 24) {
    final hours = difference.inHours;
    return hours == 1 ? '1 hour ago' : '$hours hours ago';
  }
  final days = difference.inDays;
  return days == 1 ? 'yesterday' : '$days days ago';
}

String _formatTime(DateTime dt) {
  final h = dt.hour.toString().padLeft(2, '0');
  final m = dt.minute.toString().padLeft(2, '0');
  return '$h:$m';
}
