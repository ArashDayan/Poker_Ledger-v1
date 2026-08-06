import 'package:flutter/foundation.dart';

import '../license/license_model.dart';
import '../license/license_service.dart';

/// Exposes licensing state to the widget tree.
///
/// Kept deliberately thin — all policy lives in [LicenseService]. This
/// only holds the current snapshot and notifies listeners, matching how
/// SettingsProvider and SessionProvider are structured so the licensing
/// layer does not introduce a second, unfamiliar pattern.
class LicenseProvider extends ChangeNotifier {
  LicenseStatus _status = const LicenseStatus.inactive();
  bool _busy = false;
  LicenseError? _lastError;

  LicenseProvider({bool autoLoad = true}) {
    if (autoLoad) refresh();
  }

  LicenseStatus get status => _status;
  bool get isActive => _status.isActive;
  bool get busy => _busy;
  LicenseError? get lastError => _lastError;

  /// Re-derives status from the signed blob on disk.
  void refresh() {
    _status = LicenseService.currentStatus();
    notifyListeners();
  }

  Future<bool> activate(String key) async {
    _busy = true;
    _lastError = null;
    notifyListeners();

    final result = await LicenseService.activate(key);

    if (result.success) {
      _status = LicenseService.currentStatus();
      _lastError = null;
    } else {
      _lastError = result.error;
    }
    _busy = false;
    notifyListeners();
    return result.success;
  }

  Future<void> deactivate() async {
    await LicenseService.deactivate();
    _status = const LicenseStatus.inactive();
    _lastError = null;
    notifyListeners();
  }

  void clearError() {
    if (_lastError == null) return;
    _lastError = null;
    notifyListeners();
  }
}
