import 'dart:async';
import 'package:flutter/material.dart';
import '../../../core/widgets/stagger_in.dart';
import '../../../core/models/order.dart';
import 'package:geolocator/geolocator.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/models/shop.dart';
import '../../../core/network/api_client.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/network/multipart_upload.dart';
import '../../../core/network/session_manager.dart';
import '../../../core/theme/app_colors_extension.dart';
import '../../../core/theme/app_spacing.dart';
import '../../location/widgets/location_field.dart';
import '../../../core/widgets/list_filter_bar.dart';
import '../../../core/widgets/order_filters.dart';
import '../widgets/owner_filters.dart';
import '../widgets/product_category_field.dart';
import '../widgets/shop_performance_section.dart';
import '../../notifications/widgets/notification_bell.dart';
import '../../../core/utils/media_url.dart';
import '../../../core/theme/theme_controller.dart';
import '../../../core/utils/route_args.dart';
import '../../../core/utils/validators.dart';
import '../../../core/utils/view_state.dart';
import '../../../core/widgets/app_button.dart';
import '../../../core/widgets/app_card.dart';
import '../../../core/widgets/app_text_field.dart';
import '../../../core/widgets/required_fields_note.dart';
import '../../../core/widgets/async_state_view.dart';
import '../../../core/widgets/rating_chip.dart';
import '../../../core/widgets/skeleton_list.dart';
import '../../../core/widgets/status_badge.dart';
import '../../../core/widgets/branded_app_bar.dart';

/// The Shop Owner's workspace: their shop's open/closed status, products,
/// alerts and analytics, all on one screen. Serves two roles:
///
///  * as the shop owner's **Home tab** -- pass [onOpenAccount], and it renders
///    a greeting header (with theme + account buttons) and no Scaffold, since
///    HomeScreen supplies the Scaffold and bottom nav.
///  * as a **standalone route** -- leave [onOpenAccount] null and it renders
///    its own Scaffold + AppBar (used by the "manage your shop" hint link on
///    a shop's detail page).
///
/// If the owner manages more than one shop a selector switches between them;
/// if they have none it shows a create-shop prompt.
class ShopOwnerDashboardScreen extends StatefulWidget {
  final void Function(BuildContext context)? onOpenAccount;

  const ShopOwnerDashboardScreen({super.key, this.onOpenAccount});

  @override
  State<ShopOwnerDashboardScreen> createState() =>
      _ShopOwnerDashboardScreenState();
}

class _ShopOwnerDashboardScreenState extends State<ShopOwnerDashboardScreen> {
  ViewState<List<Shop>> _state = const ViewLoading();
  String? _selectedShopId;

  bool get _embedded => widget.onOpenAccount != null;

  @override
  void initState() {
    super.initState();
    _loadShops();
  }

  Future<void> _loadShops() async {
    setState(() => _state = const ViewLoading());
    try {
      final response = await ApiClient.instance.get('/shops/owner/me') as List;
      final shops = response
          .map((e) => Shop.fromJson(e as Map<String, dynamic>))
          .toList();
      if (!mounted) return;
      setState(() {
        _state = ViewData(shops);
        // Keep the current selection if it still exists, else pick the first.
        if (shops.every((s) => s.id != _selectedShopId)) {
          _selectedShopId = shops.isNotEmpty ? shops.first.id : null;
        }
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _state = ViewError(e.message));
    }
  }

  Future<void> _openCreateShopForm() async {
    final created = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (_) => const _ShopFormSheet(),
    );
    if (created == true) _loadShops();
  }

  @override
  Widget build(BuildContext context) {
    if (_embedded) {
      return Column(
        children: [
          _EmbeddedHeader(onOpenAccount: widget.onOpenAccount!),
          Expanded(child: _content()),
        ],
      );
    }
    return Scaffold(
      appBar: BrandedAppBar(
        title: const Text('My Shops'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: 'Create Shop',
            onPressed: _openCreateShopForm,
          ),
        ],
      ),
      body: _content(),
    );
  }

  Widget _content() {
    return AsyncStateView<List<Shop>>(
      state: _state,
      onRetry: _loadShops,
      builder: (context, shops) {
        if (shops.isEmpty) return _emptyState();
        final selected = shops.firstWhere(
          (s) => s.id == _selectedShopId,
          orElse: () => shops.first,
        );
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.md, AppSpacing.sm, 0),
              child: Row(
                children: [
                  if (shops.length > 1)
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        initialValue: selected.id,
                        isExpanded: true,
                        decoration: const InputDecoration(labelText: 'Shop', isDense: true),
                        items: shops
                            .map((s) => DropdownMenuItem(
                                  value: s.id,
                                  child: Text(s.name, overflow: TextOverflow.ellipsis),
                                ))
                            .toList(),
                        onChanged: (value) => setState(() => _selectedShopId = value),
                      ),
                    )
                  else
                    Expanded(
                      child: Text(
                        selected.name,
                        style: Theme.of(context)
                            .textTheme
                            .titleMedium
                            ?.copyWith(fontWeight: FontWeight.w700),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  const SizedBox(width: AppSpacing.sm),
                  selected.isOpen ? StatusBadge.open(context) : StatusBadge.closed(context),
                  if (_embedded)
                    IconButton(
                      icon: const Icon(Icons.add_circle_outline),
                      tooltip: 'Create another shop',
                      onPressed: _openCreateShopForm,
                    ),
                ],
              ),
            ),
            // Item 6: the owner should not have to wonder why their shop
            // carries a "Not verified" chip for customers.
            if (selected.awaitingVerification)
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.lg,
                  0,
                  AppSpacing.lg,
                  AppSpacing.md,
                ),
                child: _AwaitingVerificationBanner(shop: selected),
              ),
            Expanded(
              child: _ShopWorkspace(
                key: ValueKey(selected.id),
                shop: selected,
                onChanged: _loadShops,
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _emptyState() {
    return RefreshIndicator(
      onRefresh: _loadShops,
      child: LayoutBuilder(
        builder: (context, constraints) => SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(AppSpacing.xxl),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.storefront_outlined,
                      size: 56,
                      color: context.appColors.textSecondary,
                    ),
                    const SizedBox(height: AppSpacing.lg),
                    Text(
                      "You haven't listed a shop yet",
                      style: Theme.of(context).textTheme.titleMedium,
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: AppSpacing.xs),
                    Text(
                      'Create your shop profile so customers can find you.',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodyMedium
                          ?.copyWith(color: context.appColors.textSecondary),
                    ),
                    const SizedBox(height: AppSpacing.lg),
                    AppButton(
                      label: 'Create Shop',
                      icon: Icons.add,
                      expand: false,
                      onPressed: _openCreateShopForm,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The greeting strip shown above the workspace when it is the shop owner's
/// Home tab -- mirrors the header the other role homes use.
class _EmbeddedHeader extends StatelessWidget {
  final void Function(BuildContext context) onOpenAccount;

  const _EmbeddedHeader({required this.onOpenAccount});

  @override
  Widget build(BuildContext context) {
    final session = SessionManager.instance;
    final textTheme = Theme.of(context).textTheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Padding(
      padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.sm, AppSpacing.sm, 0),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _greeting(),
                  style: textTheme.bodyMedium?.copyWith(color: context.appColors.textSecondary),
                ),
                Text(
                  'Hi, ${session.userName ?? 'there'}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800),
                ),
              ],
            ),
          ),
          IconButton(
            icon: Icon(isDark ? Icons.light_mode_outlined : Icons.dark_mode_outlined),
            tooltip: 'Switch to ${isDark ? 'light' : 'dark'} mode',
            onPressed: () => ThemeController.instance.toggle(Theme.of(context).brightness),
          ),
          // Order, review, low-stock and verification alerts all land in the
          // notification centre; the bell keeps it one tap away instead of
          // behind the account sheet.
          const NotificationBell(),
          IconButton(
            icon: const Icon(Icons.account_circle_outlined),
            tooltip: 'Account',
            onPressed: () => onOpenAccount(context),
          ),
        ],
      ),
    );
  }

  String _greeting() {
    final hour = DateTime.now().hour;
    if (hour < 12) return 'Good morning';
    if (hour < 17) return 'Good afternoon';
    return 'Good evening';
  }
}

// ---------------------------------------------------------------------------
// Create / edit shop form
// ---------------------------------------------------------------------------

String _formatTimeOfDay(TimeOfDay time) =>
    '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';

TimeOfDay? _parseTimeOfDay(String? value) {
  if (value == null) return null;
  final parts = value.split(':');
  if (parts.length != 2) return null;
  final hour = int.tryParse(parts[0]);
  final minute = int.tryParse(parts[1]);
  if (hour == null || minute == null) return null;
  return TimeOfDay(hour: hour, minute: minute);
}

String _formatDate(DateTime date) {
  final local = date.toLocal();
  final month = local.month.toString().padLeft(2, '0');
  final day = local.day.toString().padLeft(2, '0');
  return '$month/$day/${local.year}';
}

const List<String> _weekdayLabels = [
  'Mon',
  'Tue',
  'Wed',
  'Thu',
  'Fri',
  'Sat',
  'Sun',
];

String _shortWeekday(DateTime date) => _weekdayLabels[date.weekday - 1];

/// Create/edit form for a shop, shown as a scrollable bottom sheet. Pops with
/// `true` when the shop was created/updated so the caller can refresh.
class _ShopFormSheet extends StatefulWidget {
  final Shop? existingShop;
  const _ShopFormSheet({this.existingShop});

  @override
  State<_ShopFormSheet> createState() => _ShopFormSheetState();
}

class _ShopFormSheetState extends State<_ShopFormSheet> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameController;
  late final TextEditingController _descController;
  late final TextEditingController _addressController;
  late final TextEditingController _phoneController;
  late final TextEditingController _imageUrlController;
  String? _category;
  TimeOfDay? _openingTime;
  TimeOfDay? _closingTime;
  double? _latitude;
  double? _longitude;
  bool _locating = false;
  bool _isSubmitting = false;

  @override
  void initState() {
    super.initState();
    final existing = widget.existingShop;
    _nameController = TextEditingController(text: existing?.name ?? '');
    _descController = TextEditingController(text: existing?.description ?? '');
    _addressController = TextEditingController(text: existing?.address ?? '');
    _phoneController = TextEditingController(text: existing?.phone ?? '');
    _imageUrlController = TextEditingController(text: existing?.imageUrl ?? '');
    _category = existing?.category;
    _openingTime = _parseTimeOfDay(existing?.openingTime);
    _closingTime = _parseTimeOfDay(existing?.closingTime);
    _latitude = existing?.latitude;
    _longitude = existing?.longitude;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _descController.dispose();
    _addressController.dispose();
    _phoneController.dispose();
    _imageUrlController.dispose();
    super.dispose();
  }

  Future<void> _useCurrentLocation() async {
    setState(() => _locating = true);
    try {
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        throw const ApiException('Location permission was denied.');
      }
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        throw const ApiException(
          'Please enable location services and try again.',
        );
      }
      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
        ),
      );
      if (!mounted) return;
      setState(() {
        _latitude = position.latitude;
        _longitude = position.longitude;
      });
    } catch (e) {
      if (!mounted) return;
      final message = e is ApiException
          ? e.message
          : 'Could not get your current location.';
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    } finally {
      if (mounted) setState(() => _locating = false);
    }
  }

  Future<void> _submit() async {
    final formState = _formKey.currentState;
    if (formState == null || !formState.validate()) return;
    if (_openingTime == null || _closingTime == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Select your usual opening and closing hours.'),
        ),
      );
      return;
    }
    if (_latitude == null || _longitude == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Set the shop location.')));
      return;
    }

    setState(() => _isSubmitting = true);
    final body = <String, dynamic>{
      'name': _nameController.text.trim(),
      'description': _descController.text.trim(),
      'category': _category,
      'address': _addressController.text.trim(),
      'latitude': _latitude,
      'longitude': _longitude,
      'opening_time': _formatTimeOfDay(_openingTime!),
      'closing_time': _formatTimeOfDay(_closingTime!),
      if (_phoneController.text.trim().isNotEmpty)
        'phone': _phoneController.text.trim(),
      if (_imageUrlController.text.trim().isNotEmpty)
        'image_url': _imageUrlController.text.trim(),
    };

    try {
      if (widget.existingShop != null) {
        await ApiClient.instance.patch(
          '/shops/${widget.existingShop!.id}',
          body: body,
        );
      } else {
        await ApiClient.instance.post('/shops', body: body);
      }
      if (!mounted) return;
      Navigator.pop(context, true);
    } on ApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  Widget _buildTimeField(
    String label,
    TimeOfDay? value,
    ValueChanged<TimeOfDay> onChanged,
  ) {
    return InkWell(
      borderRadius: BorderRadius.circular(AppRadius.input),
      onTap: () async {
        final picked = await showTimePicker(
          context: context,
          initialTime: value ?? const TimeOfDay(hour: 9, minute: 0),
        );
        if (picked != null) onChanged(picked);
      },
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: label,
          suffixIcon: const Icon(Icons.access_time_outlined),
        ),
        child: Text(value == null ? 'Select time' : value.format(context)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isEdit = widget.existingShop != null;
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.xl),
          child: Form(
            key: _formKey,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    isEdit ? 'Edit Shop Details' : 'Create Shop',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: AppSpacing.lg),
                  const RequiredFieldsNote(),
                  AppTextField(
                    controller: _nameController,
                    label: 'Shop name',
                    isRequired: true,
                    validator: (v) =>
                        Validators.required(v, field: 'Shop name'),
                  ),
                  const SizedBox(height: AppSpacing.md),
                  AppTextField(
                    controller: _descController,
                    label: 'Description',
                    isRequired: true,
                    maxLines: 3,
                    validator: (v) =>
                        Validators.required(v, field: 'Description'),
                  ),
                  const SizedBox(height: AppSpacing.md),
                  DropdownButtonFormField<String>(
                    initialValue: _category,
                    decoration: const InputDecoration(labelText: 'Category'),
                    items: shopCategories
                        .map(
                          (c) => DropdownMenuItem(
                            value: c,
                            child: Text(formatCategoryLabel(c)),
                          ),
                        )
                        .toList(),
                    onChanged: (value) => setState(() => _category = value),
                    validator: (value) =>
                        value == null ? 'Select a category' : null,
                  ),
                  const SizedBox(height: AppSpacing.md),
                  AppTextField(
                    controller: _addressController,
                    label: 'Address',
                    isRequired: true,
                    validator: (v) => Validators.required(v, field: 'Address'),
                  ),
                  const SizedBox(height: AppSpacing.md),
                  AppTextField(
                    controller: _phoneController,
                    label: 'Phone (optional)',
                    keyboardType: TextInputType.phone,
                    validator: Validators.phone,
                  ),
                  const SizedBox(height: AppSpacing.md),
                  AppTextField(
                    controller: _imageUrlController,
                    label: 'Image URL (optional)',
                    keyboardType: TextInputType.url,
                  ),
                  const SizedBox(height: AppSpacing.md),
                  // One under the other: side by side, the longer labels
                  // were cut off on a phone.
                  _buildTimeField(
                    'Usual Opening Hours',
                    _openingTime,
                    (value) => setState(() => _openingTime = value),
                  ),
                  const SizedBox(height: AppSpacing.md),
                  _buildTimeField(
                    'Usual Closing Hours',
                    _closingTime,
                    (value) => setState(() => _closingTime = value),
                  ),
                  const SizedBox(height: AppSpacing.lg),
                  Text(
                    'Location',
                    style: Theme.of(context).textTheme.labelLarge,
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  // A shop owner is often not standing in their shop when
                  // they register it, so "use my location" alone is not
                  // enough -- they can drop the pin on the map instead.
                  LocationField(
                    latitude: _latitude,
                    longitude: _longitude,
                    isLocating: _locating,
                    pickerTitle: 'Where is your shop?',
                    confirmLabel: 'Use this location',
                    onUseMyLocation: _useCurrentLocation,
                    onPicked: (picked) => setState(() {
                      _latitude = picked.latitude;
                      _longitude = picked.longitude;
                      if (_addressController.text.trim().isEmpty &&
                          picked.address.isNotEmpty) {
                        _addressController.text = picked.address;
                      }
                    }),
                  ),
                  const SizedBox(height: AppSpacing.xl),
                  AppButton(
                    label: isEdit ? 'Save Changes' : 'Create Shop',
                    isLoading: _isSubmitting,
                    requiresConnection: true,
                    onPressed: _isSubmitting ? null : _submit,
                  ),
                  const SizedBox(height: AppSpacing.lg),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Per-shop workspace: status, products, alerts, analytics (no Scaffold of its
// own -- embedded in the shop owner's Home tab / dashboard screen above).
// ---------------------------------------------------------------------------

class _ShopWorkspace extends StatefulWidget {
  final Shop shop;

  /// Called after a change that the parent's shop list should reflect (status
  /// toggled, details edited) so it can re-fetch.
  final VoidCallback onChanged;

  const _ShopWorkspace({super.key, required this.shop, required this.onChanged});

  @override
  State<_ShopWorkspace> createState() => _ShopWorkspaceState();
}

class _ShopWorkspaceState extends State<_ShopWorkspace> {
  late Shop _shop;
  late bool _isOpen;
  bool _togglingStatus = false;

  @override
  void initState() {
    super.initState();
    _shop = widget.shop;
    _isOpen = widget.shop.isOpen;
  }

  @override
  void didUpdateWidget(covariant _ShopWorkspace oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Parent handed us a refreshed copy of the same shop (e.g. after an edit).
    if (!identical(oldWidget.shop, widget.shop) && !_togglingStatus) {
      _shop = widget.shop;
      _isOpen = widget.shop.isOpen;
    }
  }

  Future<void> _toggleStatus(bool value) async {
    final previous = _isOpen;
    setState(() {
      _isOpen = value;
      _togglingStatus = true;
    });
    try {
      await ApiClient.instance.patch(
        '/shops/${_shop.id}/status',
        body: {'is_open': value},
      );
      widget.onChanged();
    } on ApiException catch (e) {
      if (mounted) setState(() => _isOpen = previous);
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => _togglingStatus = false);
    }
  }

  Future<void> _openEditForm() async {
    final updated = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _ShopFormSheet(existingShop: _shop),
    );
    if (updated == true) widget.onChanged();
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 5,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(AppSpacing.sm, AppSpacing.xs, AppSpacing.sm, 0),
            child: Row(
              children: [
                TextButton.icon(
                  onPressed: _openEditForm,
                  icon: const Icon(Icons.edit_outlined, size: 18),
                  label: const Text('Edit details'),
                ),
                const Spacer(),
                TextButton.icon(
                  onPressed: () => Navigator.pushNamed(
                    context,
                    AppRoutes.submitAd,
                    arguments: SubmitAdArgs(shopId: _shop.id, shopName: _shop.name),
                  ),
                  icon: const Icon(Icons.campaign_outlined, size: 18),
                  label: const Text('Promote'),
                ),
              ],
            ),
          ),
          const TabBar(
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            tabs: [
              Tab(text: 'Overview'),
              Tab(text: 'Orders'),
              Tab(text: 'Products'),
              Tab(text: 'Alerts'),
              Tab(text: 'Analytics'),
            ],
          ),
          Expanded(
            child: TabBarView(
              children: [
                _OverviewTab(
                  shop: _shop,
                  isOpen: _isOpen,
                  toggling: _togglingStatus,
                  onToggleStatus: _toggleStatus,
                  onEditShop: _openEditForm,
                ),
                _OrdersTab(shopId: _shop.id),
                _ProductsTab(shopId: _shop.id),
                _AlertsTab(shopId: _shop.id),
                _AnalyticsTab(shopId: _shop.id),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Overview tab
// ---------------------------------------------------------------------------

/// The shop's top-level snapshot: open/closed status, quick stats, and a
/// preview of recent alerts. Reuses the same `/shops/{id}/alerts` endpoint
/// the Alerts tab already calls -- just to power this preview and count.
class _OverviewTab extends StatefulWidget {
  final Shop shop;
  final bool isOpen;
  final bool toggling;
  final ValueChanged<bool> onToggleStatus;
  final VoidCallback onEditShop;

  const _OverviewTab({
    required this.shop,
    required this.isOpen,
    required this.toggling,
    required this.onToggleStatus,
    required this.onEditShop,
  });

  @override
  State<_OverviewTab> createState() => _OverviewTabState();
}

class _OverviewTabState extends State<_OverviewTab> {
  ViewState<List<ShopAlert>> _state = const ViewLoading();

  /// What customers actually wrote. The rating average alone tells the owner
  /// that something is wrong but never what, so the text is the useful part.
  List<Map<String, dynamic>> _reviews = const [];

  Future<void> _loadReviews() async {
    try {
      final response =
          await ApiClient.instance.get('/shops/${widget.shop.id}/reviews');
      final rows = (response as List)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
      if (!mounted) return;
      setState(() => _reviews = rows);
    } catch (_) {
      // The alerts card is the primary content here; a failed review fetch
      // should not blank the whole tab.
    }
  }

  Future<void> _reply(Map<String, dynamic> review) async {
    final controller = TextEditingController(
      text: (review['owner_reply'] as String?) ?? '',
    );
    final text = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Reply to this review'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLines: 3,
          decoration: const InputDecoration(
            hintText: 'Thank you for your feedback',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('Send reply'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (text == null || text.isEmpty) return;
    try {
      await ApiClient.instance.post(
        '/shops/${widget.shop.id}/reviews/${review['id']}/reply',
        body: {'reply': text},
      );
      await _loadReviews();
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Reply sent')));
    } on ApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  @override
  void initState() {
    super.initState();
    _load();
    _loadReviews();
  }

  Future<void> _load() async {
    setState(() => _state = const ViewLoading());
    try {
      final response = await ApiClient.instance.get(
        '/shops/${widget.shop.id}/alerts',
      ) as List;
      final alerts = response
          .map((e) => ShopAlert.fromJson(e as Map<String, dynamic>))
          .toList();
      if (!mounted) return;
      setState(() => _state = ViewData(alerts));
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _state = ViewError(e.message));
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return RefreshIndicator(
      onRefresh: _load,
      child: AsyncStateView<List<ShopAlert>>(
        state: _state,
        onRetry: _load,
        loadingSkeleton: const SkeletonList(itemCount: 3, itemHeight: 90),
        builder: (context, alerts) {
          final recent = alerts.take(3).toList();
          return ListView(
            padding: const EdgeInsets.all(AppSpacing.lg),
            children: [
              _ShopStatusCard(
                isOpen: widget.isOpen,
                toggling: widget.toggling,
                onChanged: widget.onToggleStatus,
              ),
              const SizedBox(height: AppSpacing.lg),
              Row(
                children: [
                  Expanded(
                    child: _StatCard(
                      icon: Icons.star_rounded,
                      color: colorScheme.secondary,
                      valueWidget: RatingChip(
                        rating: widget.shop.ratingAvg,
                        count: widget.shop.ratingCount,
                      ),
                      label: 'Avg. rating',
                    ),
                  ),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: _StatCard(
                      icon: Icons.report_gmailerrorred_outlined,
                      color: colorScheme.error,
                      value: '${alerts.length}',
                      label: 'Open reports',
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.xl),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'Recent alerts',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  TextButton.icon(
                    onPressed: widget.onEditShop,
                    icon: const Icon(Icons.arrow_forward, size: 14),
                    label: const Text('Edit shop'),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.sm),
              if (recent.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: AppSpacing.lg),
                  child: Text(
                    'No alerts right now.',
                    style: TextStyle(color: context.appColors.textSecondary),
                  ),
                )
              else
                ...recent.map(
                  (alert) => Padding(
                    padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                    child: _AlertPreviewCard(alert: alert),
                  ),
                ),
              const SizedBox(height: AppSpacing.xl),
              Text(
                'Customer reviews',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: AppSpacing.sm),
              if (_reviews.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: AppSpacing.lg),
                  child: Text(
                    'No reviews yet.',
                    style: TextStyle(color: context.appColors.textSecondary),
                  ),
                )
              else
                ..._reviews.map(
                  (review) => Padding(
                    padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                    child: _ReviewCard(review: review, onReply: () => _reply(review)),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

/// The prominent tinted open/closed status card from the approved mockup.
class _ShopStatusCard extends StatelessWidget {
  final bool isOpen;
  final bool toggling;
  final ValueChanged<bool> onChanged;

  const _ShopStatusCard({
    required this.isOpen,
    required this.toggling,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final colors = context.appColors;
    final tint = isOpen
        ? colorScheme.primaryContainer
        : colorScheme.error.withValues(alpha: 0.12);
    final accent = isOpen ? colors.success : colorScheme.error;
    return Container(
      padding: const EdgeInsets.all(AppSpacing.lg),
      decoration: BoxDecoration(
        color: tint,
        borderRadius: BorderRadius.circular(AppRadius.card),
      ),
      child: Row(
        children: [
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(color: accent, shape: BoxShape.circle),
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  isOpen ? 'Shop is Open' : 'Shop is Closed',
                  style: Theme.of(context).textTheme.titleMedium
                      ?.copyWith(fontWeight: FontWeight.w700, color: accent),
                ),
                const SizedBox(height: 2),
                Text(
                  isOpen
                      ? 'Customers can see you on the map'
                      : 'Customers cannot find you right now',
                  style: Theme.of(context).textTheme.bodySmall
                      ?.copyWith(color: accent),
                ),
              ],
            ),
          ),
          Switch(value: isOpen, onChanged: toggling ? null : onChanged),
        ],
      ),
    );
  }
}

/// One "recent alert" row: a tinted icon box + message + relative timestamp.
class _AlertPreviewCard extends StatelessWidget {
  final ShopAlert alert;
  const _AlertPreviewCard({required this.alert});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final colors = context.appColors;
    return AppCard(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: colorScheme.secondaryContainer,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(
              Icons.campaign_outlined,
              size: 18,
              color: colors.warning,
            ),
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  alert.message,
                  style: Theme.of(context).textTheme.bodyMedium
                      ?.copyWith(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 3),
                Text(
                  _relativeTime(alert.createdAt),
                  style: Theme.of(context).textTheme.bodySmall
                      ?.copyWith(color: colors.textSecondary),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A short, human-friendly relative timestamp ("2h ago", "Yesterday"),
/// falling back to an absolute date for anything older than a week.
String _relativeTime(DateTime dateTime) {
  final diff = DateTime.now().difference(dateTime.toLocal());
  if (diff.inMinutes < 1) return 'Just now';
  if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
  if (diff.inHours < 24) return '${diff.inHours}h ago';
  if (diff.inDays == 1) return 'Yesterday';
  if (diff.inDays < 7) return '${diff.inDays}d ago';
  return _formatDate(dateTime);
}

// ---------------------------------------------------------------------------
// Products tab
// ---------------------------------------------------------------------------

class _ProductsTab extends StatefulWidget {
  final String shopId;
  const _ProductsTab({required this.shopId});

  @override
  State<_ProductsTab> createState() => _ProductsTabState();
}

class _ProductsTabState extends State<_ProductsTab> {
  ViewState<List<Product>> _state = const ViewLoading();
  String _filter = 'all';
  String _query = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _state = const ViewLoading());
    try {
      final response = await ApiClient.instance.get(
        '/shops/${widget.shopId}/products',
      ) as List;
      final products = response
          .map((e) => Product.fromJson(e as Map<String, dynamic>))
          .toList();
      if (!mounted) return;
      setState(() => _state = ViewData(products));
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _state = ViewError(e.message));
    }
  }

  Future<void> _openProductForm({Product? existing}) async {
    final changed = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (_) =>
          _ProductFormSheet(shopId: widget.shopId, existingProduct: existing),
    );
    if (changed == true) _load();
  }

  Future<void> _deleteProduct(Product product) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete product?'),
        content: Text('Remove "${product.name}" from this shop?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await ApiClient.instance.delete(
        '/shops/${widget.shopId}/products/${product.id}',
      );
      _load();
    } on ApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  /// Shows a hidden product to customers again.
  ///
  /// A product hidden because its last item sold has nothing in stock, and
  /// shop-service refuses to unhide an empty product, so the owner is asked
  /// how many they have now and the restock and unhide go in one request.
  Future<void> _unhide(Product product) async {
    final body = <String, dynamic>{'is_hidden': false};
    if (product.stockQuantity < AppConstants.minListableStock) {
      final quantity = await _askRestockQuantity(product);
      if (quantity == null) return;
      body['stock_quantity'] = quantity;
    }
    try {
      await ApiClient.instance.patch(
        '/shops/${widget.shopId}/products/${product.id}',
        body: body,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${product.name} is visible to customers again.')),
      );
      _load();
    } on ApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  /// Asks how many of [product] the owner has now. Null when cancelled.
  Future<int?> _askRestockQuantity(Product product) {
    return showDialog<int>(
      context: context,
      builder: (_) => _RestockDialog(productName: product.name),
    );
  }

  Future<void> _toggleAvailability(Product product, bool value) async {
    try {
      await ApiClient.instance.patch(
        '/shops/${widget.shopId}/products/${product.id}',
        body: {'is_available': value},
      );
      _load();
    } on ApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.lg,
            AppSpacing.md,
            AppSpacing.lg,
            0,
          ),
          child: Align(
            alignment: Alignment.centerRight,
            child: AppButton(
              label: 'Add Product',
              icon: Icons.add,
              expand: false,
              onPressed: () => _openProductForm(),
            ),
          ),
        ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: _load,
            child: AsyncStateView<List<Product>>(
              state: _state,
              onRetry: _load,
              isEmpty: (data) => data.isEmpty,
              emptyTitle: 'No products yet',
              emptyMessage: 'Add products so customers know what you sell.',
              emptyIcon: Icons.inventory_2_outlined,
              loadingSkeleton: const SkeletonList(itemCount: 4, itemHeight: 90),
              builder: (context, allProducts) {
                final products = filterOwnerProducts(
                  allProducts,
                  filter: _filter,
                  query: _query,
                );
                return Column(
                  children: [
                    ListFilterBar<String>(
                      searchHint: 'Search your products',
                      onSearchChanged: (value) => setState(() => _query = value),
                      options: ownerProductFilterOptions(allProducts),
                      selected: _filter,
                      onSelected: (value) => setState(() => _filter = value),
                    ),
                    if (products.isEmpty)
                      const Padding(
                        padding: EdgeInsets.all(AppSpacing.xl),
                        child: Text('No products match this filter.'),
                      ),
                    Expanded(
                      child: ListView.separated(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.lg,
                  AppSpacing.lg,
                  AppSpacing.lg,
                  AppSpacing.xxxl,
                ),
                itemCount: products.length,
                separatorBuilder: (_, _) =>
                    const SizedBox(height: AppSpacing.md),
                itemBuilder: (context, index) {
                  final product = products[index];
                  return AppCard(
                    onTap: () => _openProductForm(existing: product),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                product.name,
                                style: Theme.of(context).textTheme.titleMedium
                                    ?.copyWith(fontWeight: FontWeight.w600),
                              ),
                              const SizedBox(height: AppSpacing.xs),
                              Text(
                                '\$${product.price.toStringAsFixed(2)} · Stock: ${product.stockQuantity} · '
                                '${formatCategoryLabel(product.category)}',
                                style: Theme.of(context).textTheme.bodySmall
                                    ?.copyWith(
                                      color: context.appColors.textSecondary,
                                    ),
                              ),
                              if (product.hiddenLabel != null) ...[
                                const SizedBox(height: AppSpacing.xs),
                                StatusBadge(
                                  label: product.hiddenLabel!,
                                  background: context.appColors.warning
                                      .withValues(alpha: 0.14),
                                  foreground: context.appColors.warning,
                                ),
                              ],
                              if (product.isHidden) ...[
                                const SizedBox(height: AppSpacing.xs),
                                TextButton.icon(
                                  onPressed: () => _unhide(product),
                                  icon: const Icon(
                                    Icons.visibility_outlined,
                                    size: 18,
                                  ),
                                  label: const Text('Unhide'),
                                  style: TextButton.styleFrom(
                                    padding: EdgeInsets.zero,
                                    visualDensity: VisualDensity.compact,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                        Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Switch(
                              value: product.isAvailable,
                              onChanged: (value) =>
                                  _toggleAvailability(product, value),
                            ),
                            IconButton(
                              icon: const Icon(Icons.delete_outline),
                              onPressed: () => _deleteProduct(product),
                            ),
                          ],
                        ),
                      ],
                    ),
                  );
                },
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ],
    );
  }
}

/// Asks a shop owner how many of a sold-out product they have now, so it can
/// be restocked and unhidden in one step. Pops the quantity, or null.
class _RestockDialog extends StatefulWidget {
  final String productName;
  const _RestockDialog({required this.productName});

  @override
  State<_RestockDialog> createState() => _RestockDialogState();
}

class _RestockDialogState extends State<_RestockDialog> {
  final _controller = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    if (_formKey.currentState?.validate() != true) return;
    Navigator.pop(context, int.parse(_controller.text.trim()));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Restock ${widget.productName}'),
      content: Form(
        key: _formKey,
        child: TextFormField(
          controller: _controller,
          autofocus: true,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            labelText: 'How many do you have now?',
          ),
          validator: (value) {
            final parsed = int.tryParse(value?.trim() ?? '');
            if (parsed == null || parsed < AppConstants.minListableStock) {
              return 'Enter at least ${AppConstants.minListableStock}';
            }
            return null;
          },
          onFieldSubmitted: (_) => _submit(),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _submit,
          child: const Text('Restock & Unhide'),
        ),
      ],
    );
  }
}

/// Create/edit form for a product, shown as a scrollable bottom sheet.
class _ProductFormSheet extends StatefulWidget {
  final String shopId;
  final Product? existingProduct;
  const _ProductFormSheet({required this.shopId, this.existingProduct});

  @override
  State<_ProductFormSheet> createState() => _ProductFormSheetState();
}

class _ProductFormSheetState extends State<_ProductFormSheet> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameController;
  late final TextEditingController _descController;
  late final TextEditingController _priceController;
  late final TextEditingController _stockController;
  late final TextEditingController _categoryController;
  late bool _isAvailable;
  late int _discountPercent;
  PickedFile? _pickedImage;
  bool _isSubmitting = false;

  @override
  void initState() {
    super.initState();
    final existing = widget.existingProduct;
    _nameController = TextEditingController(text: existing?.name ?? '');
    _descController = TextEditingController(text: existing?.description ?? '');
    _priceController = TextEditingController(
      text: existing != null ? existing.price.toString() : '',
    );
    _stockController = TextEditingController(
      text: existing != null ? existing.stockQuantity.toString() : '',
    );
    _categoryController = TextEditingController(text: existing?.category ?? '');
    _isAvailable = existing?.isAvailable ?? true;
    _discountPercent = existing?.discountPercent ?? 0;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _descController.dispose();
    _priceController.dispose();
    _stockController.dispose();
    _categoryController.dispose();
    super.dispose();
  }

  String? _validateStock(String? value) {
    if (value == null || value.trim().isEmpty) {
      return 'Stock quantity is required';
    }
    final parsed = int.tryParse(value.trim());
    if (parsed == null || parsed < 0) return 'Enter a valid stock quantity';
    // Only on create: an owner editing a product must be able to record what
    // is really on the shelf, even when that hides it from customers.
    if (widget.existingProduct == null &&
        parsed < AppConstants.minListableStock) {
      return 'A new product needs at least '
          '${AppConstants.minListableStock} in stock';
    }
    return null;
  }

  Future<void> _submit() async {
    final formState = _formKey.currentState;
    if (formState == null || !formState.validate()) return;

    setState(() => _isSubmitting = true);
    final isEdit = widget.existingProduct != null;
    final body = <String, dynamic>{
      'name': _nameController.text.trim(),
      'description': _descController.text.trim(),
      'price': double.parse(_priceController.text.trim()),
      'stock_quantity': int.parse(_stockController.text.trim()),
      'category': _categoryController.text.trim(),
      'discount_percent': _discountPercent,
      if (isEdit) 'is_available': _isAvailable,
    };
    try {
      String productId;
      if (isEdit) {
        await ApiClient.instance.patch(
          '/shops/${widget.shopId}/products/${widget.existingProduct!.id}',
          body: body,
        );
        productId = widget.existingProduct!.id;
      } else {
        final created = await ApiClient.instance.post(
          '/shops/${widget.shopId}/products',
          body: body,
        );
        productId = (created as Map)['id'] as String;
      }

      // Separate call: the product must exist before it can own an image,
      // and a failed upload must not discard the details just typed.
      if (_pickedImage != null) {
        await MultipartUpload.send(
          path: '/shops/${widget.shopId}/products/$productId/image',
          file: _pickedImage!,
        );
      }
      if (!mounted) return;
      Navigator.pop(context, true);
    } on ApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isEdit = widget.existingProduct != null;
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.xl),
          child: Form(
            key: _formKey,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    isEdit ? 'Edit Product' : 'Add Product',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: AppSpacing.lg),
                  const RequiredFieldsNote(),
                  AppTextField(
                    controller: _nameController,
                    label: 'Product name',
                    isRequired: true,
                    validator: (v) =>
                        Validators.required(v, field: 'Product name'),
                  ),
                  const SizedBox(height: AppSpacing.md),
                  AppTextField(
                    controller: _descController,
                    label: 'Description',
                    isRequired: true,
                    maxLines: 3,
                    validator: (v) =>
                        Validators.required(v, field: 'Description'),
                  ),
                  const SizedBox(height: AppSpacing.md),
                  AppTextField(
                    controller: _priceController,
                    label: 'Price',
                    isRequired: true,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    validator: (v) =>
                        Validators.positiveNumber(v, field: 'Price'),
                  ),
                  const SizedBox(height: AppSpacing.md),
                  AppTextField(
                    controller: _stockController,
                    label: 'Stock quantity',
                    isRequired: true,
                    keyboardType: TextInputType.number,
                    helperText:
                        'Customers can order down to the last item. When '
                        'the last one sells, the product is hidden until '
                        'you unhide it.',
                    validator: _validateStock,
                  ),
                  const SizedBox(height: AppSpacing.md),
                  // Predefined categories plus "Others"; writes the chosen
                  // value into _categoryController, which _submit sends.
                  ProductCategoryField(controller: _categoryController),
                  const SizedBox(height: AppSpacing.md),
                  _ProductPhotoPicker(
                    picked: _pickedImage,
                    existingUrl: mediaUrl(widget.existingProduct?.imageUrl),
                    onPick: () async {
                      try {
                        final file = await MultipartUpload.pick();
                        if (file != null) setState(() => _pickedImage = file);
                      } on ApiException catch (e) {
                        if (!context.mounted) return;
                        ScaffoldMessenger.of(context)
                            .showSnackBar(SnackBar(content: Text(e.message)));
                      }
                    },
                  ),
                  const SizedBox(height: AppSpacing.md),
                  _DiscountSlider(
                    percent: _discountPercent,
                    price: double.tryParse(_priceController.text.trim()) ?? 0,
                    onChanged: (value) => setState(() => _discountPercent = value),
                  ),
                  if (isEdit) ...[
                    const SizedBox(height: AppSpacing.md),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      value: _isAvailable,
                      onChanged: (value) =>
                          setState(() => _isAvailable = value),
                      title: const Text('Available'),
                    ),
                  ],
                  const SizedBox(height: AppSpacing.xl),
                  AppButton(
                    label: isEdit ? 'Save Changes' : 'Add Product',
                    isLoading: _isSubmitting,
                    requiresConnection: true,
                    onPressed: _isSubmitting ? null : _submit,
                  ),
                  const SizedBox(height: AppSpacing.lg),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Alerts tab
// ---------------------------------------------------------------------------

class _AlertsTab extends StatefulWidget {
  final String shopId;
  const _AlertsTab({required this.shopId});

  @override
  State<_AlertsTab> createState() => _AlertsTabState();
}

class _AlertsTabState extends State<_AlertsTab> {
  ViewState<List<ShopAlert>> _state = const ViewLoading();
  final _messageController = TextEditingController();
  bool _posting = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _messageController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _state = const ViewLoading());
    try {
      final response = await ApiClient.instance.get(
        '/shops/${widget.shopId}/alerts',
      ) as List;
      final alerts = response
          .map((e) => ShopAlert.fromJson(e as Map<String, dynamic>))
          .toList();
      if (!mounted) return;
      setState(() => _state = ViewData(alerts));
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _state = ViewError(e.message));
    }
  }

  Future<void> _postAlert() async {
    final message = _messageController.text.trim();
    if (message.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter a message for the alert.')),
      );
      return;
    }
    setState(() => _posting = true);
    try {
      await ApiClient.instance.post(
        '/shops/${widget.shopId}/alerts',
        body: {'message': message},
      );
      _messageController.clear();
      if (!mounted) return;
      await _load();
    } on ApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => _posting = false);
    }
  }

  Future<void> _deleteAlert(ShopAlert alert) async {
    try {
      await ApiClient.instance.delete(
        '/shops/${widget.shopId}/alerts/${alert.id}',
      );
      _load();
    } on ApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: AppTextField(
                  controller: _messageController,
                  label: 'New alert message',
                  maxLines: 2,
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              IconButton.filled(
                onPressed: _posting ? null : _postAlert,
                icon: _posting
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.send),
              ),
            ],
          ),
        ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: _load,
            child: AsyncStateView<List<ShopAlert>>(
              state: _state,
              onRetry: _load,
              isEmpty: (data) => data.isEmpty,
              emptyTitle: 'No active alerts',
              emptyMessage:
                  'Post an alert to let customers know about changes.',
              emptyIcon: Icons.campaign_outlined,
              loadingSkeleton: const SkeletonList(itemCount: 3, itemHeight: 64),
              builder: (context, alerts) => ListView.separated(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.lg,
                  0,
                  AppSpacing.lg,
                  AppSpacing.xxxl,
                ),
                itemCount: alerts.length,
                separatorBuilder: (_, _) =>
                    const SizedBox(height: AppSpacing.md),
                itemBuilder: (context, index) {
                  final alert = alerts[index];
                  return AppCard(
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(alert.message),
                              const SizedBox(height: AppSpacing.xs),
                              Text(
                                _formatDate(alert.createdAt),
                                style: Theme.of(context).textTheme.bodySmall
                                    ?.copyWith(
                                      color: context.appColors.textSecondary,
                                    ),
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.delete_outline),
                          onPressed: () => _deleteAlert(alert),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Analytics tab
// ---------------------------------------------------------------------------

class _DailyViews {
  final DateTime date;
  final int views;
  const _DailyViews({required this.date, required this.views});

  factory _DailyViews.fromJson(Map<String, dynamic> json) {
    return _DailyViews(
      date: DateTime.parse(json['date'] as String),
      views: (json['views'] as num?)?.toInt() ?? 0,
    );
  }
}

class _ShopAnalytics {
  final int totalViews;
  final int totalSearchImpressions;
  final int productCount;
  final int activeAlertCount;
  final List<_DailyViews> viewsLast7Days;

  const _ShopAnalytics({
    required this.totalViews,
    required this.totalSearchImpressions,
    required this.productCount,
    required this.activeAlertCount,
    required this.viewsLast7Days,
  });

  factory _ShopAnalytics.fromJson(Map<String, dynamic> json) {
    final rawDays = json['views_last_7_days'] as List? ?? const [];
    return _ShopAnalytics(
      totalViews: (json['total_views'] as num?)?.toInt() ?? 0,
      totalSearchImpressions:
          (json['total_search_impressions'] as num?)?.toInt() ?? 0,
      productCount: (json['product_count'] as num?)?.toInt() ?? 0,
      activeAlertCount: (json['active_alert_count'] as num?)?.toInt() ?? 0,
      viewsLast7Days: rawDays
          .map((e) => _DailyViews.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }
}

class _AnalyticsTab extends StatefulWidget {
  final String shopId;
  const _AnalyticsTab({required this.shopId});

  @override
  State<_AnalyticsTab> createState() => _AnalyticsTabState();
}

class _AnalyticsTabState extends State<_AnalyticsTab> {
  ViewState<_ShopAnalytics> _state = const ViewLoading();

  /// Bumped on every pull-to-refresh so "Performance over time" reloads too.
  int _reloads = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _state = const ViewLoading();
      _reloads++;
    });
    try {
      final response = await ApiClient.instance.get(
        '/shops/${widget.shopId}/analytics',
      ) as Map<String, dynamic>;
      if (!mounted) return;
      setState(() => _state = ViewData(_ShopAnalytics.fromJson(response)));
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _state = ViewError(e.message));
    }
  }

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: _load,
      child: AsyncStateView<_ShopAnalytics>(
        state: _state,
        onRetry: _load,
        loadingSkeleton: const SkeletonList(itemCount: 4, itemHeight: 80),
        builder: (context, analytics) => ListView(
          padding: const EdgeInsets.all(AppSpacing.lg),
          children: [
            GridView.count(
              crossAxisCount: 2,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              mainAxisSpacing: AppSpacing.md,
              crossAxisSpacing: AppSpacing.md,
              childAspectRatio: 1.6,
              children: [
                _StatCard(
                  label: 'Total Views',
                  value: '${analytics.totalViews}',
                  icon: Icons.visibility_outlined,
                ),
                _StatCard(
                  label: 'Search Impressions',
                  value: '${analytics.totalSearchImpressions}',
                  icon: Icons.search,
                ),
                _StatCard(
                  label: 'Products',
                  value: '${analytics.productCount}',
                  icon: Icons.inventory_2_outlined,
                ),
                _StatCard(
                  label: 'Active Alerts',
                  value: '${analytics.activeAlertCount}',
                  icon: Icons.campaign_outlined,
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.xl),
            Text(
              'Views — Last 7 Days',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: AppSpacing.lg),
            AppCard(
              child: analytics.viewsLast7Days.isEmpty
                  ? Text(
                      'No view data yet.',
                      style: TextStyle(color: context.appColors.textSecondary),
                    )
                  : _ViewsBarChart(data: analytics.viewsLast7Days),
            ),
            const SizedBox(height: AppSpacing.xl),
            ShopPerformanceSection(
              key: ValueKey('performance-$_reloads'),
              shopId: widget.shopId,
            ),
          ],
        ),
      ),
    );
  }
}

class _StatCard extends StatelessWidget {
  final String label;
  final String? value;
  final Widget? valueWidget;
  final IconData icon;
  final Color? color;

  const _StatCard({
    required this.label,
    this.value,
    this.valueWidget,
    required this.icon,
    this.color,
  }) : assert(
         value != null || valueWidget != null,
         'Provide either value or valueWidget',
       );

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, color: color ?? colorScheme.primary),
          const SizedBox(height: AppSpacing.sm),
          valueWidget ??
              Text(
                value!,
                style: Theme.of(context).textTheme.headlineSmall
                    ?.copyWith(fontWeight: FontWeight.w700),
              ),
          Text(
            label,
            style: Theme.of(context).textTheme.bodySmall
                ?.copyWith(color: context.appColors.textSecondary),
          ),
        ],
      ),
    );
  }
}

class _ViewsBarChart extends StatelessWidget {
  final List<_DailyViews> data;
  const _ViewsBarChart({required this.data});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final colors = context.appColors;
    final maxViews = data
        .map((d) => d.views)
        .fold<int>(0, (a, b) => a > b ? a : b);
    const chartHeight = 120.0;
    return SizedBox(
      height: chartHeight + 44,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: data.map((day) {
          final fraction = maxViews == 0 ? 0.0 : day.views / maxViews;
          final barHeight = (fraction * chartHeight)
              .clamp(4.0, chartHeight)
              .toDouble();
          return Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  Text(
                    '${day.views}',
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  Container(
                    height: barHeight,
                    decoration: BoxDecoration(
                      color: colorScheme.primary,
                      borderRadius: const BorderRadius.vertical(
                        top: Radius.circular(6),
                      ),
                    ),
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    _shortWeekday(day.date),
                    style: Theme.of(context).textTheme.labelSmall
                        ?.copyWith(color: colors.textSecondary),
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


/// Product photo picker for the owner's product form. One photo per product:
/// on a phone listing the thumbnail is what sells the item, and asking a
/// one-room shop owner to curate a gallery is friction they will not accept.
class _ProductPhotoPicker extends StatelessWidget {
  final PickedFile? picked;
  final String? existingUrl;
  final VoidCallback onPick;

  const _ProductPhotoPicker({
    required this.picked,
    required this.existingUrl,
    required this.onPick,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final hasImage = picked != null || existingUrl != null;

    return Row(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(AppRadius.input),
          child: SizedBox(
            width: 68,
            height: 68,
            child: picked != null
                ? Image.memory(picked!.bytes, fit: BoxFit.cover)
                : existingUrl != null
                    ? Image.network(
                        existingUrl!,
                        fit: BoxFit.cover,
                        errorBuilder: (_, _, _) => ColoredBox(
                          color: colorScheme.surfaceContainerHighest,
                          child: const Icon(Icons.broken_image_outlined),
                        ),
                      )
                    : ColoredBox(
                        color: colorScheme.surfaceContainerHighest,
                        child: Icon(
                          Icons.image_outlined,
                          color: context.appColors.textSecondary,
                        ),
                      ),
          ),
        ),
        const SizedBox(width: AppSpacing.md),
        Expanded(
          child: OutlinedButton.icon(
            onPressed: onPick,
            icon: const Icon(Icons.photo_camera_outlined, size: 18),
            label: Text(hasImage ? 'Change photo' : 'Add photo'),
          ),
        ),
      ],
    );
  }
}

/// Discount control, showing the resulting price as the owner drags so they
/// can see what the customer will actually pay before saving.
class _DiscountSlider extends StatelessWidget {
  final int percent;
  final double price;
  final ValueChanged<int> onChanged;

  const _DiscountSlider({
    required this.percent,
    required this.price,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.appColors;
    final finalPrice = price * (100 - percent) / 100;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('Discount', style: Theme.of(context).textTheme.labelLarge),
            const Spacer(),
            if (percent > 0)
              Text(
                'Rs. ${price.toStringAsFixed(2)} to Rs. ${finalPrice.toStringAsFixed(2)}',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: colors.success,
                      fontWeight: FontWeight.w700,
                    ),
              )
            else
              Text(
                'No discount',
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: colors.textSecondary),
              ),
          ],
        ),
        Slider(
          value: percent.toDouble(),
          // Capped at 90 to match shop-service: a 100% discount is a
          // giveaway, and a number that high is nearly always a typo.
          max: 90,
          divisions: 18,
          label: '$percent%',
          onChanged: (value) => onChanged(value.round()),
        ),
      ],
    );
  }
}


/// One customer review: the stars, what they wrote, and the owner's reply.
class _ReviewCard extends StatelessWidget {
  final Map<String, dynamic> review;
  final VoidCallback onReply;

  const _ReviewCard({required this.review, required this.onReply});

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final colors = context.appColors;
    final rating = (review['rating'] as num?)?.toInt() ?? 0;
    final comment = (review['comment'] as String?)?.trim() ?? '';
    final reply = (review['owner_reply'] as String?)?.trim() ?? '';

    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              for (var i = 1; i <= 5; i++)
                Icon(
                  i <= rating ? Icons.star_rounded : Icons.star_border_rounded,
                  size: 18,
                  color: Colors.amber,
                ),
              const Spacer(),
              TextButton(
                onPressed: onReply,
                child: Text(reply.isEmpty ? 'Reply' : 'Edit reply'),
              ),
            ],
          ),
          Text(
            comment.isEmpty ? 'No comment left with this rating.' : comment,
            style: comment.isEmpty
                ? textTheme.bodySmall?.copyWith(
                    color: colors.textSecondary, fontStyle: FontStyle.italic)
                : textTheme.bodyMedium,
          ),
          if (reply.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.sm),
            Container(
              padding: const EdgeInsets.all(AppSpacing.sm),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(AppRadius.input),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.reply_rounded, size: 16, color: colors.textSecondary),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: Text(reply, style: textTheme.bodySmall),
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


// ---------------------------------------------------------------------------
// Orders tab
// ---------------------------------------------------------------------------

/// The shop's orders, and -- the reason this tab exists -- the pickup code.
///
/// The delivery agent has to read that code off the shop owner's screen
/// before they can collect a parcel. Without this tab the owner had nowhere
/// to look, so every pickup attempt failed with "that code does not match".
class _OrdersTab extends StatefulWidget {
  final String shopId;

  const _OrdersTab({required this.shopId});

  @override
  State<_OrdersTab> createState() => _OrdersTabState();
}

class _OrdersTabState extends State<_OrdersTab> {
  String _group = 'all';
  String _query = '';
  ViewState<List<DeliveryOrder>> _state = const ViewLoading();
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    _load();
    // An agent can arrive at any moment, so the list keeps itself current
    // rather than relying on the owner to pull to refresh.
    _poll = Timer.periodic(const Duration(seconds: 15), (_) => _load(quiet: true));
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _load({bool quiet = false}) async {
    if (!quiet) setState(() => _state = const ViewLoading());
    try {
      final response =
          await ApiClient.instance.get('/delivery/orders/shop/${widget.shopId}');
      final orders = (response as List)
          .map((e) => DeliveryOrder.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList();
      if (!mounted) return;
      setState(() => _state = ViewData(orders));
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _state = ViewError(e.message));
    } catch (_) {
      if (!mounted) return;
      setState(() => _state = const ViewError('Could not load your orders.'));
    }
  }

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: _load,
      child: AsyncStateView<List<DeliveryOrder>>(
        state: _state,
        onRetry: _load,
        isEmpty: (data) => data.isEmpty,
        emptyTitle: 'No orders yet',
        emptyMessage: 'Orders customers place from your shop appear here.',
        loadingSkeleton: const SkeletonList(itemCount: 3),
        builder: (context, orders) {
          // Orders an agent is on the way for come first; the owner is
          // usually opening this tab because someone is at the counter.
          final sorted = [
            ...filterOrders(orders, group: _group, query: _query),
          ]..sort((a, b) {
              int rank(DeliveryOrder o) => o.status == 'accepted' ? 0 : 1;
              final byRank = rank(a).compareTo(rank(b));
              return byRank != 0 ? byRank : b.createdAt.compareTo(a.createdAt);
            });
          return Column(
            children: [
              ListFilterBar<String>(
                searchHint: 'Search order number, item or address',
                onSearchChanged: (value) => setState(() => _query = value),
                options: orderFilterOptions(orders),
                selected: _group,
                onSelected: (value) => setState(() => _group = value),
              ),
              if (sorted.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(AppSpacing.xl),
                  child: Text('No orders match this filter.'),
                ),
              Expanded(
                child: ListView.separated(
                  padding: const EdgeInsets.all(AppSpacing.lg),
                  itemCount: sorted.length,
                  separatorBuilder: (_, _) => const SizedBox(height: AppSpacing.md),
                  itemBuilder: (context, i) => StaggerIn(
                    index: i,
                    child: _ShopOrderCard(order: sorted[i], onChanged: _load),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _ShopOrderCard extends StatelessWidget {
  final DeliveryOrder order;
  final Future<void> Function() onChanged;

  const _ShopOrderCard({required this.order, required this.onChanged});

  /// Item 8: a shop that cannot fill an order says so, with a reason the
  /// customer is shown. Allowed while the order is pending or accepted,
  /// which is what the server allows too.
  Future<void> _cancel(BuildContext context) async {
    final reason = await showDialog<String>(
      context: context,
      builder: (dialogContext) => const _CancelReasonDialog(),
    );
    if (reason == null || !context.mounted) return;

    try {
      await ApiClient.instance.patch(
        '/delivery/orders/${order.id}/cancel',
        body: {'reason': reason},
      );
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Order cancelled. The customer has been told.')),
      );
      await onChanged();
    } on ApiException catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  /// The owner confirms the handover themselves, instead of the driver
  /// typing the code -- for when the driver's phone has no signal.
  Future<void> _confirmPickup(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Handed to the driver?'),
        content: Text(
          'Confirm only once the driver has order '
          '#${order.id.substring(0, 6).toUpperCase()} in their hands. '
          'This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Not yet'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Yes, handed over'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;

    try {
      await ApiClient.instance.post('/delivery/orders/${order.id}/confirm-pickup');
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Pickup confirmed. The order is on its way.')),
      );
      await onChanged();
    } on ApiException catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final colorScheme = Theme.of(context).colorScheme;
    final colors = context.appColors;
    final code = order.pickupCode;
    // Only while an agent is actually coming to collect it.
    final awaitingPickup = order.status == 'accepted' && code != null;

    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Order #${order.id.substring(0, 6).toUpperCase()}',
                  style: textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                ),
              ),
              _OrderStatusChip(status: order.status),
            ],
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            order.deliveryAddress,
            style: textTheme.bodySmall?.copyWith(color: colors.textSecondary),
          ),
          Text(
            'Rs. ${order.totalAmount.toStringAsFixed(2)}',
            style: textTheme.bodySmall?.copyWith(color: colors.textSecondary),
          ),
          if (awaitingPickup) ...[
            const SizedBox(height: AppSpacing.md),
            Container(
              padding: const EdgeInsets.all(AppSpacing.md),
              decoration: BoxDecoration(
                color: colorScheme.primaryContainer,
                borderRadius: BorderRadius.circular(AppRadius.input),
              ),
              child: Row(
                children: [
                  Icon(Icons.pin_rounded, color: colorScheme.primary),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Pickup code',
                          style: textTheme.labelMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                            color: colorScheme.onPrimaryContainer,
                          ),
                        ),
                        Text(
                          'Read this out to the delivery agent.',
                          style: textTheme.labelSmall
                              ?.copyWith(color: colorScheme.onPrimaryContainer),
                        ),
                      ],
                    ),
                  ),
                  Text(
                    code,
                    style: textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                      letterSpacing: 4,
                      color: colorScheme.primary,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            // The other way to confirm the pickup: it needs this phone to be
            // online, not the driver's.
            FilledButton.icon(
              onPressed: () => _confirmPickup(context),
              icon: const Icon(Icons.handshake_outlined, size: 18),
              label: const Text('Handed to driver'),
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(44)),
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              'Driver has no signal? Tap this once the order is in their hands.',
              style: textTheme.labelSmall?.copyWith(color: colors.textSecondary),
            ),
          ],
          if (order.status == 'pending' || order.status == 'accepted') ...[
            const SizedBox(height: AppSpacing.sm),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: () => _cancel(context),
                icon: const Icon(Icons.cancel_outlined, size: 18),
                label: const Text('Cancel with reason'),
                style: TextButton.styleFrom(foregroundColor: colorScheme.error),
              ),
            ),
          ],
          if (order.cancellationNote != null) ...[
            const SizedBox(height: AppSpacing.sm),
            Text(
              order.cancellationNote!,
              style: textTheme.bodySmall?.copyWith(color: colorScheme.error),
            ),
          ],
        ],
      ),
    );
  }
}


/// Item 6: "waiting for verification", shown on the owner's own dashboard.
///
/// Customers see a "Not verified" chip on an unverified shop, so the owner
/// is told the same thing from their side, and what it means for them.
class _AwaitingVerificationBanner extends StatelessWidget {
  final Shop shop;

  const _AwaitingVerificationBanner({required this.shop});

  @override
  Widget build(BuildContext context) {
    final colors = context.appColors;
    final ready = shop.hasEnoughProductsToVerify;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: colors.warning.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: colors.warning.withValues(alpha: 0.4)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.hourglass_top_rounded, size: 20, color: colors.warning),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Waiting for admin verification',
                  style: Theme.of(context)
                      .textTheme
                      .bodyMedium
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 2),
                Text(
                  'Customers see a "Not verified" note on your shop until an '
                  'admin approves it.',
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: colors.textSecondary),
                ),
                const SizedBox(height: AppSpacing.sm),
                // Item 10: what is actually missing, rather than "wait".
                Row(
                  children: [
                    Icon(
                      ready ? Icons.check_circle_outline : Icons.inventory_2_outlined,
                      size: 16,
                      color: ready ? colors.success : colors.warning,
                    ),
                    const SizedBox(width: AppSpacing.xs),
                    Expanded(
                      child: Text(
                        ready
                            ? '${shop.productProgressLabel} — ready for review.'
                            : '${shop.productProgressLabel}. A shop needs '
                                '${AppConstants.minProductsToVerify} products in '
                                'stock that customers can see.',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              fontWeight: FontWeight.w600,
                              color: ready ? colors.success : colors.warning,
                            ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}


/// Asks the owner why, because the customer is shown the answer.
class _CancelReasonDialog extends StatefulWidget {
  const _CancelReasonDialog();

  @override
  State<_CancelReasonDialog> createState() => _CancelReasonDialogState();
}

class _CancelReasonDialogState extends State<_CancelReasonDialog> {
  final _controller = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Cancel this order?'),
      content: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'The customer and the delivery agent are told, with your reason. '
              'Cancelling too often is reviewed by an administrator.',
            ),
            const SizedBox(height: AppSpacing.md),
            AppTextField(
              controller: _controller,
              label: 'Reason',
              isRequired: true,
              maxLines: 2,
              validator: (value) =>
                  Validators.required(value, field: 'Reason'),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Keep order'),
        ),
        FilledButton(
          onPressed: () {
            if (_formKey.currentState?.validate() != true) return;
            Navigator.pop(context, _controller.text.trim());
          },
          child: const Text('Cancel order'),
        ),
      ],
    );
  }
}


/// A small coloured chip for an order's current state.
class _OrderStatusChip extends StatelessWidget {
  final String status;

  const _OrderStatusChip({required this.status});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (background, foreground) = switch (status) {
      'delivered' => (Colors.green.withValues(alpha: 0.15), Colors.green),
      'cancelled' => (scheme.errorContainer, scheme.onErrorContainer),
      'accepted' => (scheme.primaryContainer, scheme.onPrimaryContainer),
      _ => (scheme.surfaceContainerHighest, scheme.onSurfaceVariant),
    };
    return StatusBadge(
      label: formatOrderStatusLabel(status),
      background: background,
      foreground: foreground,
    );
  }
}
