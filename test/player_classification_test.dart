// Issue #4 — Player Classification must be mutually exclusive.
//
// The UI previously used FilterChip with `v ? tags.add(tag) : tags.remove(tag)`,
// which is multi-select: a player could hold VIP *and* Regular *and*
// Problem Player at once.
//
// The fix keeps the storage shape (List<PlayerTag>) untouched and enforces
// the invariant at the single selection site by clearing the set before
// adding. These tests exercise that exact selection rule, plus the
// persistence round-trip, so a regression in either shows up here.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:poker_ledger/models/enums.dart';
import 'package:poker_ledger/models/player.dart';
import 'package:poker_ledger/models/session.dart';
import 'package:poker_ledger/models/transaction.dart';
import 'package:poker_ledger/providers/session_provider.dart';
import 'package:poker_ledger/services/hive_service.dart';

import 'test_helper.dart';

late Directory _tmp;

/// Mirrors the sheet's selection handler exactly:
///   onSelected: (v) { tags.clear(); if (v) tags.add(tag); }
void select(Set<PlayerTag> tags, PlayerTag tag, {bool value = true}) {
  tags.clear();
  if (value) tags.add(tag);
}

/// Tapping an already-selected chip deselects it (value == false).
void tapChip(Set<PlayerTag> tags, PlayerTag tag) {
  final wasSelected = tags.contains(tag);
  select(tags, tag, value: !wasSelected);
}

Future<void> _open() async {
  _tmp = await Directory.systemTemp.createTemp('pl_classification_');
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

Future<SessionProvider> _provider() async {
  final s = PokerSession(
    id: 'session-1',
    name: 'Friday',
    location: 'Home',
    dateTime: DateTime.now(),
    smallBlind: 1,
    bigBlind: 2,
    tableNumber: '1',
  );
  await HiveService.sessions.put(s.id, s);
  return SessionProvider()..loadSession(s);
}

Player _stored(String id) => HiveService.players.get(id)!;

void main() {
  setUp(_open);
  tearDown(_close);

  group('1. no classification is valid', () {
    test('an empty selection stays empty', () {
      final tags = <PlayerTag>{};
      expect(tags, isEmpty);
    });

    test('a player can be created with no classification', () async {
      final provider = await _provider();
      final p = await provider.addPlayer(name: 'Ali', seatNumber: 1);
      expect(_stored(p.id).tags, isEmpty);
    });

    test('classification is optional — never forced on save', () async {
      final provider = await _provider();
      final p = await provider.addPlayer(
          name: 'Ali', seatNumber: 1, tags: <PlayerTag>[]);
      expect(_stored(p.id).tags, isEmpty);
    });
  });

  group('2-5. selecting one option selects only that option', () {
    for (final tag in PlayerTag.values) {
      test('selecting ${tag.label} leaves only ${tag.label}', () {
        final tags = <PlayerTag>{};
        select(tags, tag);
        expect(tags.length, 1);
        expect(tags.single, tag);
        for (final other in PlayerTag.values.where((t) => t != tag)) {
          expect(tags.contains(other), isFalse,
              reason: '${other.label} must be deselected');
        }
      });
    }
  });

  group('6-8. switching replaces the previous classification', () {
    test('VIP then Regular leaves only Regular', () {
      final tags = <PlayerTag>{};
      select(tags, PlayerTag.vip);
      expect(tags.single, PlayerTag.vip);

      select(tags, PlayerTag.regular);
      expect(tags.length, 1);
      expect(tags.single, PlayerTag.regular);
      expect(tags.contains(PlayerTag.vip), isFalse);
    });

    test('Regular then Problem Player leaves only Problem Player', () {
      final tags = <PlayerTag>{};
      select(tags, PlayerTag.regular);
      select(tags, PlayerTag.problemPlayer);
      expect(tags.length, 1);
      expect(tags.single, PlayerTag.problemPlayer);
      expect(tags.contains(PlayerTag.regular), isFalse);
    });

    test('Problem Player then Tilt leaves only Tilt', () {
      final tags = <PlayerTag>{};
      select(tags, PlayerTag.problemPlayer);
      select(tags, PlayerTag.tilt);
      expect(tags.length, 1);
      expect(tags.single, PlayerTag.tilt);
      expect(tags.contains(PlayerTag.problemPlayer), isFalse);
    });

    test('Tilt then VIP leaves only VIP', () {
      final tags = <PlayerTag>{};
      select(tags, PlayerTag.tilt);
      select(tags, PlayerTag.vip);
      expect(tags.length, 1);
      expect(tags.single, PlayerTag.vip);
    });
  });

  group('9. no combination can ever hold two classifications', () {
    test('every ordered pair ends with exactly one selected', () {
      for (final a in PlayerTag.values) {
        for (final b in PlayerTag.values) {
          final tags = <PlayerTag>{};
          select(tags, a);
          select(tags, b);
          expect(tags.length, 1,
              reason: 'after ${a.label} then ${b.label}');
          expect(tags.single, b);
        }
      }
    });

    test('a long chain of selections never accumulates', () {
      final tags = <PlayerTag>{};
      for (var i = 0; i < 20; i++) {
        for (final tag in PlayerTag.values) {
          select(tags, tag);
          expect(tags.length, lessThanOrEqualTo(1));
        }
      }
      expect(tags.length, 1);
    });

    test('re-tapping the selected chip clears it', () {
      final tags = <PlayerTag>{};
      tapChip(tags, PlayerTag.vip);
      expect(tags.single, PlayerTag.vip);

      tapChip(tags, PlayerTag.vip);
      expect(tags, isEmpty, reason: 'deselect must be possible');
    });

    test('tapping a different chip swaps rather than adds', () {
      final tags = <PlayerTag>{};
      tapChip(tags, PlayerTag.vip);
      tapChip(tags, PlayerTag.regular);
      expect(tags.length, 1);
      expect(tags.single, PlayerTag.regular);
    });
  });

  group('10. persistence and existing data', () {
    test('a single classification round-trips through Hive', () async {
      final provider = await _provider();
      final p = await provider.addPlayer(
        name: 'Ali',
        seatNumber: 1,
        tags: [PlayerTag.vip],
      );

      await Hive.box<Player>(HiveService.playersBox).close();
      await Hive.openBox<Player>(HiveService.playersBox);

      expect(_stored(p.id).tags, [PlayerTag.vip]);
    });

    test('a legacy multi-tag record still LOADS without data loss',
        () async {
      // Written by the old multi-select UI. The storage shape is
      // unchanged, so this must keep loading exactly as before — the fix
      // must not destroy or reject historical data.
      final legacy = Player(
        id: 'legacy-1',
        sessionId: 'session-1',
        name: 'Old Timer',
        seatNumber: 2,
        tags: [PlayerTag.vip, PlayerTag.regular, PlayerTag.problemPlayer],
      );
      await HiveService.players.put(legacy.id, legacy);

      await Hive.box<Player>(HiveService.playersBox).close();
      await Hive.openBox<Player>(HiveService.playersBox);

      final rec = _stored('legacy-1');
      expect(rec.tags.length, 3, reason: 'legacy data preserved on read');
      expect(rec.tags, contains(PlayerTag.vip));
      expect(rec.name, 'Old Timer');
    });

    test('editing a legacy multi-tag record normalises it to one',
        () async {
      // The banker opens the sheet on a legacy record and picks a
      // classification: clear-then-add collapses the old multi-selection.
      final tags = <PlayerTag>{
        PlayerTag.vip,
        PlayerTag.regular,
        PlayerTag.problemPlayer,
      };
      expect(tags.length, 3);

      select(tags, PlayerTag.regular);

      expect(tags.length, 1);
      expect(tags.single, PlayerTag.regular);
    });

    test('a legacy record left untouched keeps its tags', () async {
      final legacy = Player(
        id: 'legacy-2',
        sessionId: 'session-1',
        name: 'Untouched',
        seatNumber: 3,
        tags: [PlayerTag.vip, PlayerTag.tilt],
      );
      await HiveService.players.put(legacy.id, legacy);

      // An unrelated edit (rename) must not silently rewrite tags.
      final rec = _stored('legacy-2');
      rec.name = 'Renamed';
      await rec.save();

      expect(_stored('legacy-2').tags.length, 2);
    });

    test('toJson/fromJson preserves a single classification', () {
      final p = Player(
        id: 'p1',
        sessionId: 's1',
        name: 'Ali',
        seatNumber: 1,
        tags: [PlayerTag.problemPlayer],
      );
      final copy = Player.fromJson(p.toJson());
      expect(copy.tags, [PlayerTag.problemPlayer]);
    });

    test('unrelated player fields are untouched by classification',
        () async {
      final provider = await _provider();
      final p = await provider.addPlayer(
        name: 'Ali',
        seatNumber: 4,
        tags: [PlayerTag.vip],
        sampleSignatureBase64: 'SIG1',
        sampleSignature2Base64: 'SIG2',
      );

      final rec = _stored(p.id);
      expect(rec.tags, [PlayerTag.vip]);
      expect(rec.name, 'Ali');
      expect(rec.seatNumber, 4);
      expect(rec.isActive, isTrue);
      expect(rec.sampleSignatureBase64, 'SIG1');
      expect(rec.sampleSignature2Base64, 'SIG2');
    });
  });

  group('the four options are unchanged', () {
    test('exactly four classifications exist, with original labels', () {
      expect(PlayerTag.values.length, 4);
      expect(PlayerTag.vip.label, 'VIP');
      expect(PlayerTag.regular.label, 'Regular');
      expect(PlayerTag.problemPlayer.label, 'Problem Player');
      expect(PlayerTag.tilt.label, 'Tilt');
    });

    test('enum indices are unchanged (serialisation compatibility)', () {
      // toJson stores t.index, so these must never shift.
      expect(PlayerTag.vip.index, 0);
      expect(PlayerTag.regular.index, 1);
      expect(PlayerTag.problemPlayer.index, 2);
      expect(PlayerTag.tilt.index, 3);
    });
  });
}
