import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';
import 'package:local_auth_android/local_auth_android.dart';
import 'package:local_auth_darwin/local_auth_darwin.dart';

import '../core/localization/app_localizations.dart';

/// Why an authentication attempt did not succeed.
///
/// Deliberately coarse: the OS never tells us *which* finger failed or
/// what the passcode was, and we do not want to know. These map to
/// messages that tell the banker what to do next.
enum AppLockFailure {
  /// The user cancelled, or the OS dismissed the prompt.
  cancelled,

  /// Fingerprint/face did not match, or the user gave up.
  failed,

  /// The device has no enrolled biometrics AND no device credential.
  notEnrolled,

  /// The hardware/OS cannot do this at all.
  unavailable,

  /// Too many attempts — the OS has temporarily locked authentication
  /// out. Only the OS can clear this.
  lockedOut,
}

/// Result of one authentication attempt.
class AppLockResult {
  final bool authenticated;
  final AppLockFailure? failure;

  const AppLockResult.success()
      : authenticated = true,
        failure = null;

  const AppLockResult.failure(AppLockFailure this.failure)
      : authenticated = false;
}

/// Thin wrapper over the OS authentication prompt.
///
/// PRIVACY — THE WHOLE POINT OF THIS CLASS
/// Poker Ledger never sees biometric data. It calls
/// `LocalAuthentication.authenticate()`, and the operating system does
/// everything else behind its own secure boundary: it shows the prompt,
/// reads the sensor, compares against the enrolment stored in the secure
/// enclave / TEE, and hands back a single boolean.
///
/// There is no API here — and none exists on either platform — to read a
/// fingerprint image, a face template, or the user's PIN/pattern/
/// password. This class stores nothing. The only thing that ever touches
/// disk is the user's *preference* (on/off, timeout), written by
/// [AppLockSettings].
///
/// Kept entirely separate from the license layer: neither knows the other
/// exists, so a lock problem can never affect activation and vice versa.
class AppLockService {
  AppLockService._();

  static final LocalAuthentication _auth = LocalAuthentication();

  /// True when the device can authenticate by *any* means — biometric or
  /// device credential (PIN/pattern/password).
  ///
  /// `isDeviceSupported()` covers the credential fallback, which
  /// `canCheckBiometrics` alone does not; a phone with a PIN but no
  /// fingerprint reader must still be able to use App Lock.
  static Future<bool> isSupported() async {
    try {
      return await _auth.isDeviceSupported();
    } on PlatformException {
      return false;
    } catch (_) {
      return false;
    }
  }

  /// True when the user has actually enrolled a biometric.
  ///
  /// Only used to describe the device in Settings. App Lock does not
  /// require it — device credential is a perfectly good second factor.
  static Future<bool> hasBiometricsEnrolled() async {
    try {
      if (!await _auth.canCheckBiometrics) return false;
      final available = await _auth.getAvailableBiometrics();
      return available.isNotEmpty;
    } on PlatformException {
      return false;
    } catch (_) {
      return false;
    }
  }

  /// Which biometric types the OS reports. Display only.
  static Future<List<BiometricType>> availableBiometrics() async {
    try {
      return await _auth.getAvailableBiometrics();
    } on PlatformException {
      return const [];
    } catch (_) {
      return const [];
    }
  }

  /// Asks the OS to authenticate the user.
  ///
  /// [biometricOnly] is deliberately false: allowing the device
  /// credential means a banker whose hands are wet, who is wearing
  /// gloves, or whose sensor has failed can still get into their own
  /// ledger mid-game. Locking them out of their own money records at the
  /// table would be worse than the marginal security gain.
  static Future<AppLockResult> authenticate({String? reason}) async {
    try {
      final ok = await _auth.authenticate(
        localizedReason: reason ?? tr('app_lock_reason'),
        authMessages: [
          AndroidAuthMessages(
            signInTitle: tr('app_lock_title'),
            biometricHint: '',
            biometricNotRecognized: tr('app_lock_not_recognized'),
            biometricRequiredTitle: tr('app_lock_required'),
            cancelButton: tr('cancel'),
            deviceCredentialsRequiredTitle: tr('app_lock_required'),
            deviceCredentialsSetupDescription: tr('app_lock_not_enrolled'),
            goToSettingsButton: tr('settings'),
            goToSettingsDescription: tr('app_lock_not_enrolled'),
          ),
          IOSAuthMessages(
            lockOut: tr('app_lock_locked_out'),
            cancelButton: tr('cancel'),
            goToSettingsButton: tr('settings'),
            goToSettingsDescription: tr('app_lock_not_enrolled'),
          ),
        ],
        options: const AuthenticationOptions(
          // Allow PIN/pattern/passcode as well as biometrics.
          biometricOnly: false,
          // Keep the prompt up if the user glances at a notification —
          // otherwise a banker gets bounced back to the lock screen
          // constantly during a busy game.
          stickyAuth: true,
          useErrorDialogs: true,
        ),
      );
      return ok
          ? const AppLockResult.success()
          : const AppLockResult.failure(AppLockFailure.failed);
    } on PlatformException catch (e) {
      return AppLockResult.failure(_mapError(e.code));
    } catch (_) {
      return const AppLockResult.failure(AppLockFailure.failed);
    }
  }

  /// Maps plugin error codes to our own enum.
  ///
  /// Compared case-insensitively against known substrings rather than
  /// exact constants, because the codes differ between Android and iOS
  /// and have been renamed across plugin versions.
  static AppLockFailure _mapError(String code) {
    final c = code.toLowerCase();
    if (c.contains('notavailable') || c.contains('nohardware')) {
      return AppLockFailure.unavailable;
    }
    if (c.contains('notenrolled') || c.contains('passcodenotset')) {
      return AppLockFailure.notEnrolled;
    }
    if (c.contains('lockedout')) {
      return AppLockFailure.lockedOut;
    }
    if (c.contains('cancel')) {
      return AppLockFailure.cancelled;
    }
    return AppLockFailure.failed;
  }

  /// Localized, non-technical explanation of a failure.
  static String messageFor(AppLockFailure failure) {
    switch (failure) {
      case AppLockFailure.cancelled:
        return tr('app_lock_cancelled');
      case AppLockFailure.failed:
        return tr('app_lock_failed');
      case AppLockFailure.notEnrolled:
        return tr('app_lock_not_enrolled');
      case AppLockFailure.unavailable:
        return tr('app_lock_unavailable');
      case AppLockFailure.lockedOut:
        return tr('app_lock_locked_out');
    }
  }
}
