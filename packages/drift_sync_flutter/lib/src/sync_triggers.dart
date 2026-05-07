import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:internet_connection_checker_plus/internet_connection_checker_plus.dart';

/// Reason a [SyncTriggers] instance fired its `onTrigger` callback.
enum SyncTriggerEvent {
  /// Initial fire when [SyncTriggers.attach] runs.
  startup,

  /// The periodic interval timer ticked.
  periodic,

  /// The app returned to the foreground.
  resume,

  /// Internet connectivity was restored after being lost.
  connectivity,
}

/// Reason a [SyncTriggers] instance fired its `onPause` callback.
enum SyncPauseEvent {
  /// The app moved to the background, became inactive, was hidden, or detached.
  background,

  /// Internet connectivity was lost.
  offline,

  /// [SyncTriggers.detach] was called.
  detach,
}

/// A single trigger surface for sync: app lifecycle, connectivity, and a
/// periodic timer, behind one attach/detach pair.
///
/// Wire `onTrigger` to whatever should run on each event (typically
/// `synchronizer.sync()`). Wire `onPause` to whatever should be cancelled
/// when the app backgrounds, goes offline, or detaches.
///
/// The class deliberately exposes only four operations: constructor,
/// [attach], [detach], and [setInterval]. It is not a scheduler — it does
/// not retry, debounce, or back off. If you need that, do it in the
/// callback.
class SyncTriggers with WidgetsBindingObserver {
  SyncTriggers({
    required this.onTrigger,
    this.onPause,
    Duration? interval,
    this.bindConnectivity = true,
    this.fireOnAttach = true,
    InternetConnection? connectivity,
  })  : _interval = interval,
        _connectivity = connectivity ?? InternetConnection();

  /// Called on startup, periodic ticks, foreground resume, and
  /// connectivity restore.
  final void Function(SyncTriggerEvent event) onTrigger;

  /// Called when the app backgrounds, goes offline, or detaches.
  final void Function(SyncPauseEvent event)? onPause;

  /// If true, listens to [InternetConnection] and emits
  /// [SyncTriggerEvent.connectivity] / [SyncPauseEvent.offline].
  final bool bindConnectivity;

  /// If true, fires [SyncTriggerEvent.startup] from [attach].
  final bool fireOnAttach;

  Duration? _interval;
  Timer? _timer;
  StreamSubscription<InternetStatus>? _connSub;
  final InternetConnection _connectivity;
  bool _isOnline = true;
  bool _isForeground = true;
  bool _attached = false;

  /// Whether the periodic timer is allowed to run right now.
  bool get _canTick => _isOnline && _isForeground;

  /// Current periodic interval. `null` means the periodic timer is disabled.
  Duration? get interval => _interval;

  /// Whether [attach] has been called and [detach] has not.
  bool get isAttached => _attached;

  /// Updates the periodic interval. Pass `null` to disable the timer
  /// entirely (event-driven only). If currently attached, the timer is
  /// restarted with the new interval.
  void setInterval(Duration? value) {
    if (value == _interval) return;
    _interval = value;
    if (_attached) _restartTimer();
  }

  /// Starts observing lifecycle, connectivity, and the periodic timer.
  /// Idempotent — calling twice is a no-op.
  Future<void> attach() async {
    if (_attached) return;
    _attached = true;

    WidgetsBinding.instance.addObserver(this);
    if (bindConnectivity) {
      _connSub = _connectivity.onStatusChange.listen(_onConnectivityChanged);
    }
    _restartTimer();
    if (fireOnAttach) onTrigger(SyncTriggerEvent.startup);
  }

  /// Stops observing and cancels the timer. Idempotent.
  Future<void> detach() async {
    if (!_attached) return;
    _attached = false;

    WidgetsBinding.instance.removeObserver(this);
    await _connSub?.cancel();
    _connSub = null;
    _timer?.cancel();
    _timer = null;
    onPause?.call(SyncPauseEvent.detach);
  }

  void _restartTimer() {
    _timer?.cancel();
    _timer = null;
    final i = _interval;
    if (i == null || !_canTick) return;
    _timer = Timer.periodic(i, (_) => onTrigger(SyncTriggerEvent.periodic));
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final wasForeground = _isForeground;
    switch (state) {
      case AppLifecycleState.resumed:
        _isForeground = true;
        if (!wasForeground) {
          _restartTimer();
          if (_isOnline) onTrigger(SyncTriggerEvent.resume);
        }
      case AppLifecycleState.paused:
      case AppLifecycleState.inactive:
      case AppLifecycleState.detached:
      case AppLifecycleState.hidden:
        _isForeground = false;
        if (wasForeground) {
          _restartTimer();
          onPause?.call(SyncPauseEvent.background);
        }
    }
  }

  void _onConnectivityChanged(InternetStatus status) {
    final wasOnline = _isOnline;
    _isOnline = status == InternetStatus.connected;
    if (!wasOnline && _isOnline) {
      _restartTimer();
      onTrigger(SyncTriggerEvent.connectivity);
    } else if (wasOnline && !_isOnline) {
      _restartTimer();
      onPause?.call(SyncPauseEvent.offline);
    }
  }
}
