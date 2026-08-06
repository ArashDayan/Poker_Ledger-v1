import 'package:flutter/foundation.dart';

import '../security/app_lock_service.dart';
import '../security/app_lock_settings.dart';

/// Owns "is the app currently locked?" and the auto-lock clock.
///
/// Independent of [LicenseProvider] by design: the two layers answer
/// different questions ("may this device run the app at all?" vs "is the
/// person holding the phone right now the owner?") and neither reads the
/// other's state.
class AppLockProvider extends ChangeNotifier {
  bool _enabled = false;
  AutoLockTimeout _timeout = AutoLockTimeout.immediately;

  /// Locked until the user authenticates. Starts locked when the feature
  /// is on, so the very first frame after launch is already protected.
  bool _locked = false;

  /// True while the OS prompt is on screen, so lifecycle changes caused
  /// by that prompt do not re-trigger a lock.
  bool _authenticating = false;

  AppLockFailure? _lastFailure;

  /// When the app went to the background. Null while foregrounded.
  DateTime? _backgroundedAt;

  AppLockProvider({bool autoLoad = true}) {
    if (autoLoad) load();
  }

  bool get isEnabled => _enabled;
  bool get isLocked => _enabled && _locked;
  bool get isAuthenticating => _authenticating;
  AutoLockTimeout get timeout => _timeout;
  AppLockFailure? get lastFailure => _lastFailure;

  void load() {
    _enabled = AppLockSettings.isEnabled;
    _timeout = AppLockSettings.timeout;
    // If the feature is on, the app begins locked — never the other way
    // round. Defaulting to unlocked would leave a window where the
    // ledger is visible before the prompt appears.
    _locked = _enabled;
    notifyListeners();
  }

  /// Turns App Lock on. Requires a successful authentication first, so a
  /// user cannot enable a lock they are then unable to pass — that would
  /// strand them outside their own ledger.
  Future<bool> enable() async {
    final result = await AppLockService.authenticate();
    if (!result.authenticated) {
      _lastFailure = result.failure;
      notifyListeners();
      return false;
    }
    _enabled = true;
    _locked = false;
    _lastFailure = null;
    await AppLockSettings.setEnabled(true);
    notifyListeners();
    return true;
  }

  /// Turns App Lock off. Also requires authentication: otherwise anyone
  /// holding an unlocked phone could simply switch the protection off.
  Future<bool> disable() async {
    final result = await AppLockService.authenticate();
    if (!result.authenticated) {
      _lastFailure = result.failure;
      notifyListeners();
      return false;
    }
    _enabled = false;
    _locked = false;
    _lastFailure = null;
    await AppLockSettings.setEnabled(false);
    notifyListeners();
    return true;
  }

  Future<void> setTimeout(AutoLockTimeout value) async {
    _timeout = value;
    await AppLockSettings.setTimeout(value);
    notifyListeners();
  }

  /// Runs the OS prompt to unlock. Called by the lock screen.
  Future<bool> unlock() async {
    if (_authenticating) return false;
    _authenticating = true;
    _lastFailure = null;
    notifyListeners();

    final result = await AppLockService.authenticate();

    _authenticating = false;
    if (result.authenticated) {
      _locked = false;
      _backgroundedAt = null;
      _lastFailure = null;
    } else {
      // Stay locked. The user can retry from the lock screen.
      _lastFailure = result.failure;
    }
    notifyListeners();
    return result.authenticated;
  }

  /// The app went to the background — remember when.
  void onPaused() {
    if (!_enabled || _authenticating) return;
    _backgroundedAt ??= DateTime.now();
  }

  /// The app came back. Re-lock if it was away longer than the timeout.
  void onResumed() {
    if (!_enabled || _authenticating) return;
    final since = _backgroundedAt;
    if (since == null) return;

    final away = DateTime.now().difference(since);
    if (_timeout == AutoLockTimeout.immediately || away >= _timeout.duration) {
      _locked = true;
      notifyListeners();
    }
    _backgroundedAt = null;
  }

  void clearFailure() {
    if (_lastFailure == null) return;
    _lastFailure = null;
    notifyListeners();
  }

  /// Test-only hook.
  @visibleForTesting
  void debugSet({bool? enabled, bool? locked, AutoLockTimeout? timeout}) {
    if (enabled != null) _enabled = enabled;
    if (locked != null) _locked = locked;
    if (timeout != null) _timeout = timeout;
    notifyListeners();
  }
}
