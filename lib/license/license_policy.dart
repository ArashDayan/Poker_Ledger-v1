import 'license_model.dart';

/// Policy rules layered ON TOP of the existing signature system.
///
/// WHAT THIS IS NOT
/// This file contains no cryptography and no storage. [LicenseVerifier]
/// still owns RSA, [LicenseStorage] still owns persistence, and
/// [LicenseService] still owns the activation flow. This is purely the
/// place that answers policy questions like "how many devices may this
/// license type use?" so those answers live in one auditable spot instead
/// of being scattered through the service.
///
/// Adding it changed nothing about how a license is verified: an existing
/// customer license issued before this file existed validates and
/// activates exactly as it did before.
class LicensePolicy {
  LicensePolicy._();

  /// Default number of personal devices an Owner License covers when the
  /// issuer does not say otherwise. Phone + tablet + one spare.
  ///
  /// Configurable per-license via `--devices` at issue time; this is only
  /// the fallback when the payload omits it.
  static const int defaultOwnerDeviceLimit = 3;

  /// Customer licenses default to a single device unless the owner
  /// deliberately issues more (e.g. a club).
  static const int defaultCustomerDeviceLimit = 1;

  /// Hard ceiling, so a typo like `--devices 9999` cannot silently create
  /// an effectively unlimited license.
  static const int maxDeviceLimit = 25;

  /// Effective device allowance for a verified payload.
  ///
  /// The signed `device_limit` is authoritative — it is inside the signed
  /// bytes, so it cannot be edited without breaking the signature. This
  /// only supplies a sane floor for owner licenses issued before the
  /// owner policy existed, which would otherwise read as 1 device.
  static int deviceLimitFor(LicensePayload payload) {
    if (payload.type == LicenseType.owner) {
      final signed = payload.deviceLimit;
      return signed > defaultOwnerDeviceLimit
          ? signed
          : defaultOwnerDeviceLimit;
    }
    return payload.deviceLimit;
  }

  /// Whether this license may be used on more than one device at once.
  static bool allowsMultipleDevices(LicensePayload payload) =>
      deviceLimitFor(payload) > 1;

  /// The Owner License is the master key: it never expires, even if an
  /// expiry somehow appears in the payload.
  ///
  /// Deliberately a policy decision rather than a verification one — the
  /// signature is still checked normally. This only means the owner can
  /// never be locked out of their own software by a stale date.
  static bool isExpiryEnforced(LicensePayload payload) =>
      payload.type != LicenseType.owner;

  /// Single place the rest of the app asks "is this license expired?",
  /// so the owner exemption cannot be forgotten at one call site.
  static bool isExpired(LicensePayload payload, DateTime now) {
    if (!isExpiryEnforced(payload)) return false;
    return payload.isExpiredAt(now);
  }

  /// True for the owner's own master license.
  static bool isOwner(LicensePayload payload) =>
      payload.type == LicenseType.owner;

  /// Human-facing description of the device allowance, used in Settings.
  static String deviceAllowanceSummary(LicensePayload payload) {
    final limit = deviceLimitFor(payload);
    return limit == 1 ? '1' : '$limit';
  }
}
