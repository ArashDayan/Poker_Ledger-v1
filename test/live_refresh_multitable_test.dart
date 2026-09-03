// Phase 1 / 1.2 regression tests.
//
// These lock in the three bugs that were actually reproducible:
//   1. Transactions carried no tableId, so a per-table timeline was
//      impossible and every table showed every transaction.
//   2. Screens pushed with a Player object rendered that stale snapshot,
//      so a rename/reseat/table-move was invisible until reopening.
//   3. The cached session object could go stale after an external write.
//
// They also guard the rule that matters most: none of this may change
// the money. The settlement engine stays session-wide.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:poker_ledger/models/financial_event.dart';
import 'package:poker_ledger/models/hand.dart';
import 'package:poker_ledger/models/player.dart';
import 'package:poker_ledger/models/player_identity.dart';
import 'package:poker_ledger/models/session.dart';
import 'package:poker_ledger/models/table_participation.dart';
import 'package:poker_ledger/models/transaction.dart';
import 'package:poker_ledger/services/hive_service.dart';
import 'package:poker_ledger/services/session_service.dart';
import 'package:poker_ledger/services/table_service.dart';
import 'package:uuid/uuid.dart';
import 'test_helper.dart';

const _uuid = Uuid();
late Directory _tmp;

Future<void> _open() async {
  _tmp = await Directory.systemTemp.createTemp('pl_refresh_');
  Hive.init(_tmp.path);
  registerTestAdapters();
  await Hive.openBox<PokerSession>(HiveService.sessionsBox);
  await Hive.openBox<Player>(HiveService.playersBox);
  await Hive.openBox<LedgerTransaction>(HiveService.transactionsBox);
  await Hive.openBox(HiveService.settingsBox);
  await Hive.openBox<FinancialEvent>(HiveService.financialEventsBox);
  await Hive.openBox<Hand>(HiveService.handsBox);
  await Hive.openBox<PlayerIdentity>(HiveService.playerIdentitiesBox);
  await Hive.openBox<TableParticipation>(HiveService.participationsBox);
  await Hive.openBox(HiveService.transferEventsBox);
}

Future<void> _close() async {
  await Hive.deleteFromDisk();
  if (await _tmp.exists()) await _tmp.delete(recursive: true);
}

PokerSession _session() {
  final s = PokerSession(
    id: _uuid.v4(),
    name: 'Multi',
    location: 'Room',
    dateTime: DateTime.now(),
    smallBlind: 1,
    bigBlind: 2,
    tableNumber: '1',
  );
  HiveService.sessions.put(s.id, s);
  return s;
}

Player _p(String sid, String name, {int seat = 1, String? tableId}) {
  final p = Player(
      id: _uuid.v4(),
      sessionId: sid,
      name: name,
      seatNumber: seat,
      tableId: tableId);
  HiveService.players.put(p.id, p);
  return p;
}

/// Attaches a valid Player Master identity (J5 fixture).
Player _reg(Player p) {
  final personId = _uuid.v4();
  HiveService.playerIdentities.put(
      personId, PlayerIdentity(id: personId, displayName: p.name));
  p.personId = personId;
  p.save();
  return p;
}

Future<LedgerTransaction> _tx(String sid, String? pid, TransactionType t,
    double amt, {String? tableId}) {
  return SessionService.recordTransaction(
    sessionId: sid,
    playerId: pid,
    type: t,
    amount: amt,
    hostSignatureBase64: 'sig',
    tableId: tableId,
  );
}

void main() {
  setUp(_open);
  tearDown(_close);

  group('Transactions carry a table id', () {
    test('a player transaction is filed at that player\'s table', () async {
      final s = _session();
      await TableService.addTable(s, name: 'Table 2');
      final t1 = TableService.tablesFor(s).first.id;
      final a = _p(s.id, 'A', seat: 1, tableId: t1);
      final b = _p(s.id, 'B', seat: 1, tableId: 'table-2');

      final txA = await _tx(s.id, a.id, TransactionType.buyIn, 100);
      final txB = await _tx(s.id, b.id, TransactionType.buyIn, 200);

      expect(txA.tableId, t1);
      expect(txB.tableId, 'table-2');
    });

    test('a table-level rake row is filed at the table given', () async {
      final s = _session();
      await TableService.addTable(s, name: 'Table 2');
      final rake = await _tx(s.id, null, TransactionType.rakeCollection, 25,
          tableId: 'table-2');
      expect(rake.tableId, 'table-2');
      expect(rake.playerId, isNull);
    });

    test('filtering by table separates the two tables cleanly', () async {
      final s = _session();
      await TableService.addTable(s, name: 'Table 2');
      final t1 = TableService.tablesFor(s).first.id;
      final a = _p(s.id, 'A', seat: 1, tableId: t1);
      final b = _p(s.id, 'B', seat: 1, tableId: 'table-2');
      await _tx(s.id, a.id, TransactionType.buyIn, 100);
      await _tx(s.id, b.id, TransactionType.buyIn, 200);
      await _tx(s.id, b.id, TransactionType.rebuy, 50);

      final one = SessionService.transactionsForTable(s.id, t1,
          isFirstTable: true);
      final two = SessionService.transactionsForTable(s.id, 'table-2',
          isFirstTable: false);

      expect(one.length, 1);
      expect(two.length, 2);
      expect(one.every((t) => t.playerId == a.id), isTrue);
      expect(two.every((t) => t.playerId == b.id), isTrue);
    });

    test('legacy rows with a null tableId belong to the first table',
        () async {
      final s = _session();
      final a = _p(s.id, 'Old', seat: 1); // no tableId, like pre-upgrade data
      await _tx(s.id, a.id, TransactionType.buyIn, 300);
      await TableService.addTable(s, name: 'Table 2');
      final t1 = TableService.tablesFor(s).first.id;

      final one = SessionService.transactionsForTable(s.id, t1,
          isFirstTable: true);
      final two = SessionService.transactionsForTable(s.id, 'table-2',
          isFirstTable: false);

      expect(one.length, 1,
          reason: 'an existing session must not lose its timeline');
      expect(two, isEmpty);
    });

    test('history stays at the table where the money changed hands',
        () async {
      final s = _session();
      await TableService.addTable(s, name: 'Table 2');
      final t1 = TableService.tablesFor(s).first.id;
      final p = _reg(_p(s.id, 'Mover', seat: 1, tableId: t1));
      final before = await _tx(s.id, p.id, TransactionType.buyIn, 100);

      await TableService.movePlayer(
          s, p, 'table-2', amount: 1, hostSignatureBase64: 'sig');
      final after = await _tx(s.id, p.id, TransactionType.rebuy, 50);

      expect(before.tableId, t1,
          reason: 'rewriting history would falsify the audit trail');
      expect(after.tableId, 'table-2');
    });
  });

  group('Money is unaffected by tables', () {
    test('the balance check stays session-wide', () async {
      final s = _session();
      await TableService.addTable(s, name: 'Table 2');
      final t1 = TableService.tablesFor(s).first.id;
      final a = _p(s.id, 'A', seat: 1, tableId: t1);
      final b = _p(s.id, 'B', seat: 1, tableId: 'table-2');
      await _tx(s.id, a.id, TransactionType.buyIn, 1000);
      await _tx(s.id, b.id, TransactionType.buyIn, 1000);
      await _tx(s.id, a.id, TransactionType.cashOut, 1500);
      await _tx(s.id, b.id, TransactionType.cashOut, 500);

      final bal = SessionService.checkBalance(s.id);
      expect(bal.moneyIn, 2000);
      expect(bal.moneyOut, 2000);
      expect(bal.isBalanced, isTrue);
    });

    test('moving a player never alters their totals', () async {
      final s = _session();
      await TableService.addTable(s, name: 'Table 2');
      final t1 = TableService.tablesFor(s).first.id;
      final p = _reg(_p(s.id, 'Mover', seat: 2, tableId: t1));
      await _tx(s.id, p.id, TransactionType.buyIn, 400);
      await _tx(s.id, p.id, TransactionType.rebuy, 200);

      await TableService.movePlayer(
          s, p, 'table-2', amount: 1, hostSignatureBase64: 'sig');

      expect(SessionService.playerTotalIn(s.id, p.id), 600);
      expect(SessionService.checkBalance(s.id).moneyIn, 600);
    });
  });

  group('Live refresh — writes are observable', () {
    test('an in-place player edit fires a box event', () async {
      final s = _session();
      final p = _p(s.id, 'Before');
      final events = <BoxEvent>[];
      final sub = HiveService.players.watch().listen(events.add);

      p.name = 'After';
      p.seatNumber = 6;
      await p.save();
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();

      expect(events, isNotEmpty);
      expect(HiveService.players.get(p.id)!.name, 'After');
    });

    test('a table move fires a box event and is readable at once',
        () async {
      final s = _session();
      await TableService.addTable(s, name: 'Table 2');
      final p = _reg(_p(s.id, 'Mover', seat: 1));
      final events = <BoxEvent>[];
      final sub = HiveService.players.watch().listen(events.add);

      await TableService.movePlayer(
          s, p, 'table-2', amount: 1, hostSignatureBase64: 'sig');
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();

      expect(events, isNotEmpty);
      // The freshly read record — not the in-memory snapshot — must show
      // the new table. This is the "player page shows old table" bug.
      expect(HiveService.players.get(p.id)!.tableId, 'table-2');
    });

    test('adding a table fires a sessions event so the shell repaints',
        () async {
      final s = _session();
      final events = <BoxEvent>[];
      final sub = HiveService.sessions.watch().listen(events.add);
      await TableService.addTable(s, name: 'Table 2');
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();
      expect(events, isNotEmpty);
      expect(TableService.tablesFor(HiveService.sessions.get(s.id)!).length, 2);
    });
  });

  group('Backup round trip keeps the table id', () {
    test('a transaction survives json with its table', () async {
      final s = _session();
      await TableService.addTable(s, name: 'Table 2');
      final p = _p(s.id, 'A', seat: 1, tableId: 'table-2');
      final tx = await _tx(s.id, p.id, TransactionType.buyIn, 120);
      final restored = LedgerTransaction.fromJson(tx.toJson());
      expect(restored.tableId, 'table-2');
      expect(restored.amount, 120);
    });
  });
}
