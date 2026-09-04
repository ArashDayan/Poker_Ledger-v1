// Issue #1 regression suite — Sample 2 must be persisted by the ADD
// PLAYER path, not only by Edit Player.
//
// The bug: SessionProvider.addPlayer() had no sampleSignature2Base64
// parameter, so a Sample 2 captured in the Add Player sheet was silently
// dropped at creation. Timeline -> Verify Signature then showed Sample 1
// but an empty Sample 2, until the banker re-signed it from Edit Player
// (which calls setPlayerSampleSignature2() and therefore worked).
//
// These tests drive the real SessionProvider against a real Hive box, so
// they assert on the ACTUAL STORED RECORD rather than on UI state.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:poker_ledger/models/enums.dart';
import 'package:poker_ledger/models/player.dart';
import 'package:poker_ledger/models/player_identity.dart';
import 'package:poker_ledger/models/session.dart';
import 'package:poker_ledger/models/transaction.dart';
import 'package:poker_ledger/providers/session_provider.dart';
import 'package:poker_ledger/services/hive_service.dart';
import 'package:poker_ledger/services/session_service.dart';

import 'test_helper.dart';

late Directory _tmp;

// Stand-ins for PNG bytes. Content is irrelevant here — what matters is
// that the exact value survives every hop to storage and back.
const _sample1 = 'BASE64_SAMPLE_ONE';
const _sample2 = 'BASE64_SAMPLE_TWO';
const _sample2Updated = 'BASE64_SAMPLE_TWO_V2';
const _hostSig = 'BASE64_HOST_TRANSACTION_SIGNATURE';

Future<void> _open() async {
  _tmp = await Directory.systemTemp.createTemp('pl_sigsample_');
  Hive.init(_tmp.path);
  registerTestAdapters();
  await Hive.openBox<PokerSession>(HiveService.sessionsBox);
  await Hive.openBox<Player>(HiveService.playersBox);
  await Hive.openBox<LedgerTransaction>(HiveService.transactionsBox);
  await Hive.openBox(HiveService.settingsBox);
  await Hive.openBox<PlayerIdentity>(HiveService.playerIdentitiesBox);
}

Future<void> _close() async {
  await Hive.deleteFromDisk();
  if (await _tmp.exists()) await _tmp.delete(recursive: true);
}

/// A provider with a live session loaded, matching how the Add Player
/// sheet is always reached in the app.
Future<SessionProvider> _providerWithSession() async {
  final session = PokerSession(
    id: 'session-1',
    name: 'Friday Game',
    location: 'Home',
    dateTime: DateTime.now(),
    smallBlind: 1,
    bigBlind: 2,
    tableNumber: '1',
  );
  await HiveService.sessions.put(session.id, session);
  final provider = SessionProvider()..loadSession(session);
  return provider;
}

Future<String> _registeredPerson(String name) async {
  final id = 'sig-person-$name';
  await HiveService.playerIdentities.put(
      id, PlayerIdentity(id: id, displayName: name));
  return id;
}

/// Re-reads straight from the box, bypassing any in-memory instance —
/// this is what Timeline and Edit Player actually see.
Player _stored(String id) => HiveService.players.get(id)!;


Future<String> _j5regId(String name) async {
  final normalized = name.replaceAll(RegExp(r'[^A-Za-z0-9]'), '');
  final id = 'j5reg-$normalized';
  await HiveService.playerIdentities.put(
      id, PlayerIdentity(id: id, displayName: name));
  return id;
}

void main() {
  setUp(_open);
  tearDown(_close);

  group('1. Add Player persists both samples', () {
    test('both Sample 1 and Sample 2 reach the stored record', () async {
      final provider = await _providerWithSession();

      final player = await provider.addPlayer(
        name: 'Ali', personId: await _j5regId('Ali'),
        seatNumber: 1,
        sampleSignatureBase64: _sample1,
        sampleSignature2Base64: _sample2,
      );

      final rec = _stored(player.id);
      expect(rec.sampleSignatureBase64, _sample1);
      expect(rec.sampleSignature2Base64, _sample2,
          reason: 'Sample 2 must be persisted at creation, not only on edit');
      expect(rec.hasSampleSignature, isTrue);
      expect(rec.hasSecondSample, isTrue);
    });

    test('both capture timestamps are stamped', () async {
      final provider = await _providerWithSession();
      final player = await provider.addPlayer(
        name: 'Ali', personId: await _j5regId('Ali'),
        seatNumber: 1,
        sampleSignatureBase64: _sample1,
        sampleSignature2Base64: _sample2,
      );

      final rec = _stored(player.id);
      expect(rec.sampleSignatureAt, isNotNull);
      expect(rec.sampleSignature2At, isNotNull,
          reason: 'the banker must be able to see how current sample 2 is');
    });

    test('an unsigned Sample 2 pad stores null, never an empty string',
        () async {
      final provider = await _providerWithSession();
      final player = await provider.addPlayer(
        name: 'Ali', personId: await _j5regId('Ali'),
        seatNumber: 1,
        sampleSignatureBase64: _sample1,
        sampleSignature2Base64: '',
      );

      final rec = _stored(player.id);
      expect(rec.sampleSignature2Base64, isNull);
      expect(rec.sampleSignature2At, isNull);
      expect(rec.hasSecondSample, isFalse);
    });
  });

  group('2. Samples survive Hive persistence', () {
    test('both samples survive a close/reopen of the box', () async {
      final provider = await _providerWithSession();
      final player = await provider.addPlayer(
        name: 'Ali', personId: await _j5regId('Ali'),
        seatNumber: 1,
        sampleSignatureBase64: _sample1,
        sampleSignature2Base64: _sample2,
      );
      final id = player.id;

      // Force a real adapter round-trip through disk.
      await Hive.box<Player>(HiveService.playersBox).close();
      await Hive.openBox<Player>(HiveService.playersBox);

      final rec = _stored(id);
      expect(rec.sampleSignatureBase64, _sample1);
      expect(rec.sampleSignature2Base64, _sample2);
      expect(rec.sampleSignature2At, isNotNull);
    });

    test('both samples survive a toJson/fromJson round-trip', () async {
      final provider = await _providerWithSession();
      final player = await provider.addPlayer(
        name: 'Ali', personId: await _j5regId('Ali'),
        seatNumber: 1,
        sampleSignatureBase64: _sample1,
        sampleSignature2Base64: _sample2,
      );

      final copy = Player.fromJson(_stored(player.id).toJson());
      expect(copy.sampleSignatureBase64, _sample1);
      expect(copy.sampleSignature2Base64, _sample2);
    });
  });

  group('3. signatureSamples feeds the similarity scorer', () {
    test('contains both samples after Add Player', () async {
      final provider = await _providerWithSession();
      final player = await provider.addPlayer(
        name: 'Ali', personId: await _j5regId('Ali'),
        seatNumber: 1,
        sampleSignatureBase64: _sample1,
        sampleSignature2Base64: _sample2,
      );

      final samples = _stored(player.id).signatureSamples;
      expect(samples.length, 2);
      expect(samples, containsAll(<String>[_sample1, _sample2]));
    });

    test('contains only Sample 1 when no second sample was given',
        () async {
      final provider = await _providerWithSession();
      final player = await provider.addPlayer(
        name: 'Ali', personId: await _j5regId('Ali'),
        seatNumber: 1,
        sampleSignatureBase64: _sample1,
      );
      expect(_stored(player.id).signatureSamples, [_sample1]);
    });
  });

  group('4. Add Player WITH buy-in', () {
    test('both samples persist and the buy-in is still recorded',
        () async {
      final provider = await _providerWithSession();
      final personId = await _registeredPerson('Ali');

      final player = await provider.addPlayerWithBuyIn(
        name: 'Ali',
        seatNumber: 1,
        buyInAmount: 1000,
        hostSignatureBase64: _hostSig,
        sampleSignatureBase64: _sample1,
        sampleSignature2Base64: _sample2,
        personId: personId,
      );

      // Signatures.
      final rec = _stored(player.id);
      expect(rec.sampleSignatureBase64, _sample1);
      expect(rec.sampleSignature2Base64, _sample2);

      // Money side must be completely unaffected by this fix.
      expect(SessionService.playerTotalIn('session-1', player.id), 1000);
      expect(SessionService.totalBuyIn('session-1'), 1000);
      final txns = SessionService.transactionsFor('session-1');
      expect(txns.length, 1);
      expect(txns.single.type, TransactionType.buyIn);
      expect(txns.single.amount, 1000);
    });

    test('works with no buy-in amount (railing player)', () async {
      final provider = await _providerWithSession();
      final player = await provider.addPlayerWithBuyIn(
        name: 'Ali', personId: await _j5regId('Ali'),
        seatNumber: 1,
        buyInAmount: null,
        hostSignatureBase64: null,
        sampleSignatureBase64: _sample1,
        sampleSignature2Base64: _sample2,
      );

      expect(_stored(player.id).sampleSignature2Base64, _sample2);
      expect(SessionService.transactionsFor('session-1'), isEmpty);
    });
  });

  group('5. Backward compatibility', () {
    test('a legacy player with only Sample 1 stays valid', () async {
      // Exactly what old records look like: field 15/16 absent -> null.
      final legacy = Player(
        id: 'legacy-1',
        sessionId: 'session-1',
        name: 'Old Timer',
        seatNumber: 2,
        sampleSignatureBase64: _sample1,
        sampleSignatureAt: DateTime.now(),
      );
      await HiveService.players.put(legacy.id, legacy);

      await Hive.box<Player>(HiveService.playersBox).close();
      await Hive.openBox<Player>(HiveService.playersBox);

      final rec = _stored('legacy-1');
      expect(rec.sampleSignatureBase64, _sample1);
      expect(rec.hasSampleSignature, isTrue);
      expect(rec.hasSecondSample, isFalse);
      expect(rec.sampleSignature2Base64, isNull);
      expect(rec.signatureSamples, [_sample1]);
    });

    test('calling addPlayer without the new parameter still works',
        () async {
      // The parameter is optional, so pre-existing call sites compile and
      // behave exactly as before.
      final provider = await _providerWithSession();
      final player = await provider.addPlayer(
        name: 'Ali', personId: await _j5regId('Ali'),
        seatNumber: 1,
        sampleSignatureBase64: _sample1,
      );
      final rec = _stored(player.id);
      expect(rec.sampleSignatureBase64, _sample1);
      expect(rec.sampleSignature2Base64, isNull);
    });

    test('a legacy player can supply Sample 2 later', () async {
      final provider = await _providerWithSession();
      final player = await provider.addPlayer(
        name: 'Ali', personId: await _j5regId('Ali'),
        seatNumber: 1,
        sampleSignatureBase64: _sample1,
      );
      expect(_stored(player.id).hasSecondSample, isFalse);

      await provider.setPlayerSampleSignature2(player, _sample2);

      final rec = _stored(player.id);
      expect(rec.hasSecondSample, isTrue);
      expect(rec.sampleSignature2Base64, _sample2);
      expect(rec.sampleSignatureBase64, _sample1);
    });
  });

  group('6. Updating Sample 2 does not disturb Sample 1', () {
    test('replacing Sample 2 leaves Sample 1 byte-identical', () async {
      final provider = await _providerWithSession();
      final player = await provider.addPlayer(
        name: 'Ali', personId: await _j5regId('Ali'),
        seatNumber: 1,
        sampleSignatureBase64: _sample1,
        sampleSignature2Base64: _sample2,
      );

      await provider.setPlayerSampleSignature2(player, _sample2Updated);

      final rec = _stored(player.id);
      expect(rec.sampleSignature2Base64, _sample2Updated);
      expect(rec.sampleSignatureBase64, _sample1);
    });

    test('clearing Sample 2 leaves Sample 1 intact', () async {
      final provider = await _providerWithSession();
      final player = await provider.addPlayer(
        name: 'Ali', personId: await _j5regId('Ali'),
        seatNumber: 1,
        sampleSignatureBase64: _sample1,
        sampleSignature2Base64: _sample2,
      );

      await provider.setPlayerSampleSignature2(player, null);

      final rec = _stored(player.id);
      expect(rec.sampleSignature2Base64, isNull);
      expect(rec.sampleSignature2At, isNull);
      expect(rec.sampleSignatureBase64, _sample1);
      expect(rec.hasSampleSignature, isTrue);
    });

    test('replacing Sample 1 leaves Sample 2 intact', () async {
      final provider = await _providerWithSession();
      final player = await provider.addPlayer(
        name: 'Ali', personId: await _j5regId('Ali'),
        seatNumber: 1,
        sampleSignatureBase64: _sample1,
        sampleSignature2Base64: _sample2,
      );

      await provider.setPlayerSampleSignature(player, 'NEW_SAMPLE_ONE');

      final rec = _stored(player.id);
      expect(rec.sampleSignatureBase64, 'NEW_SAMPLE_ONE');
      expect(rec.sampleSignature2Base64, _sample2);
    });
  });

  group('7. Transaction signature stays separate', () {
    test('the host signature is stored on the transaction, not the player',
        () async {
      final provider = await _providerWithSession();
      final personId = await _registeredPerson('Ali');
      final player = await provider.addPlayerWithBuyIn(
        name: 'Ali',
        seatNumber: 1,
        buyInAmount: 500,
        hostSignatureBase64: _hostSig,
        sampleSignatureBase64: _sample1,
        sampleSignature2Base64: _sample2,
        personId: personId,
      );

      final tx = SessionService.transactionsFor('session-1').single;
      expect(tx.hostSignatureBase64, _hostSig);

      // The three signatures are three distinct values — the verify
      // dialog's three areas must never collapse into one another.
      final rec = _stored(player.id);
      expect(rec.sampleSignatureBase64, _sample1);
      expect(rec.sampleSignature2Base64, _sample2);
      expect(rec.sampleSignatureBase64, isNot(_hostSig));
      expect(rec.sampleSignature2Base64, isNot(_hostSig));
      expect(rec.sampleSignatureBase64, isNot(rec.sampleSignature2Base64));
    });
  });

  group('8. Unrelated edits never clear Sample 2', () {
    test('rename, reseat, tag change and favourite all preserve it',
        () async {
      final provider = await _providerWithSession();
      final player = await provider.addPlayer(
        name: 'Ali', personId: await _j5regId('Ali'),
        seatNumber: 1,
        sampleSignatureBase64: _sample1,
        sampleSignature2Base64: _sample2,
      );

      // Exactly what the Edit Player sheet does when signatures are
      // untouched: mutate the fields, then updatePlayer().
      player.name = 'Ali Renamed';
      player.seatNumber = 5;
      player.tags = [PlayerTag.vip];
      await provider.updatePlayer(player);
      await provider.toggleFavorite(player);

      final rec = _stored(player.id);
      expect(rec.name, 'Ali Renamed');
      expect(rec.seatNumber, 5);
      expect(rec.isFavorite, isTrue);
      expect(rec.sampleSignatureBase64, _sample1);
      expect(rec.sampleSignature2Base64, _sample2,
          reason: 'an unrelated edit must never drop a signature sample');
      expect(rec.sampleSignature2At, isNotNull);
    });

    test('recording a later transaction does not touch the samples',
        () async {
      final provider = await _providerWithSession();
      final personId = await _registeredPerson('Ali');
      final player = await provider.addPlayerWithBuyIn(
        name: 'Ali',
        seatNumber: 1,
        buyInAmount: 1000,
        hostSignatureBase64: _hostSig,
        sampleSignatureBase64: _sample1,
        sampleSignature2Base64: _sample2,
        personId: personId,
      );

      await provider.recordTransaction(
        playerId: player.id,
        type: TransactionType.rebuy,
        amount: 500,
        hostSignatureBase64: 'ANOTHER_HOST_SIG',
      );

      final rec = _stored(player.id);
      expect(rec.sampleSignatureBase64, _sample1);
      expect(rec.sampleSignature2Base64, _sample2);
      expect(SessionService.playerTotalIn('session-1', player.id), 1500);
    });
  });
}
