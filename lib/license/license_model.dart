import 'dart:convert';

/// What kind of license was issued. Stored as a string in the payload so
/// adding a type later cannot invalidate licenses already in the field.
enum LicenseType {
  /// Normal paid license.
  standard,

  /// Time-limited evaluation.
  trial,

  /// A full customer license. Behaves like [standard]; kept distinct so
  /// invoices and support conversations can use the same word the
  /// customer was sold.
  full,

  /// Multi-seat customer license for a venue running several tables.
  /// Ordinary customer rules apply — it simply tends to be issued with a
  /// higher device limit.
  club,

  /// The software owner's permanent master license. Covers several of
  /// the owner's own devices (phone, tablet, spare) and is never expired
  /// by policy. See LicensePolicy.
  owner;

  /// Unknown values fall back to [standard] rather than throwing, so a
  /// license issued by a NEWER tool still activates on an older build
  /// instead of bricking a paying customer.
  static LicenseType parse(String? raw) {
    switch (raw) {
      case 'trial':
        return LicenseType.trial;
      case 'full':
        return LicenseType.full;
      case 'club':
        return LicenseType.club;
      case 'owner':
        return LicenseType.owner;
      default:
        return LicenseType.standard;
    }
  }

  /// True for every non-owner type. Used by policy so adding a customer
  /// type later automatically inherits customer rules.
  bool get isCustomer => this != LicenseType.owner;

  String get wire => name;
}

/// The signed half of a license: everything the owner commits to when
/// issuing. This object is reconstructed verbatim from the license blob
/// and is only trusted AFTER its signature has been verified.
///
/// Deliberately a plain immutable value type with no Hive adapter — it is
/// persisted as the original blob string, not as fields, so there is no
/// new type id and no migration risk to the existing boxes.
class LicensePayload {
  /// Unique id of this license, e.g. `PL-2026-0001`. Shown in Settings so
  /// the owner and the customer can talk about the same license.
  final String licenseId;

  /// Who it was issued to.
  final String customerId;
  final String customerName;

  final LicenseType type;

  /// When the owner issued it (not when it was activated).
  final DateTime issuedAt;

  /// Null means perpetual.
  final DateTime? expiresAt;

  /// How many distinct devices may activate this license.
  final int deviceLimit;

  /// Devices the owner has pre-bound at issue time. Empty means "bind to
  /// whichever device activates first", which is the normal flow.
  ///
  /// Present so a future server can issue device-scoped licenses without
  /// a format change.
  final List<String> boundDevices;

  const LicensePayload({
    required this.licenseId,
    required this.customerId,
    required this.customerName,
    required this.type,
    required this.issuedAt,
    required this.deviceLimit,
    this.expiresAt,
    this.boundDevices = const [],
  });

  bool get isPerpetual => expiresAt == null;

  /// Expiry is evaluated against the supplied clock so tests can pin time
  /// and so a future server can pass authoritative time instead of the
  /// device's (which the user controls).
  bool isExpiredAt(DateTime now) =>
      expiresAt != null && now.isAfter(expiresAt!);

  factory LicensePayload.fromJson(Map<String, dynamic> j) {
    DateTime? parseDate(Object? v) {
      if (v == null) return null;
      return DateTime.tryParse(v.toString())?.toUtc();
    }

    final issued = parseDate(j['issued_at']);
    if (issued == null) {
      throw const FormatException('License payload has no valid issued_at');
    }
    final id = (j['license_id'] ?? '').toString();
    if (id.isEmpty) {
      throw const FormatException('License payload has no license_id');
    }

    final rawLimit = j['device_limit'];
    final limit = rawLimit is int
        ? rawLimit
        : int.tryParse(rawLimit?.toString() ?? '') ?? 1;

    return LicensePayload(
      licenseId: id,
      customerId: (j['customer_id'] ?? '').toString(),
      customerName: (j['customer_name'] ?? '').toString(),
      type: LicenseType.parse(j['type']?.toString()),
      issuedAt: issued,
      expiresAt: parseDate(j['expires_at']),
      deviceLimit: limit < 1 ? 1 : limit,
      boundDevices: (j['bound_devices'] as List?)
              ?.map((e) => e.toString())
              .toList(growable: false) ??
          const [],
    );
  }

  Map<String, dynamic> toJson() => {
        'license_id': licenseId,
        'customer_id': customerId,
        'customer_name': customerName,
        'type': type.wire,
        'issued_at': issuedAt.toIso8601String(),
        if (expiresAt != null) 'expires_at': expiresAt!.toIso8601String(),
        'device_limit': deviceLimit,
        if (boundDevices.isNotEmpty) 'bound_devices': boundDevices,
      };
}

/// A license that has been verified AND bound to this device.
///
/// [blob] is the original pasted license text. It is kept so verification
/// can be re-run from scratch on every launch — the stored activation
/// record is never trusted on its own, which is what stops someone from
/// hand-editing a "activated: true" flag into local storage.
class ActivationRecord {
  final String blob;
  final String deviceId;
  final DateTime activatedAt;

  const ActivationRecord({
    required this.blob,
    required this.deviceId,
    required this.activatedAt,
  });

  Map<String, dynamic> toJson() => {
        'blob': blob,
        'device_id': deviceId,
        'activated_at': activatedAt.toIso8601String(),
      };

  static ActivationRecord? tryParse(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final j = jsonDecode(raw) as Map<String, dynamic>;
      final blob = (j['blob'] ?? '').toString();
      final device = (j['device_id'] ?? '').toString();
      final at = DateTime.tryParse((j['activated_at'] ?? '').toString());
      if (blob.isEmpty || device.isEmpty || at == null) return null;
      return ActivationRecord(
        blob: blob,
        deviceId: device,
        activatedAt: at,
      );
    } catch (_) {
      return null;
    }
  }
}

/// Why an activation attempt failed. The UI maps these to localized,
/// non-technical messages — a banker needs to know what to do next, not
/// which parsing step threw.
enum LicenseError {
  empty,
  malformed,
  badSignature,
  expired,
  wrongDevice,
  deviceLimitReached,
  futureFormat,
  tampered,
}

/// Result of verifying a license blob.
class LicenseCheck {
  final bool valid;
  final LicensePayload? payload;
  final LicenseError? error;

  const LicenseCheck.ok(LicensePayload this.payload)
      : valid = true,
        error = null;

  const LicenseCheck.fail(LicenseError this.error)
      : valid = false,
        payload = null;
}
