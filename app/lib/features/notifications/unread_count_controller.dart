import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../core/network/api_client.dart';
import '../../core/network/session_manager.dart';

/// Keeps the notification bell's unread badge up to date.
///
/// A single shared controller rather than per-widget timers: the bell appears
/// in more than one place (customer home app bar, account sheet), and polling
/// `/notifications/me/unread-count` once per widget would multiply the
/// requests for no benefit. Widgets listen; the controller owns the timer and
/// stops it whenever nothing is listening, nobody is logged in, or the app is
/// in the background.
class UnreadCountController extends ChangeNotifier with WidgetsBindingObserver {
  UnreadCountController._() {
    WidgetsBinding.instance.addObserver(this);
  }

  static final UnreadCountController instance = UnreadCountController._();

  static const Duration pollInterval = Duration(seconds: 30);

  int _unread = 0;
  Timer? _timer;
  bool _inFlight = false;

  int get unread => _unread;

  /// Called by the bell when it mounts. Fetches straight away, then polls.
  void start() {
    refresh();
    _timer ??= Timer.periodic(pollInterval, (_) => refresh());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Don't poll while backgrounded; refresh once on the way back so the
    // badge is right the moment the user sees it again.
    if (state == AppLifecycleState.resumed) {
      if (_timer != null) refresh();
    } else if (state == AppLifecycleState.paused) {
      stop();
    }
  }

  Future<void> refresh() async {
    if (_inFlight) return;
    if (!SessionManager.instance.isLoggedIn) {
      _set(0);
      return;
    }
    _inFlight = true;
    try {
      final response = await ApiClient.instance.get('/notifications/me/unread-count');
      final count = response is Map ? response['unread'] : null;
      _set(count is int ? count : 0);
    } catch (_) {
      // A badge is not worth surfacing an error for -- leave the last known
      // count and try again on the next tick.
    } finally {
      _inFlight = false;
    }
  }

  /// Lets a screen correct the badge immediately after marking rows read,
  /// instead of waiting up to [pollInterval] for the next poll.
  void setUnread(int value) => _set(value);

  void decrement() => _set(_unread - 1);

  void _set(int value) {
    final clamped = value < 0 ? 0 : value;
    if (clamped == _unread) return;
    _unread = clamped;
    notifyListeners();
  }
}
