import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';

/// One Hive box subscription that can fail independently and be retried.
///
/// SessionProvider used to attach every box in a single try/catch. If
/// `HiveService.players` threw (box not open yet, or a late-opened box),
/// *none* of the seating/transaction watchers attached. The UI then
/// stayed stale until something else called `notifyListeners` (reopening
/// the session, switching tabs that setState on return). After the
/// banker had used the app for a while, boxes were open and a later
/// provider construction — or a path that notified explicitly — looked
/// "fixed by itself".
///
/// Each box is attached on its own. A missing financial box cannot drop
/// the players watcher. Failed names stay listed so [retryFailed] can
/// recover without polling.
class BoxWatchHub {
  final void Function() onEvent;
  final List<StreamSubscription<BoxEvent>> _subs = [];
  final Set<String> _attached = {};
  final Set<String> _failed = {};
  final Map<String, Object?> _lastError = {};
  bool _disposed = false;

  BoxWatchHub({required this.onEvent});

  bool get isDisposed => _disposed;
  int get attachedCount => _attached.length;
  Set<String> get attachedNames => Set.unmodifiable(_attached);
  Set<String> get failedNames => Set.unmodifiable(_failed);
  Object? lastErrorFor(String name) => _lastError[name];
  bool get hasFailures => _failed.isNotEmpty;
  bool isAttached(String name) => _attached.contains(name);

  /// Opens [watch] and listens. Returns true when attached.
  bool attach(String name, Stream<BoxEvent> Function() watch) {
    if (_disposed) return false;
    if (_attached.contains(name)) return true;
    try {
      final stream = watch();
      _subs.add(stream.listen((_) {
        if (!_disposed) onEvent();
      }));
      _attached.add(name);
      _failed.remove(name);
      _lastError.remove(name);
      return true;
    } catch (e, st) {
      _failed.add(name);
      _lastError[name] = e;
      debugPrint('BoxWatchHub: failed to watch "$name": $e\n$st');
      return false;
    }
  }

  /// Re-attempts every name that previously failed.
  ///
  /// [retry] must call [attach] for each failed name. The hub does not
  /// store the watch factory so a late-opened box can be resolved by
  /// the caller at retry time.
  void retryFailed(void Function(String name) retry) {
    if (_disposed) return;
    final pending = List<String>.from(_failed);
    for (final name in pending) {
      retry(name);
    }
  }

  void dispose() {
    _disposed = true;
    for (final s in _subs) {
      s.cancel();
    }
    _subs.clear();
    _attached.clear();
    _failed.clear();
    _lastError.clear();
  }
}
