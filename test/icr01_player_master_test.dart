// ICR-01 — Player Master: Player Number, first/last name, optional ID,
// two specimen signatures, credit limit.
//
// Covers: additive model fields (Hive typeId 11, fields 5–11),
// numbering from 101, best-effort name split, the idempotent startup /
// post-restore backfill (migrateMasterFields), seat→identity specimen
// copy rules, and Backup v8 tolerance in both directions.
//
// No money is touched anywhere here: the identity layer never reads or
// writes sessions, transactions, chip movements or financial events.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:poker_ledger/models/player.dart';
import 'package:poker_ledger/models/player_identity.dart';
import 'package:poker_ledger/services/hive_service.dart';
import 'package:poker_ledger/services/player_identity_service.dart';

import 'test_helper.dart';

late Directory _tmp;

Future<void> _open() async {
  _tmp = await Directory.systemTemp.createTemp('pl_icr01_');
  Hive.init(_tmp.path);
  registerTestAdapters();
  await Hive.openBox<PlayerIdentity>(HiveService.playerIdentitiesBox);
  await Hive.openBox<Player>(HiveService.playersBox);
}

Future<void> _close() async {
  await Hive.deleteFromDisk();
  if (await _tmp.exists()) await _tmp.delete(recursive: true);
}

/// Writes a legacy-shaped identity exactly as a pre-ICR-01 build would
/// have: no number, no split names, no specimens, no credit limit.
Future<PlayerIdentity> _legacyIdentity({
  required String id,
  required String displayName,
  required DateTime createdAt,
  String? note,
}) async {
  final identity = PlayerIdentity(
    id: id,
    displayName: displayName,
    createdAt: createdAt,
    updatedAt: createdAt,
    note: note,
  );
  await HiveService.playerIdentities.put(id, identity);
  return identity;
}

void main() {
  setUp(_open);
  tearDown(_close);

  group('Player Number assignment', () {
    test('first identity gets 101, second gets 102', () async {
      final a = await PlayerIdentityService.createNew('Ali Ahmadi');
      final b = await PlayerIdentityService.createNew('Reza Karimi');
      expect(a, isNotNull);
      expect(b, isNotNull);
      expect(a!.playerNumber, 101);
      expect(b!.playerNumber, 102);
      expect(a.id, isNot(b.id));
    });

    test('nextPlayerNumber is max+1 — gaps are never recycled', () async {
      await _legacyIdentity(
          id: 'x1', displayName: 'Old Timer', createdAt: DateTime(2024));
      final seeded = HiveService.playerIdentities.get('x1')!;
      seeded.playerNumber = 150;
      await seeded.save();
      expect(PlayerIdentityService.nextPlayerNumber(), 151);
      final c = await PlayerIdentityService.createNew('New Guy');
      expect(c!.playerNumber, 151);
    });

    test('nextPlayerNumber on an empty box is 101', () {
      expect(PlayerIdentityService.nextPlayerNumber(), 101);
    });

    test('createNew still refuses a blank name and writes nothing',
        () async {
      expect(await PlayerIdentityService.createNew('   '), isNull);
      expect(HiveService.playerIdentities.length, 0);
    });
  });

  group('createNew splits names but preserves displayName', () {
    test('two-word name splits first/last', () async {
      final i = await PlayerIdentityService.createNew('Ali Ahmadi');
      expect(i!.firstName, 'Ali');
      expect(i.lastName, 'Ahmadi');
      expect(i.displayName, 'Ali Ahmadi');
    });

    test('three-word name keeps remainder as family name', () async {
      final i = await PlayerIdentityService.createNew('Ali Reza Ahmadi');
      expect(i!.firstName, 'Ali');
      expect(i.lastName, 'Reza Ahmadi');
    });

    test('single word is a given name with no family name', () async {
      final i = await PlayerIdentityService.createNew('Madonna');
      expect(i!.firstName, 'Madonna');
      expect(i.lastName, '');
    });

    test('FA display name splits on whitespace identically', () async {
      final i = await PlayerIdentityService.createNew('علی رضایی');
      expect(i!.firstName, 'علی');
      expect(i.lastName, 'رضایی');
    });
  });

  group('migrateMasterFields — numbering', () {
    test('assigns 101+ deterministically by createdAt, then id', () async {
      await _legacyIdentity(
          id: 'mmm', displayName: 'Middle', createdAt: DateTime(2024, 6));
      await _legacyIdentity(
          id: 'aaa', displayName: 'Oldest', createdAt: DateTime(2024, 1));
      // Same createdAt as 'mmm' → id breaks the tie ('bbb' < 'mmm').
      await _legacyIdentity(
          id: 'bbb', displayName: 'Tied', createdAt: DateTime(2024, 6));

      final changed = await PlayerIdentityService.migrateMasterFields();
      expect(changed, 3);

      expect(HiveService.playerIdentities.get('aaa')!.playerNumber, 101);
      expect(HiveService.playerIdentities.get('bbb')!.playerNumber, 102);
      expect(HiveService.playerIdentities.get('mmm')!.playerNumber, 103);
    });

    test('existing unique numbers are kept; ids never change', () async {
      await _legacyIdentity(
          id: 'keep', displayName: 'Has One', createdAt: DateTime(2024, 1));
      await _legacyIdentity(
          id: 'need', displayName: 'Needs One', createdAt: DateTime(2024, 2));
      HiveService.playerIdentities.get('keep')!.playerNumber = 140;
      await HiveService.playerIdentities.get('keep')!.save();

      await PlayerIdentityService.migrateMasterFields();

      expect(HiveService.playerIdentities.get('keep')!.playerNumber, 140);
      expect(HiveService.playerIdentities.get('need')!.playerNumber, 141);
    });

    test('duplicate numbers are healed: earlier identity keeps it',
        () async {
      await _legacyIdentity(
          id: 'early', displayName: 'Early', createdAt: DateTime(2024, 1));
      await _legacyIdentity(
          id: 'late', displayName: 'Late', createdAt: DateTime(2024, 2));
      for (final id in ['early', 'late']) {
        HiveService.playerIdentities.get(id)!.playerNumber = 101;
        await HiveService.playerIdentities.get(id)!.save();
      }

      await PlayerIdentityService.migrateMasterFields();

      expect(HiveService.playerIdentities.get('early')!.playerNumber, 101);
      expect(HiveService.playerIdentities.get('late')!.playerNumber, 102);
    });

    test('migration never bumps updatedAt (backfill ≠ banker edit)',
        () async {
      final stamp = DateTime(2024, 3, 15, 20);
      await _legacyIdentity(
          id: 'ts', displayName: 'Stamp Test', createdAt: stamp);
      await PlayerIdentityService.migrateMasterFields();
      expect(HiveService.playerIdentities.get('ts')!.updatedAt, stamp);
    });
  });

  group('migrateMasterFields — names', () {
    test('splits only when BOTH first and last are empty', () async {
      await _legacyIdentity(
          id: 'both-empty',
          displayName: 'Ali Ahmadi',
          createdAt: DateTime(2024));
      await _legacyIdentity(
          id: 'first-set',
          displayName: 'Ali Ahmadi',
          createdAt: DateTime(2024, 2));
      HiveService.playerIdentities.get('first-set')!.firstName = 'Alireza';
      await HiveService.playerIdentities.get('first-set')!.save();

      await PlayerIdentityService.migrateMasterFields();

      final split = HiveService.playerIdentities.get('both-empty')!;
      expect(split.firstName, 'Ali');
      expect(split.lastName, 'Ahmadi');

      final corrected = HiveService.playerIdentities.get('first-set')!;
      expect(corrected.firstName, 'Alireza'); // banker edit preserved
      expect(corrected.lastName, ''); // NOT filled by the split
    });
  });

  group('migrateMasterFields — specimens', () {
    Future<Player> _seat({
      required String id,
      required String personId,
      required DateTime joinedAt,
      String? s1,
      String? s2,
    }) async {
      final seat = Player(
        id: id,
        sessionId: 'session-x',
        name: 'Seat Row',
        seatNumber: 1,
        joinedAt: joinedAt,
        personId: personId,
        sampleSignatureBase64: s1,
        sampleSignature2Base64: s2,
      );
      await HiveService.players.put(id, seat);
      return seat;
    }

    test('empty identity inherits specimens from the oldest linked seat',
        () async {
      await _legacyIdentity(
          id: 'p1', displayName: 'Sig Person', createdAt: DateTime(2023));
      await _seat(
          id: 'seat-new',
          personId: 'p1',
          joinedAt: DateTime(2024, 5),
          s1: 'c2lnLW5ldy0x',
          s2: 'c2lnLW5ldy0y');
      await _seat(
          id: 'seat-old',
          personId: 'p1',
          joinedAt: DateTime(2024, 1),
          s1: 'c2lnLW9sZC0x',
          s2: 'c2lnLW9sZC0y');

      await PlayerIdentityService.migrateMasterFields();

      final identity = HiveService.playerIdentities.get('p1')!;
      expect(identity.sampleSignatureBase64, 'c2lnLW9sZC0x');
      expect(identity.sampleSignature2Base64, 'c2lnLW9sZC0y');
    });

    test('seat specimens are never deleted by the copy', () async {
      await _legacyIdentity(
          id: 'p2', displayName: 'Keep Seats', createdAt: DateTime(2023));
      await _seat(
          id: 'seat-k',
          personId: 'p2',
          joinedAt: DateTime(2024),
          s1: 'c2lnYTE=',
          s2: 'c2lnYTI=');

      await PlayerIdentityService.migrateMasterFields();

      final seat = HiveService.players.get('seat-k')!;
      expect(seat.sampleSignatureBase64, 'c2lnYTE=');
      expect(seat.sampleSignature2Base64, 'c2lnYTI=');
    });

    test('an existing identity specimen is never overwritten; only empty '
        'slots are filled', () async {
      await _legacyIdentity(
          id: 'p3', displayName: 'Has One', createdAt: DateTime(2023));
      final identity = HiveService.playerIdentities.get('p3')!;
      identity.sampleSignatureBase64 = 'b3duLXNeZw==';
      await identity.save();
      await _seat(
          id: 'seat-h',
          personId: 'p3',
          joinedAt: DateTime(2024),
          s1: 'c2VhdC0x',
          s2: 'c2VhdC0y');

      await PlayerIdentityService.migrateMasterFields();

      final after = HiveService.playerIdentities.get('p3')!;
      expect(after.sampleSignatureBase64, 'b3duLXNeZw=='); // untouched
      expect(after.sampleSignature2Base64, 'c2VhdC0y'); // filled
    });

    test('identity with no linked seats keeps empty specimens', () async {
      await _legacyIdentity(
          id: 'p4', displayName: 'No Seats', createdAt: DateTime(2023));
      await PlayerIdentityService.migrateMasterFields();
      final identity = HiveService.playerIdentities.get('p4')!;
      expect(identity.sampleSignatureBase64, isNull);
      expect(identity.sampleSignature2Base64, isNull);
    });
  });

  group('idempotency', () {
    test('a second migration run changes nothing', () async {
      await _legacyIdentity(
          id: 'i1', displayName: 'First Person', createdAt: DateTime(2024));
      await _legacyIdentity(
          id: 'i2', displayName: 'Second Person', createdAt: DateTime(2024, 2));
      await _seatlessSpecimenSeeds();
      expect(await PlayerIdentityService.migrateMasterFields(), 2);
      expect(await PlayerIdentityService.migrateMasterFields(), 0);
    });
  });

  group('Backup v8 tolerance', () {
    test('legacy JSON (pre-ICR-01 keys only) decodes with defaults', () {
      final identity = PlayerIdentity.fromJson(const {
        'id': 'legacy-1',
        'displayName': 'Old Backup',
        'createdAt': '2024-01-01T00:00:00.000',
        'updatedAt': '2024-01-01T00:00:00.000',
        'note': null,
      });
      expect(identity.playerNumber, 0);
      expect(identity.hasPlayerNumber, isFalse);
      expect(identity.firstName, '');
      expect(identity.lastName, '');
      expect(identity.idNumber, isNull);
      expect(identity.sampleSignatureBase64, isNull);
      expect(identity.sampleSignature2Base64, isNull);
      expect(identity.creditLimitMinor, 0);
    });

    test('toJson emits the new keys; round-trip preserves them', () async {
      final created = await PlayerIdentityService.createNew('Ali Ahmadi',
          note: 'regular');
      created!.idNumber = 'ID-7788';
      created.creditLimitMinor = 500000;
      created.sampleSignatureBase64 = 'c3BlYzE=';
      await created.save();

      final json = created.toJson();
      for (final key in [
        'playerNumber',
        'firstName',
        'lastName',
        'idNumber',
        'sampleSignatureBase64',
        'sampleSignature2Base64',
        'creditLimitMinor',
      ]) {
        expect(json.containsKey(key), isTrue, reason: 'missing key $key');
      }

      final back = PlayerIdentity.fromJson(json);
      expect(back.playerNumber, 101);
      expect(back.firstName, 'Ali');
      expect(back.lastName, 'Ahmadi');
      expect(back.idNumber, 'ID-7788');
      expect(back.sampleSignatureBase64, 'c3BlYzE=');
      expect(back.creditLimitMinor, 500000);
    });
  });

  group('Hive adapter round-trip (typeId 11, fields 5–11)', () {
    test('put/get preserves every ICR-01 field', () async {
      final identity = PlayerIdentity(
        id: 'rt-1',
        displayName: 'Round Trip',
        playerNumber: 177,
        firstName: 'Round',
        lastName: 'Trip',
        idNumber: 'PP-123',
        sampleSignatureBase64: 'YTE=',
        sampleSignature2Base64: 'YTI=',
        creditLimitMinor: 123456789,
      );
      await HiveService.playerIdentities.put(identity.id, identity);
      final read = HiveService.playerIdentities.get('rt-1')!;
      expect(read.playerNumber, 177);
      expect(read.firstName, 'Round');
      expect(read.lastName, 'Trip');
      expect(read.idNumber, 'PP-123');
      expect(read.sampleSignatureBase64, 'YTE=');
      expect(read.sampleSignature2Base64, 'YTI=');
      expect(read.creditLimitMinor, 123456789);
    });

    test('null optionals survive a round-trip', () async {
      await HiveService.playerIdentities.put(
          'rt-2', PlayerIdentity(id: 'rt-2', displayName: 'Bare'));
      final read = HiveService.playerIdentities.get('rt-2')!;
      expect(read.idNumber, isNull);
      expect(read.sampleSignatureBase64, isNull);
      expect(read.sampleSignature2Base64, isNull);
      expect(read.playerNumber, 0);
      expect(read.creditLimitMinor, 0);
    });
  });
}

/// Helper so the idempotency test has a seat with specimens to copy.
Future<void> _seatlessSpecimenSeeds() async {
  final seat = Player(
    id: 'idem-seat',
    sessionId: 'session-x',
    name: 'First Person',
    seatNumber: 2,
    personId: 'i1',
    sampleSignatureBase64: 'aWRlbQ==',
  );
  await HiveService.players.put(seat.id, seat);
}
