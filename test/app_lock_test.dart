// App Lock: preference storage and auto-lock timing.
//
// SCOPE — stated honestly.
// These tests cover everything that is pure Dart: preference
// persistence, timeout selection, the lock/unlock state machine and the
// lifecycle rules. They deliberately do NOT test the biometric prompt
// itself: that lives entirely inside the operating system, needs real
// hardware and a real enrolled fingerprint, and cannot be exercised in a
// unit test. That part must be verified by hand on a device.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:poker_ledger/models/player.dart';
import 'package:poker_ledger/models/session.dart';
import 'package:poker_ledger/models/transaction.dart';
import 'package:poker_ledger/providers/app_lock_provider.dart';
import 'package:poker_ledger/security/app_lock_settings.dart';
import 'package:poker_ledger/services/hive_service.dart';
import 'test_helper.dart';

late Directory _tmp;

Future<void> _open() async {
  _tmp = await Directory.systemTemp.createTemp('pl_applock_');
  Hive.init(_tmp.path);
  registerTestAdapters();
  await Hive.openBox<PokerSession>(HiveService.sessionsBox);
  await Hive.openBox<Player>(HiveService.playersBox);
  await Hive.openBox<LedgerTransaction>(HiveService.transactionsBox);
  await Hive.openBox(HiveService.settingsBox);
}

Future<void> _close() async {
  await Hive.deleteFromDisk();
  if (await _tmp.exists()) await _tmp.delete(recursive: true);
}

void main() {
  setUp(_open);
  tearDown(_close);

  group('preferences', () {
    test('App Lock is off until the user turns it on', () {
      expect(AppLockSettings.isEnabled, isFalse);
    });

    test('the enabled flag persists', () async {
      await AppLockSettings.setEnabled(true);
      expect(AppLockSettings.isEnabled, isTrue);
      await AppLockSettings.setEnabled(false);
      expect(AppLockSettings.isEnabled, isFalse);
    });

    test('auto-lock defaults to immediately', () {
      expect(AppLockSettings.timeout, AutoLockTimeout.immediately);
    });

    test('every timeout option round-trips through storage', () async {
      for (final t in AutoLockTimeout.values) {
        await AppLockSettings.setTimeout(t);
        expect(AppLockSettings.timeout, t);
      }
    });

    test('an unknown stored value falls back to immediately', () async {
      await HiveService.settings.put('app_lock_timeout_minutes', 999);
      expect(AppLockSettings.timeout, AutoLockTimeout.immediately);
    });

    test('timeout durations are what they claim', () {
      expect(AutoLockTimeout.immediately.duration, Duration.zero);
      expect(AutoLockTimeout.after1Minute.duration,
          const Duration(minutes: 1));
      expect(AutoLockTimeout.after5Minutes.duration,
          const Duration(minutes: 5));
      expect(AutoLockTimeout.after15Minutes.duration,
          const Duration(minutes: 15));
    });
  });

  group('no biometric data is ever stored', () {
    test('only the two preference keys are written', () async {
      final before = HiveService.settings.keys.toSet();
      await AppLockSettings.setEnabled(true);
      await AppLockSettings.setTimeout(AutoLockTimeout.after5Minutes);
      final added = HiveService.settings.keys.toSet().difference(before);

      expect(added, {'app_lock_enabled', 'app_lock_timeout_minutes'});
    });

    test('stored values are a plain bool and int, nothing else', () async {
      await AppLockSettings.setEnabled(true);
      await AppLockSettings.setTimeout(AutoLockTimeout.after1Minute);

      expect(HiveService.settings.get('app_lock_enabled'), isA<bool>());
      expect(
          HiveService.settings.get('app_lock_timeout_minutes'), isA<int>());
      expect(HiveService.settings.get('app_lock_timeout_minutes'), 1);
    });

    test('no key in storage looks like credential material', () async {
      await AppLockSettings.setEnabled(true);
      await AppLockSettings.setTimeout(AutoLockTimeout.after15Minutes);

      for (final key in HiveService.settings.keys) {
        final k = key.toString().toLowerCase();
        expect(k.contains('fingerprint'), isFalse, reason: '$key');
        expect(k.contains('biometric'), isFalse, reason: '$key');
        expect(k.contains('face'), isFalse, reason: '$key');
        expect(k.contains('passcode'), isFalse, reason: '$key');
        expect(k.contains('password'), isFalse, reason: '$key');
        expect(k.contains('pattern'), isFalse, reason: '$key');
      }
    });
  });

  group('lock state machine', () {
    test('a disabled lock never reports locked', () {
      final provider = AppLockProvider(autoLoad: false)
        ..debugSet(enabled: false, locked: true);
      // isLocked is gated on isEnabled, so a stale locked flag cannot
      // strand the user behind a lock they turned off.
      expect(provider.isLocked, isFalse);
    });

    test('loading with the feature on starts LOCKED', () async {
      await AppLockSettings.setEnabled(true);
      final provider = AppLockProvider(autoLoad: false)..load();
      expect(provider.isEnabled, isTrue);
      expect(provider.isLocked, isTrue,
          reason: 'must never show the ledger before authenticating');
    });

    test('loading with the feature off starts unlocked', () async {
      await AppLockSettings.setEnabled(false);
      final provider = AppLockProvider(autoLoad: false)..load();
      expect(provider.isLocked, isFalse);
    });

    test('the stored timeout is picked up on load', () async {
      await AppLockSettings.setEnabled(true);
      await AppLockSettings.setTimeout(AutoLockTimeout.after5Minutes);
      final provider = AppLockProvider(autoLoad: false)..load();
      expect(provider.timeout, AutoLockTimeout.after5Minutes);
    });

    test('changing the timeout persists it', () async {
      final provider = AppLockProvider(autoLoad: false)..load();
      await provider.setTimeout(AutoLockTimeout.after15Minutes);
      expect(AppLockSettings.timeout, AutoLockTimeout.after15Minutes);
      expect(provider.timeout, AutoLockTimeout.after15Minutes);
    });
  });

  group('auto-lock on lifecycle', () {
    test('immediate mode re-locks as soon as the app returns', () {
      final provider = AppLockProvider(autoLoad: false)
        ..debugSet(
            enabled: true,
            locked: false,
            timeout: AutoLockTimeout.immediately);

      provider.onPaused();
      provider.onResumed();
      expect(provider.isLocked, isTrue);
    });

    test('a timed mode does not lock on a brief switch away', () {
      final provider = AppLockProvider(autoLoad: false)
        ..debugSet(
            enabled: true,
            locked: false,
            timeout: AutoLockTimeout.after15Minutes);

      // Backgrounded and returned immediately — well inside 15 minutes.
      provider.onPaused();
      provider.onResumed();
      expect(provider.isLocked, isFalse,
          reason: 'checking a message mid-game must not lock the banker out');
    });

    test('resuming without ever pausing does not lock', () {
      final provider = AppLockProvider(autoLoad: false)
        ..debugSet(
            enabled: true,
            locked: false,
            timeout: AutoLockTimeout.immediately);

      provider.onResumed();
      expect(provider.isLocked, isFalse);
    });

    test('lifecycle events are ignored while the lock is disabled', () {
      final provider = AppLockProvider(autoLoad: false)
        ..debugSet(enabled: false, locked: false);

      provider.onPaused();
      provider.onResumed();
      expect(provider.isLocked, isFalse);
    });
  });

  group('independence from other layers', () {
    test('App Lock preferences do not touch ledger data', () async {
      final players = HiveService.players;
      final sessions = HiveService.sessions;
      final txns = HiveService.transactions;

      await players.put(
        'p1',
        Player(id: 'p1', sessionId: 's1', name: 'Ali', seatNumber: 1),
      );
      await sessions.put(
        's1',
        PokerSession(
          id: 's1',
          name: 'Friday Game',
          location: 'Home',
          dateTime: DateTime.now(),
          smallBlind: 1,
          bigBlind: 2,
          tableNumber: '1',
        ),
      );
      await txns.put(
        't1',
        LedgerTransaction(
          id: 't1',
          sessionId: 's1',
          playerId: 'p1',
          type: TransactionType.buyIn,
          amount: 100,
        ),
      );

      await AppLockSettings.setEnabled(true);
      await AppLockSettings.setTimeout(AutoLockTimeout.after5Minutes);
      await AppLockSettings.setEnabled(false);

      expect(players.length, 1);
      expect(sessions.length, 1);
      expect(txns.length, 1);
      expect(players.get('p1')!.name, 'Ali');
      expect(txns.get('t1')!.amount, 100);
    });

    test('App Lock does not touch the license activation record',
        () async {
      await HiveService.settings
          .put('license_activation_v1', 'untouched-sentinel');

      await AppLockSettings.setEnabled(true);
      await AppLockSettings.setTimeout(AutoLockTimeout.after1Minute);
      await AppLockSettings.setEnabled(false);

      expect(HiveService.settings.get('license_activation_v1'),
          'untouched-sentinel');
    });
  });
}
