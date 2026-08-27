// Issue #3A — a player added from a specific table must be STORED with
// that table's id.
//
// The bug: addPlayer() inferred the destination from `isMultiTable`,
// which reads false whenever `session.tables` has never been
// materialised (tablesFor() synthesises a single table without
// persisting it). The player was then written with tableId == null, and
// a null tableId is only ever visible on the FIRST table — so the player
// silently vanished from the table the banker was standing at. The
// notification worked fine; the stored data was wrong.
//
// These tests assert on the STORED record and on what playersAt()
// actually returns, which is what the seat grid renders from.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:poker_ledger/models/enums.dart';
import 'package:poker_ledger/models/financial_event.dart';
import 'package:poker_ledger/models/hand.dart';
import 'package:poker_ledger/models/player.dart';
import 'package:poker_ledger/models/session.dart';
import 'package:poker_ledger/models/transaction.dart';
import 'package:poker_ledger/providers/session_provider.dart';
import 'package:poker_ledger/services/hive_service.dart';
import 'package:poker_ledger/services/session_service.dart';
import 'package:poker_ledger/services/table_service.dart';

import 'test_helper.dart';

late Directory _tmp;

const _sample1 = 'BASE64_SAMPLE_ONE';
const _sample2 = 'BASE64_SAMPLE_TWO';
const _hostSig = 'BASE64_HOST_SIG';

Future<void> _open() async {
  _tmp = await Directory.systemTemp.createTemp('pl_addplayer_table_');
  Hive.init(_tmp.path);
  registerTestAdapters();
  await Hive.openBox<PokerSession>(HiveService.sessionsBox);
  await Hive.openBox<Player>(HiveService.playersBox);
  await Hive.openBox<LedgerTransaction>(HiveService.transactionsBox);
  await Hive.openBox(HiveService.settingsBox);
  await Hive.openBox<FinancialEvent>(HiveService.financialEventsBox);
  await Hive.openBox<Hand>(HiveService.handsBox);
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

PokerSession get _live => HiveService.sessions.get('session-1')!;
Player _stored(String id) => HiveService.players.get(id)!;

void main() {
  setUp(_open);
  tearDown(_close);

  group('1-2. explicit table assignment', () {
    test('adding from Table 1 stores table 1\'s id', () async {
      final provider = await _provider();
      await provider.addTable(name: 'Table 2');
      final ids = TableService.tablesFor(_live).map((t) => t.id).toList();

      final player = await provider.addPlayer(
        name: 'Ali',
        seatNumber: 1,
        tableId: ids[0],
      );

      expect(_stored(player.id).tableId, ids[0]);
    });

    test('adding from Table 2 stores table 2\'s id', () async {
      final provider = await _provider();
      await provider.addTable(name: 'Table 2');
      final ids = TableService.tablesFor(_live).map((t) => t.id).toList();

      final player = await provider.addPlayer(
        name: 'Sara',
        seatNumber: 3,
        tableId: ids[1],
      );

      expect(_stored(player.id).tableId, ids[1]);
      expect(_stored(player.id).tableId, isNot(ids[0]));
    });

    test('THE BUG CASE: explicit id wins even before materialise',
        () async {
      // A session whose `tables` list has never been written. Previously
      // isMultiTable read false here and the player got a null tableId.
      final provider = await _provider();
      expect(_live.tables == null || _live.tables!.isEmpty, isTrue,
          reason: 'precondition: tables not yet materialised');

      final player = await provider.addPlayer(
        name: 'Nima',
        seatNumber: 5,
        tableId: 'table-2',
      );

      expect(_stored(player.id).tableId, 'table-2');
      expect(_stored(player.id).tableId, isNotNull);
    });

    test('the player is visible on the table it was added to', () async {
      final provider = await _provider();
      await provider.addTable(name: 'Table 2');
      final ids = TableService.tablesFor(_live).map((t) => t.id).toList();

      final player = await provider.addPlayer(
        name: 'Sara',
        seatNumber: 3,
        tableId: ids[1],
      );

      // This is exactly what the seat grid renders from.
      final onT1 = TableService.playersAt(_live, ids[0]);
      final onT2 = TableService.playersAt(_live, ids[1]);

      expect(onT2.map((p) => p.id), contains(player.id));
      expect(onT1.map((p) => p.id), isNot(contains(player.id)),
          reason: 'must not leak onto the first table');
    });
  });

  group('3. add with buy-in', () {
    test('correct tableId AND the buy-in transaction is intact', () async {
      final provider = await _provider();
      await provider.addTable(name: 'Table 2');
      final ids = TableService.tablesFor(_live).map((t) => t.id).toList();

      final player = await provider.addPlayerWithBuyIn(
        name: 'Sara',
        seatNumber: 4,
        buyInAmount: 1000,
        hostSignatureBase64: _hostSig,
        tableId: ids[1],
      );

      expect(_stored(player.id).tableId, ids[1]);

      // Money side untouched by this fix.
      expect(SessionService.playerTotalIn('session-1', player.id), 1000);
      expect(SessionService.totalBuyIn('session-1'), 1000);
      final txns = SessionService.transactionsFor('session-1');
      expect(txns.length, 1);
      expect(txns.single.type, TransactionType.buyIn);
      expect(txns.single.amount, 1000);
      expect(txns.single.hostSignatureBase64, _hostSig);
    });
  });

  group('4. signature samples still persist (Issue #1 preserved)', () {
    test('both samples survive alongside the explicit tableId', () async {
      final provider = await _provider();
      await provider.addTable(name: 'Table 2');
      final ids = TableService.tablesFor(_live).map((t) => t.id).toList();

      final player = await provider.addPlayerWithBuyIn(
        name: 'Ali',
        seatNumber: 2,
        buyInAmount: 500,
        hostSignatureBase64: _hostSig,
        sampleSignatureBase64: _sample1,
        sampleSignature2Base64: _sample2,
        tableId: ids[1],
      );

      final rec = _stored(player.id);
      expect(rec.tableId, ids[1]);
      expect(rec.sampleSignatureBase64, _sample1);
      expect(rec.sampleSignature2Base64, _sample2);
      expect(rec.sampleSignature2At, isNotNull);
      expect(rec.signatureSamples.length, 2);
    });
  });

  group('5. single-table sessions unchanged', () {
    test('no explicit id in a single-table session still stores null',
        () async {
      final provider = await _provider();

      final player = await provider.addPlayer(name: 'Ali', seatNumber: 1);

      // Legacy shape preserved — null means "the one and only table".
      expect(_stored(player.id).tableId, isNull);
      // And the player is still visible where they should be.
      final onFirst =
          TableService.playersAt(_live, TableService.tablesFor(_live).first.id);
      expect(onFirst.map((p) => p.id), contains(player.id));
    });

    test('a null-tableId legacy player remains visible after a 2nd table',
        () async {
      final provider = await _provider();
      final legacy = await provider.addPlayer(name: 'Old', seatNumber: 1);
      expect(_stored(legacy.id).tableId, isNull);

      await provider.addTable(name: 'Table 2');
      final ids = TableService.tablesFor(_live).map((t) => t.id).toList();

      // Still on the first table, exactly as before — not migrated.
      expect(_stored(legacy.id).tableId, isNull);
      expect(TableService.playersAt(_live, ids[0]).map((p) => p.id),
          contains(legacy.id));
    });

    test('multi-table with NO explicit id infers the active table',
        () async {
      final provider = await _provider();
      await provider.addTable(name: 'Table 2'); // makes table 2 active
      final ids = TableService.tablesFor(_live).map((t) => t.id).toList();
      provider.setActiveTable(ids[1]);

      final player = await provider.addPlayer(name: 'Sara', seatNumber: 2);

      expect(_stored(player.id).tableId, ids[1]);
    });
  });

  group('6. seat assignment preserved', () {
    test('the requested seat number is stored verbatim', () async {
      final provider = await _provider();
      await provider.addTable(name: 'Table 2');
      final ids = TableService.tablesFor(_live).map((t) => t.id).toList();

      for (final seat in [1, 4, 9]) {
        final p = await provider.addPlayer(
          name: 'P$seat',
          seatNumber: seat,
          tableId: ids[1],
        );
        expect(_stored(p.id).seatNumber, seat);
        expect(_stored(p.id).tableId, ids[1]);
      }
    });

    test('the same seat number can be used on two different tables',
        () async {
      final provider = await _provider();
      await provider.addTable(name: 'Table 2');
      final ids = TableService.tablesFor(_live).map((t) => t.id).toList();

      final a = await provider.addPlayer(
          name: 'A', seatNumber: 1, tableId: ids[0]);
      final b = await provider.addPlayer(
          name: 'B', seatNumber: 1, tableId: ids[1]);

      expect(TableService.playersAt(_live, ids[0]).map((p) => p.id), [a.id]);
      expect(TableService.playersAt(_live, ids[1]).map((p) => p.id), [b.id]);
    });
  });

  group('7. existing players are never modified', () {
    test('adding a new player does not touch earlier records', () async {
      final provider = await _provider();
      await provider.addTable(name: 'Table 2');
      final ids = TableService.tablesFor(_live).map((t) => t.id).toList();

      final first = await provider.addPlayer(
        name: 'First',
        seatNumber: 1,
        sampleSignatureBase64: _sample1,
        sampleSignature2Base64: _sample2,
        tableId: ids[0],
      );
      final beforeTable = _stored(first.id).tableId;
      final beforeSeat = _stored(first.id).seatNumber;
      final beforeS1 = _stored(first.id).sampleSignatureBase64;
      final beforeS2 = _stored(first.id).sampleSignature2Base64;

      await provider.addPlayer(
          name: 'Second', seatNumber: 2, tableId: ids[1]);

      final after = _stored(first.id);
      expect(after.tableId, beforeTable);
      expect(after.seatNumber, beforeSeat);
      expect(after.sampleSignatureBase64, beforeS1);
      expect(after.sampleSignature2Base64, beforeS2);
      expect(after.name, 'First');
    });

    test('materialise does not rewrite any player record', () async {
      final provider = await _provider();
      // Created while tables were unmaterialised -> null tableId.
      final legacy = await provider.addPlayer(name: 'Legacy', seatNumber: 1);
      expect(_stored(legacy.id).tableId, isNull);

      // A later add triggers materialise; the old record must be left
      // exactly as it was — no automatic repair, by requirement.
      await provider.addPlayer(name: 'New', seatNumber: 2);

      expect(_stored(legacy.id).tableId, isNull,
          reason: 'existing players must not be migrated');
    });
  });

  group('persistence', () {
    test('the assigned tableId survives a reload', () async {
      final provider = await _provider();
      await provider.addTable(name: 'Table 2');
      final ids = TableService.tablesFor(_live).map((t) => t.id).toList();
      final player = await provider.addPlayer(
          name: 'Sara', seatNumber: 3, tableId: ids[1]);

      await Hive.box<Player>(HiveService.playersBox).close();
      await Hive.openBox<Player>(HiveService.playersBox);

      expect(_stored(player.id).tableId, ids[1]);
    });

    test('addPlayer materialises the table list', () async {
      final provider = await _provider();
      expect(_live.tables == null || _live.tables!.isEmpty, isTrue);

      await provider.addPlayer(name: 'Ali', seatNumber: 1);

      expect(_live.tables, isNotNull);
      expect(_live.tables!.isNotEmpty, isTrue,
          reason: 'tables must be persisted so later adds infer correctly');
    });
  });
}
