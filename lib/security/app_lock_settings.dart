import '../services/hive_service.dart';

/// How long the app may sit in the background before it re-locks.
enum AutoLockTimeout {
  /// Re-lock the moment the app leaves the foreground.
  immediately(0),
  after1Minute(1),
  after5Minutes(5),
  after15Minutes(15);

  const AutoLockTimeout(this.minutes);

  /// Minutes of inactivity tolerated. 0 means lock immediately.
  final int minutes;

  Duration get duration => Duration(minutes: minutes);

  static AutoLockTimeout fromMinutes(int? value) {
    return AutoLockTimeout.values.firstWhere(
      (t) => t.minutes == value,
      orElse: () => AutoLockTimeout.immediately,
    );
  }
}

/// Persistence for App Lock *preferences only*.
///
/// WHAT IS STORED
///   - a boolean: is App Lock on?
///   - an int: auto-lock timeout in minutes
///
/// WHAT IS NEVER STORED
/// No fingerprint, no face template, no PIN, no pattern, no password, no
/// token derived from any of them. The app is never given that data by
/// the OS in the first place — [AppLockService] receives only a boolean.
///
/// Uses the app's existing Hive settings box, which lives in the OS's
/// private per-app storage (not readable by other apps on a non-rooted
/// device). Nothing here is secret: knowing that App Lock is enabled
/// tells an attacker nothing useful, and the lock is enforced by the OS
/// prompt rather than by this flag.
class AppLockSettings {
  AppLockSettings._();

  static const _enabledKey = 'app_lock_enabled';
  static const _timeoutKey = 'app_lock_timeout_minutes';

  static bool get isEnabled =>
      HiveService.settings.get(_enabledKey, defaultValue: false) as bool;

  static Future<void> setEnabled(bool value) =>
      HiveService.settings.put(_enabledKey, value);

  static AutoLockTimeout get timeout => AutoLockTimeout.fromMinutes(
        HiveService.settings.get(_timeoutKey, defaultValue: 0) as int,
      );

  static Future<void> setTimeout(AutoLockTimeout value) =>
      HiveService.settings.put(_timeoutKey, value.minutes);
}
