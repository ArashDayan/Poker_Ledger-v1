// License / activation layer.
//
// These tests exercise the REAL cryptographic path against genuinely
// signed fixtures — there is no stubbed verifier. A forged or edited
// license must fail here for the same reason it fails on a phone.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:poker_ledger/license/device_identity.dart';
import 'package:poker_ledger/license/license_model.dart';
import 'package:poker_ledger/license/license_policy.dart';
import 'package:poker_ledger/license/license_service.dart';
import 'package:poker_ledger/license/license_storage.dart';
import 'package:poker_ledger/license/license_verifier.dart';
import 'package:poker_ledger/models/player.dart';
import 'package:poker_ledger/models/session.dart';
import 'package:poker_ledger/models/transaction.dart';
import 'package:poker_ledger/services/hive_service.dart';
import 'test_helper.dart';

import 'license_fixtures.dart';

late Directory _tmp;

Future<void> _open() async {
  _tmp = await Directory.systemTemp.createTemp('pl_license_');
  Hive.init(_tmp.path);
  registerTestAdapters();
  await Hive.openBox<PokerSession>(HiveService.sessionsBox);
  await Hive.openBox<Player>(HiveService.playersBox);
  await Hive.openBox<LedgerTransaction>(HiveService.transactionsBox);
  await Hive.openBox(HiveService.settingsBox);
  DeviceIdentity.debugOverride(null);
}

Future<void> _close() async {
  DeviceIdentity.debugOverride(null);
  await Hive.deleteFromDisk();
  if (await _tmp.exists()) await _tmp.delete(recursive: true);
}

void main() {
  setUp(_open);
  tearDown(_close);

  group('signature verification', () {
    test('accepts a genuinely signed license', () {
      final result = LicenseVerifier.verify(kValidLicense);
      expect(result.valid, isTrue);
      expect(result.payload!.licenseId, 'PL-2026-0001');
      expect(result.payload!.customerName, 'Test Banker');
      expect(result.payload!.type, LicenseType.standard);
      expect(result.payload!.deviceLimit, 1);
      expect(result.payload!.isPerpetual, isTrue);
    });

    test('rejects a payload edited to raise the device limit', () {
      // The signature still belongs to the original payload, so this is
      // exactly what an attacker editing the blob would produce.
      final result = LicenseVerifier.verify(kTamperedLicense);
      expect(result.valid, isFalse);
      expect(result.error, LicenseError.badSignature);
    });

    test('rejects an empty key', () {
      expect(LicenseVerifier.verify('   ').error, LicenseError.empty);
    });

    test('rejects arbitrary text', () {
      expect(LicenseVerifier.verify('hello world').error,
          LicenseError.malformed);
    });

    test('rejects a truncated key', () {
      final short = kValidLicense.substring(0, kValidLicense.length - 40);
      expect(LicenseVerifier.verify(short).valid, isFalse);
    });

    test('rejects a single flipped signature character', () {
      final parts = kValidLicense.split('.');
      final sig = parts[2];
      final swapped = sig[0] == 'A' ? 'B' : 'A';
      final broken = '${parts[0]}.${parts[1]}.$swapped${sig.substring(1)}';
      expect(LicenseVerifier.verify(broken).valid, isFalse);
    });

    test('reports a newer format distinctly from a bad signature', () {
      expect(LicenseVerifier.verify('PLK9.abc.def').error,
          LicenseError.futureFormat);
    });

    test('tolerates whitespace and line wrapping from messaging apps', () {
      final mid = kValidLicense.length ~/ 2;
      final wrapped =
          '${kValidLicense.substring(0, mid)}\n   ${kValidLicense.substring(mid)}\n';
      expect(LicenseVerifier.verify(wrapped).valid, isTrue);
    });
  });

  group('expiry', () {
    test('a trial license is valid before its expiry', () {
      final result = LicenseVerifier.verify(kTrialLicense);
      expect(result.valid, isTrue);
      expect(result.payload!.type, LicenseType.trial);
      expect(result.payload!.isPerpetual, isFalse);
      expect(result.payload!.isExpiredAt(DateTime.now().toUtc()), isFalse);
    });

    test('an expired license verifies cryptographically but is refused',
        () async {
      // Important distinction: the signature is genuine. It is policy,
      // not crypto, that rejects it.
      expect(LicenseVerifier.verify(kExpiredLicense).valid, isTrue);

      final result = await LicenseService.activate(kExpiredLicense);
      expect(result.success, isFalse);
      expect(result.error, LicenseError.expired);
    });

    test('a perpetual license never expires', () {
      final payload = LicenseVerifier.verify(kValidLicense).payload!;
      expect(
        payload.isExpiredAt(DateTime.utc(2099)),
        isFalse,
      );
    });
  });

  group('activation lifecycle', () {
    test('a fresh install is not activated', () {
      expect(LicenseService.currentStatus().isActive, isFalse);
      expect(LicenseService.currentStatus().wasEverActivated, isFalse);
    });

    test('activating a valid key succeeds and persists', () async {
      final result = await LicenseService.activate(kValidLicense);
      expect(result.success, isTrue);

      final status = LicenseService.currentStatus();
      expect(status.isActive, isTrue);
      expect(status.payload!.licenseId, 'PL-2026-0001');
      expect(status.activatedAt, isNotNull);
      expect(status.deviceId, DeviceIdentity.id);
    });

    test('activation survives a simulated app restart', () async {
      await LicenseService.activate(kValidLicense);
      // Re-reading from storage is exactly what launch does.
      DeviceIdentity.debugOverride(null);
      expect(LicenseService.currentStatus().isActive, isTrue);
    });

    test('an invalid key does not activate', () async {
      final result = await LicenseService.activate('total-nonsense');
      expect(result.success, isFalse);
      expect(LicenseService.currentStatus().isActive, isFalse);
    });

    test('a failed activation does not overwrite a working one', () async {
      await LicenseService.activate(kValidLicense);
      await LicenseService.activate(kTamperedLicense);
      final status = LicenseService.currentStatus();
      expect(status.isActive, isTrue);
      expect(status.payload!.licenseId, 'PL-2026-0001');
    });

    test('deactivation releases the device', () async {
      await LicenseService.activate(kValidLicense);
      await LicenseService.deactivate();
      expect(LicenseService.currentStatus().isActive, isFalse);
    });
  });

  group('device binding', () {
    test('an activation copied to another device is refused', () async {
      await LicenseService.activate(kValidLicense);
      expect(LicenseService.currentStatus().isActive, isTrue);

      // Simulate the stored record being carried to a different install:
      // same encrypted blob, different device identity.
      DeviceIdentity.debugOverride('f' * 64);
      final status = LicenseService.currentStatus();
      expect(status.isActive, isFalse);
    });

    test('a license pre-bound to another device cannot be activated',
        () async {
      final result = await LicenseService.activate(kBoundLicense);
      expect(result.success, isFalse);
      expect(result.error, LicenseError.wrongDevice);
    });

    test('device id is stable across reads', () {
      final first = DeviceIdentity.id;
      DeviceIdentity.debugOverride(null);
      expect(DeviceIdentity.id, first);
    });

    test('short device id is derived from the full id', () {
      expect(DeviceIdentity.shortId.length, 14);
      expect(DeviceIdentity.shortId.replaceAll('-', ''),
          DeviceIdentity.id.substring(0, 12).toUpperCase());
    });

    test('a multi-device license reports its limit', () async {
      final result = await LicenseService.activate(kMultiDeviceLicense);
      expect(result.success, isTrue);
      expect(result.payload!.deviceLimit, 3);
    });
  });

  group('storage security', () {
    test('the activation is not stored as readable plaintext', () async {
      await LicenseService.activate(kValidLicense);
      final raw = HiveService.settings.get('license_activation_v1');
      expect(raw, isA<String>());
      // None of the meaningful fields should be greppable.
      expect(raw as String, isNot(contains('PL-2026-0001')));
      expect(raw, isNot(contains('Test Banker')));
      expect(raw, isNot(contains('PLK1')));
      expect(raw, isNot(contains('activated_at')));
    });

    test('editing the stored record is detected', () async {
      await LicenseService.activate(kValidLicense);
      final raw = HiveService.settings.get('license_activation_v1') as String;

      // Flip a character in the middle of the ciphertext.
      final mid = raw.length ~/ 2;
      final ch = raw[mid] == 'A' ? 'B' : 'A';
      await HiveService.settings.put(
        'license_activation_v1',
        raw.substring(0, mid) + ch + raw.substring(mid + 1),
      );

      // The HMAC fails, so the record is discarded rather than trusted.
      expect(LicenseStorage.read(), isNull);
      expect(LicenseService.currentStatus().isActive, isFalse);
    });

    test('a hand-written fake activation flag does not unlock the app',
        () async {
      await HiveService.settings.put(
          'license_activation_v1', 'activated=true');
      expect(LicenseService.currentStatus().isActive, isFalse);
    });
  });

  group('ledger data safety', () {
    test('activating and deactivating never touches ledger boxes',
        () async {
      final players = HiveService.players;
      final sessions = HiveService.sessions;
      final txns = HiveService.transactions;

      final player = Player(
        id: 'p1',
        sessionId: 's1',
        name: 'Ali',
        seatNumber: 1,
      );
      await players.put(player.id, player);

      final session = PokerSession(
        id: 's1',
        name: 'Friday Game',
        location: 'Home',
        dateTime: DateTime.now(),
        smallBlind: 1,
        bigBlind: 2,
        tableNumber: '1',
      );
      await sessions.put(session.id, session);

      final txn = LedgerTransaction(
        id: 't1',
        sessionId: 's1',
        playerId: 'p1',
        type: TransactionType.buyIn,
        amount: 100,
        timestamp: DateTime.now(),
      );
      await txns.put(txn.id, txn);

      await LicenseService.activate(kValidLicense);
      await LicenseService.deactivate();
      await LicenseService.activate(kValidLicense);

      expect(players.length, 1);
      expect(sessions.length, 1);
      expect(txns.length, 1);
      expect(players.get('p1')!.name, 'Ali');
      expect(players.get('p1')!.seatNumber, 1);
      expect(sessions.get('s1')!.name, 'Friday Game');
      expect(txns.get('t1')!.amount, 100);
    });
  });

  // ---------------------------------------------------------------
  // Owner License policy. Layered on top of the existing crypto — the
  // signature path below is the SAME one customer licenses use.
  // ---------------------------------------------------------------
  group('owner license', () {
    test('is recognised as the owner master license', () {
      final payload = LicenseVerifier.verify(kOwnerLicense).payload!;
      expect(payload.type, LicenseType.owner);
      expect(LicensePolicy.isOwner(payload), isTrue);
    });

    test('covers multiple devices by default', () {
      final payload = LicenseVerifier.verify(kOwnerLicense).payload!;
      expect(LicensePolicy.deviceLimitFor(payload),
          LicensePolicy.defaultOwnerDeviceLimit);
      expect(LicensePolicy.allowsMultipleDevices(payload), isTrue);
    });

    test('honours a higher configured device count', () {
      final payload = LicenseVerifier.verify(kOwnerLicense5Devices).payload!;
      expect(LicensePolicy.deviceLimitFor(payload), 5);
    });

    test('never expires, even far in the future', () {
      final payload = LicenseVerifier.verify(kOwnerLicense).payload!;
      expect(LicensePolicy.isExpired(payload, DateTime.utc(2099)), isFalse);
      expect(LicensePolicy.isExpiryEnforced(payload), isFalse);
    });

    test('activates successfully', () async {
      final result = await LicenseService.activate(kOwnerLicense);
      expect(result.success, isTrue);
      final status = LicenseService.currentStatus();
      expect(status.isActive, isTrue);
      expect(status.isOwnerLicense, isTrue);
      expect(status.deviceAllowance, 3);
      expect(status.daysRemaining(), isNull);
    });

    test('THE KEY REQUIREMENT: activating a second device does not '
        'deactivate the first', () async {
      // Device A (the phone) activates.
      DeviceIdentity.debugOverride('a' * 64);
      final phone = await LicenseService.activate(kOwnerLicense);
      expect(phone.success, isTrue);
      final phoneRecord =
          HiveService.settings.get('license_activation_v1') as String;
      expect(LicenseService.currentStatus().isActive, isTrue);

      // Device B (the tablet) is a SEPARATE installation with its own
      // storage. Activating it cannot touch the phone's record, because
      // that record lives on the other device entirely.
      DeviceIdentity.debugOverride('b' * 64);
      await LicenseStorage.clear();
      final tablet = await LicenseService.activate(kOwnerLicense);
      expect(tablet.success, isTrue);
      expect(LicenseService.currentStatus().isActive, isTrue);

      // Now prove the phone is still good: restore its untouched record
      // and its identity, exactly as that handset would see it.
      DeviceIdentity.debugOverride('a' * 64);
      await HiveService.settings
          .put('license_activation_v1', phoneRecord);
      final phoneStatus = LicenseService.currentStatus();
      expect(phoneStatus.isActive, isTrue,
          reason: 'Activating the tablet must not lock out the phone');
      expect(phoneStatus.isOwnerLicense, isTrue);
    });

    test('the same owner key activates three devices in turn', () async {
      for (final device in ['1' * 64, '2' * 64, '3' * 64]) {
        DeviceIdentity.debugOverride(device);
        await LicenseStorage.clear();
        final result = await LicenseService.activate(kOwnerLicense);
        expect(result.success, isTrue, reason: 'device $device');
        expect(LicenseService.currentStatus().isActive, isTrue);
      }
    });
  });

  group('customer licenses are unchanged', () {
    test('a customer license is not an owner license', () {
      final payload = LicenseVerifier.verify(kValidLicense).payload!;
      expect(LicensePolicy.isOwner(payload), isFalse);
      expect(payload.type.isCustomer, isTrue);
    });

    test('customer expiry is still enforced', () {
      final payload = LicenseVerifier.verify(kExpiredLicense).payload!;
      expect(LicensePolicy.isExpiryEnforced(payload), isTrue);
      expect(
          LicensePolicy.isExpired(payload, DateTime.now().toUtc()), isTrue);
    });

    test('a single-device customer license stays single-device', () {
      final payload = LicenseVerifier.verify(kValidLicense).payload!;
      expect(LicensePolicy.deviceLimitFor(payload), 1);
      expect(LicensePolicy.allowsMultipleDevices(payload), isFalse);
    });

    test('a club license keeps its issued seat count', () {
      final payload = LicenseVerifier.verify(kClubLicense).payload!;
      expect(payload.type, LicenseType.club);
      expect(LicensePolicy.deviceLimitFor(payload), 5);
      expect(LicensePolicy.isExpiryEnforced(payload), isTrue);
    });

    test('a full license behaves like a standard customer license', () {
      final payload = LicenseVerifier.verify(kFullLicense).payload!;
      expect(payload.type, LicenseType.full);
      expect(LicensePolicy.isOwner(payload), isFalse);
      expect(LicensePolicy.deviceLimitFor(payload), 1);
    });

    test('licenses issued BEFORE the owner policy still verify', () {
      // Regression guard: these fixtures were signed before
      // license_policy.dart existed. They must be unaffected.
      for (final blob in [
        kValidLicense,
        kTrialLicense,
        kMultiDeviceLicense,
        kBoundLicense,
      ]) {
        expect(LicenseVerifier.verify(blob).valid, isTrue);
      }
    });

    test('an unknown future type degrades to standard, not a crash', () {
      // parse() must never throw — an older build meeting a newer type
      // should keep a paying customer working.
      expect(LicenseType.parse('some_new_tier'), LicenseType.standard);
      expect(LicenseType.parse(null), LicenseType.standard);
    });

    test('a forged owner type still fails the signature', () {
      // Editing "standard" -> "owner" in the payload breaks the hash.
      expect(LicenseVerifier.verify(kTamperedLicense).valid, isFalse);
    });
  });
}
