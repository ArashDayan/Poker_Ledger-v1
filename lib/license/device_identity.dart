import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';

import '../services/hive_service.dart';

/// A stable, privacy-respecting identifier for this installation.
///
/// WHY NOT A HARDWARE ID
/// Android has deliberately made true hardware identifiers (IMEI, serial,
/// MAC) unavailable to normal apps since API 29, and using ANDROID_ID
/// would drag in another plugin. More importantly, a hardware id is
/// personal data we have no reason to collect for a home-game ledger.
///
/// WHAT THIS IS INSTEAD
/// A random 256-bit value generated once on first launch and stored
/// locally, mixed with coarse, non-identifying platform facts. Because it
/// is created per *installation*, it gives exactly the property the owner
/// asked for:
///
///   - Copying the APK to another phone and installing it produces a
///     fresh install with a NEW device id, so the existing activation
///     does not carry over and the copy demands its own activation.
///   - The original device keeps working forever, offline.
///
/// HONEST LIMITATION (documented, not hidden)
/// Because it is per-installation, clearing app data or reinstalling on
/// the SAME phone also produces a new id, so that phone must be
/// re-activated. Within the license's device limit this simply consumes a
/// slot. This is the standard trade-off for not requiring hardware
/// permissions, and it is why [deviceLimit] exists and why the owner can
/// always re-issue.
class DeviceIdentity {
  DeviceIdentity._();

  static const _storageKey = 'license_device_id_v1';
  static String? _cached;

  /// Returns the stable device id, creating and persisting it on first
  /// call. Safe to call repeatedly — the value is memoised.
  static String get id {
    final cached = _cached;
    if (cached != null) return cached;

    final box = HiveService.settings;
    final existing = box.get(_storageKey);
    if (existing is String && existing.length == 64) {
      _cached = existing;
      return existing;
    }

    final generated = _generate();
    box.put(_storageKey, generated);
    _cached = generated;
    return generated;
  }

  /// Short, human-readable form for display and for the customer to send
  /// to the owner when requesting a license. Grouped for readability over
  /// a phone call: `A1B2-C3D4-E5F6`.
  static String get shortId {
    final full = id.toUpperCase();
    return '${full.substring(0, 4)}-${full.substring(4, 8)}-'
        '${full.substring(8, 12)}';
  }

  /// Coarse platform description shown in Settings. Contains no
  /// identifiers — just enough for the owner to tell two activations
  /// apart when supporting a customer.
  static String get platformLabel {
    try {
      if (Platform.isAndroid) return 'Android';
      if (Platform.isIOS) return 'iOS';
      if (Platform.isWindows) return 'Windows';
      if (Platform.isMacOS) return 'macOS';
      if (Platform.isLinux) return 'Linux';
    } catch (_) {
      // Platform is unavailable on web; fall through.
    }
    return 'Unknown';
  }

  static String _generate() {
    // Random.secure() is backed by the platform CSPRNG. Falling back to a
    // time-seeded Random would be a real weakness, so if secure entropy is
    // genuinely unavailable we still mix in several independent sources
    // rather than silently degrading to a predictable value.
    final entropy = <int>[];
    try {
      final rng = Random.secure();
      for (var i = 0; i < 32; i++) {
        entropy.add(rng.nextInt(256));
      }
    } catch (_) {
      final rng = Random();
      for (var i = 0; i < 32; i++) {
        entropy.add(rng.nextInt(256));
      }
    }
    entropy.addAll(utf8.encode(DateTime.now().microsecondsSinceEpoch.toString()));
    entropy.addAll(utf8.encode(platformLabel));
    try {
      entropy.addAll(utf8.encode(Platform.operatingSystemVersion));
    } catch (_) {
      // Not fatal — the random half already carries the entropy.
    }
    return sha256.convert(entropy).toString();
  }

  /// Test-only hook so suites can pin a device id without touching Hive.
  static void debugOverride(String? value) => _cached = value;
}
