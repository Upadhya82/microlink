import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';

/// Whether the phone currently has a network connection (item 14).
///
/// Offline used to be inferred only after a request had already failed, so
/// every screen discovered it separately and a few minutes apart. This
/// watches the connection itself, so the app can say "you are offline"
/// before anyone taps something that cannot work.
///
/// Deliberately conservative: this reports whether a network is *attached*,
/// which is not the same as the internet being reachable. A captive portal
/// or a dead uplink still reads as online, and the request-level fallbacks
/// (the caches) remain the real safety net.
class ConnectivityController extends ChangeNotifier {
  ConnectivityController._();
  static final ConnectivityController instance = ConnectivityController._();

  final Connectivity _connectivity = Connectivity();
  StreamSubscription<List<ConnectivityResult>>? _subscription;

  bool _offline = false;
  bool _started = false;

  /// True when the phone has no network at all. Starts false: assuming
  /// offline before the first check would flash a banner on every launch.
  bool get isOffline => _offline;

  bool get isOnline => !_offline;

  /// Begin watching. Safe to call more than once.
  Future<void> start() async {
    if (_started) return;
    _started = true;
    await refresh();
    try {
      _subscription = _connectivity.onConnectivityChanged.listen(
        _apply,
        onError: (_) {
          // A platform that cannot report connectivity is treated as
          // online; the caches handle the rest.
          _set(false);
        },
      );
    } catch (_) {
      _set(false);
    }
  }

  /// Check once, for a pull-to-refresh or a retry button.
  Future<void> refresh() async {
    try {
      _apply(await _connectivity.checkConnectivity());
    } catch (_) {
      _set(false);
    }
  }

  void _apply(List<ConnectivityResult> results) {
    // An empty list, or nothing but `none`, means no network.
    final offline =
        results.isEmpty || results.every((r) => r == ConnectivityResult.none);
    _set(offline);
  }

  void _set(bool offline) {
    if (_offline == offline) return;
    _offline = offline;
    notifyListeners();
  }

  /// For tests: pretend the connection changed.
  @visibleForTesting
  void debugSetOffline(bool offline) => _set(offline);

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }
}
