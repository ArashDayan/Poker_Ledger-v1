/// Embedded PUBLIC key used to verify license signatures offline.
///
/// This file intentionally contains only the *public* half of the issuing
/// key pair. Anyone can read it out of the APK — that is fine and expected.
/// Verifying a signature requires only the public key; *creating* one
/// requires the private key, which never ships and is held by the owner
/// outside this repository entirely.
///
/// This is what makes the scheme resistant to key generation by an
/// attacker: unlike a checksum or an offline "algorithm" that can be
/// reverse-engineered out of the binary and re-implemented, forging a
/// signature here means breaking RSA-2048.
///
/// This is the PRODUCTION key for Poker Ledger. Its private half is held
/// only by the owner, outside this repository, at
/// ~/.pokerledger/signing/pokerledger_production_private_key.pem —
/// so it is not in the source tree, not in git, and not in any ZIP of
/// this project.
///
/// ROTATING THE KEY
/// Generate a new pair and replace the modulus below:
///   KEYDIR=~/.pokerledger/signing
///   openssl genrsa -out $KEYDIR/pokerledger_production_private_key.pem 2048
///   openssl rsa -in $KEYDIR/pokerledger_production_private_key.pem \
///       -pubout -out $KEYDIR/pokerledger_production_public_key.pem
///   python3 tool/issue_license.py --print-modulus
/// Every license issued under the previous key stops validating, so only
/// rotate when you intend exactly that.
library;

class LicenseKeys {
  LicenseKeys._();

  /// RSA modulus (n), hex encoded, 2048-bit.
  static const String modulusHex =
      'a448c04a1c58eae1d0469d5718012ac32fcae0f3fc4c2acd4b751114497a513c'
      '3de7b313c23c472fe5a9201384af4eea20fdf49a7b912115f5286784eebad72f'
      '0d1330de69c834745722ab6a999af565a303dd17dccd1feb003310fceb1c586b'
      'a0d76184fa3b6f2e554de2ee4aaba9dc791947e8c50b3bff93b3229eee00b6f4'
      '00e192102889957b53e07b587a74d96bbcdf6b91b93add8f18df58dbfe27eab5'
      '6e29e8a6550a24dd2329ff2172a8dcdf210fccc6519c4e22472f07bdaea91a21'
      'ed1aa3d76b21ef8a157d150ce336882e26250b18f7a52d8d08a01d976178fc75'
      'c1b3d4a7407ef2779673efe1953986a152cea33429744b97bd5d9d0ac1861d4f';

  /// Public exponent (e). 65537 is the standard choice.
  static const int exponent = 65537;

  /// Bumped only if the on-wire license format itself changes, so an old
  /// app can say "this license is newer than me" instead of silently
  /// failing verification for a reason the banker cannot act on.
  static const int supportedFormatVersion = 1;

  /// Prefix every license blob carries, so pasted text that is obviously
  /// not a license can be rejected with a useful message rather than a
  /// generic signature failure.
  static const String blobPrefix = 'PLK1';
}
