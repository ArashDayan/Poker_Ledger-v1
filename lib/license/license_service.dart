import 'device_identity.dart';
import 'license_model.dart';
import 'license_policy.dart';
import 'license_storage.dart';
import 'license_verifier.dart';

/// Outcome of a full activation attempt (signature + policy + binding).
class ActivationResult {
  final bool success;
  final LicenseError? error;
  final LicensePayload? payload;

  const ActivationResult.success(this.payload)
      : success = true,
        error = null;

  const ActivationResult.failure(this.error)
      : success = false,
        payload = null;
}

/// The single entry point the rest of the app uses to ask "may this
/// device run?".
///
/// DESIGN
/// Stateless and static, like the app's other services. It owns policy
/// (expiry, device binding, device limits) while [LicenseVerifier] owns
/// cryptography and [LicenseStorage] owns persistence. Keeping those
/// three apart is what makes a future server-verification mode a drop-in:
/// only this class needs an async path added.
///
/// IMPORTANT
/// Nothing here reads or writes sessions, players or transactions. The
/// license layer is strictly additive — it gates access to the UI and
/// touches no ledger data, so an activation problem can never corrupt or
/// lose a night's bookkeeping.
class LicenseService {
  LicenseService._();

  /// Re-verifies the stored activation from scratch.
  ///
  /// Deliberately re-runs the FULL signature check on every launch rather
  /// than trusting a stored "is activated" boolean. Persisting a boolean
  /// would mean the whole scheme collapses the moment someone flips it in
  /// local storage; re-deriving trust from the signed blob every time
  /// means the only way to be activated is to actually hold a valid,
  /// owner-signed license.
  static LicenseStatus currentStatus({DateTime? now}) {
    final clock = (now ?? DateTime.now()).toUtc();
    final record = LicenseStorage.read();
    if (record == null) {
      return const LicenseStatus.inactive();
    }

    final check = LicenseVerifier.verify(record.blob);
    if (!check.valid) {
      // Signature no longer verifies: the record was tampered with, or
      // the signing key was rotated. Either way this device is not
      // licensed — but the ledger data is untouched.
      return LicenseStatus.invalid(check.error ?? LicenseError.tampered);
    }

    final payload = check.payload!;

    // Device binding. The stored record names the device it was activated
    // on; if that no longer matches, this is a copied data directory.
    if (record.deviceId != DeviceIdentity.id) {
      return const LicenseStatus.invalid(LicenseError.wrongDevice);
    }

    // Expiry goes through LicensePolicy so the Owner License exemption
    // is applied in exactly one place. Customer licenses are unaffected.
    if (LicensePolicy.isExpired(payload, clock)) {
      return LicenseStatus.expired(payload, record.activatedAt);
    }

    return LicenseStatus.active(payload, record.activatedAt, record.deviceId);
  }

  /// Validates a pasted key and, if good, binds it to this device.
  static Future<ActivationResult> activate(String rawKey,
      {DateTime? now}) async {
    final clock = (now ?? DateTime.now()).toUtc();
    final normalized = LicenseVerifier.normalize(rawKey);
    if (normalized.isEmpty) {
      return const ActivationResult.failure(LicenseError.empty);
    }

    final check = LicenseVerifier.verify(normalized);
    if (!check.valid) {
      return ActivationResult.failure(check.error ?? LicenseError.malformed);
    }

    final payload = check.payload!;

    if (LicensePolicy.isExpired(payload, clock)) {
      return const ActivationResult.failure(LicenseError.expired);
    }

    final device = DeviceIdentity.id;

    // If the owner pre-bound specific devices, honour that list strictly.
    if (payload.boundDevices.isNotEmpty &&
        !payload.boundDevices.contains(device)) {
      return const ActivationResult.failure(LicenseError.wrongDevice);
    }

    // MULTI-DEVICE / OWNER LICENSE
    // Activation state is stored per installation, so activating a second
    // device never reads or writes the first device's record. That is what
    // makes the Owner License work the way it must: activating the tablet
    // cannot deactivate the phone, because the phone's storage is simply
    // not involved. The same is true for a multi-seat club license.
    //
    // Device-limit accounting stays LOCAL-ONLY: a purely offline app
    // cannot know what other handsets did with the same key. Enforcing
    // the count truthfully requires the server hook below. What is
    // enforced offline is that a key must be genuinely owner-signed and
    // that pre-bound licenses only work on their named devices — which is
    // what stops a copied APK from just working.
    await LicenseStorage.write(ActivationRecord(
      blob: normalized,
      deviceId: device,
      activatedAt: clock,
    ));

    return ActivationResult.success(payload);
  }

  /// Releases this device so the license can be moved to another phone.
  static Future<void> deactivate() => LicenseStorage.clear();

  /// Seam for future server-based verification.
  ///
  /// A server build would call out here to confirm the license is not
  /// revoked and that the device count is within [LicensePayload
  /// .deviceLimit], then cache the answer with a grace period so the app
  /// stays usable offline at the table. Returning null today means "no
  /// opinion", and every caller already treats the offline result as
  /// authoritative — so adding the network path later changes no call
  /// sites.
  static Future<bool?> remoteRevalidate(LicensePayload payload) async => null;
}

/// Immutable snapshot of licensing state, consumed by the UI.
class LicenseStatus {
  final bool isActive;
  final LicensePayload? payload;
  final DateTime? activatedAt;
  final String? deviceId;
  final LicenseError? error;
  final bool wasEverActivated;

  const LicenseStatus.inactive()
      : isActive = false,
        payload = null,
        activatedAt = null,
        deviceId = null,
        error = null,
        wasEverActivated = false;

  const LicenseStatus.active(
      LicensePayload this.payload, DateTime this.activatedAt, String this.deviceId)
      : isActive = true,
        error = null,
        wasEverActivated = true;

  const LicenseStatus.expired(LicensePayload this.payload, this.activatedAt)
      : isActive = false,
        deviceId = null,
        error = LicenseError.expired,
        wasEverActivated = true;

  const LicenseStatus.invalid(LicenseError this.error)
      : isActive = false,
        payload = null,
        activatedAt = null,
        deviceId = null,
        wasEverActivated = true;

  /// True when this is the owner's master license.
  bool get isOwnerLicense =>
      payload != null && LicensePolicy.isOwner(payload!);

  /// Devices this license covers, after policy defaults are applied.
  int? get deviceAllowance =>
      payload == null ? null : LicensePolicy.deviceLimitFor(payload!);

  /// Days left, or null for a perpetual license — and always null for the
  /// Owner License, which policy never expires.
  int? daysRemaining({DateTime? now}) {
    final p = payload;
    if (p == null) return null;
    if (!LicensePolicy.isExpiryEnforced(p)) return null;
    final exp = p.expiresAt;
    if (exp == null) return null;
    return exp.difference((now ?? DateTime.now()).toUtc()).inDays;
  }
}
