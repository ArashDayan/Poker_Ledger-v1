import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'license_keys.dart';
import 'license_model.dart';

/// Offline RSA signature verification.
///
/// WHY HAND-ROLLED
/// Verifying an RSA PKCS#1 v1.5 signature is a *public*-key operation:
/// `s^e mod n`, then a byte comparison against a deterministic padded
/// digest. Dart's built-in [BigInt.modPow] does the only hard part, and
/// `package:crypto` (already a dependency) supplies SHA-256. So this needs
/// no new dependency at all — which matters for an offline-first app that
/// must keep building without network access to pub.dev.
///
/// Note this is verification only. There is no private-key code here and
/// none is possible: signing lives in `tool/issue_license.py` on the
/// owner's machine.
///
/// SECURITY NOTE
/// Timing side channels are irrelevant here — every input to this routine
/// is public (the signature, the modulus, the digest). The secret is the
/// private key, which is not on the device.
class LicenseVerifier {
  LicenseVerifier._();

  static final BigInt _modulus =
      BigInt.parse(LicenseKeys.modulusHex, radix: 16);
  static final BigInt _exponent = BigInt.from(LicenseKeys.exponent);

  /// Parses and cryptographically verifies a pasted license blob.
  ///
  /// Format: `PLK1.<base64url(payload json)>.<base64url(signature)>`
  ///
  /// Everything is rejected unless the signature over the EXACT payload
  /// bytes checks out. Note it verifies the raw received bytes rather than
  /// re-encoding the decoded JSON — re-encoding would let a subtly
  /// different-but-equivalent payload pass, and would break on any key
  /// ordering difference.
  static LicenseCheck verify(String raw) {
    final blob = normalize(raw);
    if (blob.isEmpty) return const LicenseCheck.fail(LicenseError.empty);

    final parts = blob.split('.');
    if (parts.length != 3 || parts[0] != LicenseKeys.blobPrefix) {
      // A wrong prefix with an otherwise sane shape means a newer format.
      if (parts.length == 3 &&
          parts[0].startsWith('PLK') &&
          parts[0] != LicenseKeys.blobPrefix) {
        return const LicenseCheck.fail(LicenseError.futureFormat);
      }
      return const LicenseCheck.fail(LicenseError.malformed);
    }

    final Uint8List payloadBytes;
    final Uint8List signature;
    try {
      payloadBytes = _b64urlDecode(parts[1]);
      signature = _b64urlDecode(parts[2]);
    } catch (_) {
      return const LicenseCheck.fail(LicenseError.malformed);
    }

    if (!_verifySignature(payloadBytes, signature)) {
      return const LicenseCheck.fail(LicenseError.badSignature);
    }

    // Only now is the payload trustworthy enough to interpret.
    LicensePayload payload;
    try {
      final json = jsonDecode(utf8.decode(payloadBytes));
      if (json is! Map<String, dynamic>) {
        return const LicenseCheck.fail(LicenseError.malformed);
      }
      final version = json['v'];
      if (version is int && version > LicenseKeys.supportedFormatVersion) {
        return const LicenseCheck.fail(LicenseError.futureFormat);
      }
      payload = LicensePayload.fromJson(json);
    } catch (_) {
      return const LicenseCheck.fail(LicenseError.malformed);
    }

    return LicenseCheck.ok(payload);
  }

  /// Strips whitespace and line breaks. Licenses get delivered over
  /// WhatsApp and email, which wrap long strings — a banker pasting a
  /// license that arrived on two lines should just work.
  static String normalize(String raw) =>
      raw.replaceAll(RegExp(r'\s+'), '').trim();

  /// RSASSA-PKCS1-v1_5 verify with SHA-256.
  static bool _verifySignature(Uint8List message, Uint8List signature) {
    final k = (_modulus.bitLength + 7) >> 3;
    // A signature must be exactly the modulus size. Anything else is
    // malformed, and rejecting early avoids pointless big-int work.
    if (signature.isEmpty || signature.length > k) return false;

    final s = _bytesToBigInt(signature);
    if (s >= _modulus) return false;

    final m = s.modPow(_exponent, _modulus);
    final em = _bigIntToBytes(m, k);

    final expected = _pkcs1Sha256Encode(message, k);
    if (expected == null) return false;

    if (em.length != expected.length) return false;
    var diff = 0;
    for (var i = 0; i < em.length; i++) {
      diff |= em[i] ^ expected[i];
    }
    return diff == 0;
  }

  /// Builds `0x00 0x01 0xFF..0xFF 0x00 || DigestInfo(SHA-256, hash)`.
  static Uint8List? _pkcs1Sha256Encode(Uint8List message, int k) {
    // DER prefix for SHA-256 DigestInfo, per RFC 8017 §9.2 note 1.
    const digestInfoPrefix = <int>[
      0x30, 0x31, 0x30, 0x0d, 0x06, 0x09, 0x60, 0x86, 0x48, 0x01, //
      0x65, 0x03, 0x04, 0x02, 0x01, 0x05, 0x00, 0x04, 0x20,
    ];
    final hash = sha256.convert(message).bytes;
    final t = <int>[...digestInfoPrefix, ...hash];

    // Needs at least 11 bytes of overhead for legal padding.
    if (k < t.length + 11) return null;

    final out = Uint8List(k);
    out[0] = 0x00;
    out[1] = 0x01;
    final padLen = k - t.length - 3;
    for (var i = 0; i < padLen; i++) {
      out[2 + i] = 0xff;
    }
    out[2 + padLen] = 0x00;
    out.setRange(k - t.length, k, t);
    return out;
  }

  static BigInt _bytesToBigInt(Uint8List bytes) {
    var result = BigInt.zero;
    for (final b in bytes) {
      result = (result << 8) | BigInt.from(b);
    }
    return result;
  }

  static Uint8List _bigIntToBytes(BigInt value, int length) {
    final out = Uint8List(length);
    var v = value;
    final mask = BigInt.from(0xff);
    for (var i = length - 1; i >= 0; i--) {
      out[i] = (v & mask).toInt();
      v = v >> 8;
    }
    return out;
  }

  /// Base64url decode tolerant of missing '=' padding, which is how the
  /// issuer emits it and how most transports mangle it.
  static Uint8List _b64urlDecode(String input) {
    var s = input.replaceAll('-', '+').replaceAll('_', '/');
    final pad = s.length % 4;
    if (pad == 2) {
      s += '==';
    } else if (pad == 3) {
      s += '=';
    } else if (pad == 1) {
      throw const FormatException('Invalid base64 length');
    }
    return Uint8List.fromList(base64.decode(s));
  }
}
