import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../services/hive_service.dart';
import 'device_identity.dart';
import 'license_model.dart';

/// Persists the activation record at rest in a non-plaintext, tamper-
/// evident form.
///
/// THREAT MODEL — stated honestly
/// This protects against the realistic attack for a sideloaded home-game
/// app: someone copies the app's data directory (or a backup) to another
/// phone, or edits the local database to fake an activation. It does NOT
/// protect against an attacker who fully controls the device and is
/// willing to patch the APK — nothing running purely on-device can, and
/// claiming otherwise would be dishonest.
///
/// The real protection against forged licenses is the RSA signature in
/// [LicenseVerifier], which is re-checked on every launch. This layer
/// exists so the stored record cannot be trivially read, copied, or
/// hand-edited.
///
/// HOW IT WORKS
///   - A per-record 16-byte random nonce.
///   - A keystream derived by SHA-256(masterKey || nonce || counter),
///     XORed over the plaintext. This is a standard hash-based stream
///     cipher construction; the nonce guarantees the keystream is never
///     reused across writes.
///   - An HMAC-SHA256 tag over nonce+ciphertext, verified before
///     decryption is trusted, so any edit to the stored bytes is detected
///     rather than producing garbage that might parse.
///
/// The master key is derived from the device id, which is itself random
/// and stored locally. That means a record copied to a different install
/// fails its HMAC and is discarded — reinforcing device binding at the
/// storage layer as well as the logic layer.
///
/// NOT USING flutter_secure_storage
/// It would be the textbook answer (Keystore/Keychain-backed), but it is
/// an extra native dependency that cannot be fetched or compiled in this
/// environment, and it would not change the fundamental limitation above.
/// The design is deliberately kept swappable: replace the two methods
/// [_encrypt]/[_decrypt] and nothing else changes.
class LicenseStorage {
  LicenseStorage._();

  static const _recordKey = 'license_activation_v1';
  static const _domain = 'poker-ledger/license-storage/v1';

  /// Reads and authenticates the stored activation record.
  /// Returns null if absent, tampered with, or written by another device.
  static ActivationRecord? read() {
    final raw = HiveService.settings.get(_recordKey);
    if (raw is! String || raw.isEmpty) return null;
    final plain = _decrypt(raw);
    if (plain == null) return null;
    return ActivationRecord.tryParse(plain);
  }

  static Future<void> write(ActivationRecord record) async {
    final plain = jsonEncode(record.toJson());
    await HiveService.settings.put(_recordKey, _encrypt(plain));
  }

  /// Removes the activation. Used by "Deactivate this device" so a
  /// customer can legitimately move a license to a new phone.
  ///
  /// Deliberately touches ONLY the license key — sessions, players and
  /// transactions are never involved.
  static Future<void> clear() async {
    await HiveService.settings.delete(_recordKey);
  }

  static Uint8List get _masterKey {
    final material = utf8.encode('$_domain|${DeviceIdentity.id}');
    return Uint8List.fromList(sha256.convert(material).bytes);
  }

  static String _encrypt(String plaintext) {
    final key = _masterKey;
    final nonce = _randomBytes(16);
    final data = Uint8List.fromList(utf8.encode(plaintext));
    final cipher = _xorKeystream(data, key, nonce);
    final tag = Hmac(sha256, key).convert([...nonce, ...cipher]).bytes;
    return base64.encode([...nonce, ...cipher, ...tag]);
  }

  static String? _decrypt(String encoded) {
    try {
      final all = base64.decode(encoded);
      // 16 nonce + at least 1 byte + 32 tag.
      if (all.length < 16 + 1 + 32) return null;
      final nonce = Uint8List.fromList(all.sublist(0, 16));
      final cipher = Uint8List.fromList(all.sublist(16, all.length - 32));
      final tag = all.sublist(all.length - 32);

      final key = _masterKey;
      final expected = Hmac(sha256, key).convert([...nonce, ...cipher]).bytes;
      if (expected.length != tag.length) return null;
      var diff = 0;
      for (var i = 0; i < tag.length; i++) {
        diff |= expected[i] ^ tag[i];
      }
      // Authenticate BEFORE decrypting, so tampered data is never parsed.
      if (diff != 0) return null;

      return utf8.decode(_xorKeystream(cipher, key, nonce));
    } catch (_) {
      return null;
    }
  }

  static Uint8List _xorKeystream(
      Uint8List input, Uint8List key, Uint8List nonce) {
    final out = Uint8List(input.length);
    var offset = 0;
    var counter = 0;
    while (offset < input.length) {
      final block = sha256
          .convert([...key, ...nonce, ...utf8.encode(counter.toString())])
          .bytes;
      for (var i = 0; i < block.length && offset < input.length; i++) {
        out[offset] = input[offset] ^ block[i];
        offset++;
      }
      counter++;
    }
    return out;
  }

  static Uint8List _randomBytes(int n) {
    final out = Uint8List(n);
    Random rng;
    try {
      rng = Random.secure();
    } catch (_) {
      rng = Random();
    }
    for (var i = 0; i < n; i++) {
      out[i] = rng.nextInt(256);
    }
    return out;
  }
}
