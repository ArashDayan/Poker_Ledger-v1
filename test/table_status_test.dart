// Independent per-table status.
//
// The rule these lock in: closing a table is a TABLE lifecycle event and
// must never end the session. Only the banker ending the session does
// that. Everything else here protects money that is still on a table.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:poker_ledger/models/player.dart';
import 'package:poker_ledger/models/session.dart';
import 'package:poker_ledger/models/transaction.dart';
import 'package:poker_ledger/services/hive_service.dart';
import 'package:poker_ledger/services/session_service.dart';
import 'package:poker_ledger/services/table_service.dart';
import 'package:uuid/uuid.dart';
import 'test_helper.dart';

const _uuid = Uuid();
late Directory _tmp;

Future<void> _open() async {
  _tmp = await Directory.systemTemp.createTemp('pl_tablestatus_');
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

PokerSession _session() {
  final s = PokerSession(
    id: _uuid.v4(),
    name: 'Floor',
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
      id: _uuid.v4(), sessionId: sid, name: name, seatNumber: seat,
      tableId: tableId);
  HiveService.players.put(p.id, p);
  return p;
}

Future<void> _tx(String sid, String pid, TransactionType t, double amt) =>
    SessionService.recordTransaction(
      sessionId: sid, playerId: pid, type: t, amount: amt,
      hostSignatureBase64: 'sig');

void main() {
  setUp(_open);
  tearDown(_close);

  group('Closing a table never closes the session', () {
    test('session stays active after a table is closed', () async {
      final s = _session();
      await TableService.addTable(s, name: 'Table 2');
      await TableService.closeTable(s, 'table-2');

      expect(TableService.tableById(s, 'table-2').status,
          TableStatus.closed);
      expect(HiveService.sessions.get(s.id)!.status, SessionStatus.active,
          reason: 'closing a table must not end the session');
    });

    test('session survives even when EVERY table is closed', () async {
      final s = _session();
      await TableService.addTable(s, name: 'Table 2');
      final t1 = TableService.tablesFor(s).first.id;
      await TableService.closeTable(s, t1);
      await TableService.closeTable(s, 'table-2');

      expect(TableService.hasOpenTable(s), isFalse);
      expect(HiveService.sessions.get(s.id)!.status, SessionStatus.active,
          reason: 'only the banker ends a session');
    });

    test('other tables keep running when one closes', () async {
      final s = _session();
      await TableService.addTable(s, name: 'Table 2');
      final t1 = TableService.tablesFor(s).first.id;
      await TableService.closeTable(s, 'table-2');

      expect(TableService.tableById(s, t1).status, TableStatus.active);
      expect(TableService.openTables(s).length, 1);
    });
  });

  group('Status transitions', () {
    test('tables default to active, including legacy data', () {
      final s = _session();
      expect(TableService.tablesFor(s).first.status, TableStatus.active);
      // A stored map with no status key is pre-upgrade data.
      final legacy = PokerTable.fromMap(
          {'id': 'x', 'name': 'Old', 'seatCount': 9, 'dealerSeat': 1});
      expect(legacy.status, TableStatus.active);
    });

    test('pause and resume round-trip', () async {
      final s = _session();
      final t1 = TableService.tablesFor(s).first.id;
      await TableService.pauseTable(s, t1);
      expect(TableService.tableById(s, t1).status, TableStatus.paused);
      await TableService.resumeTable(s, t1);
      expect(TableService.tableById(s, t1).status, TableStatus.active);
    });

    test('a paused table still accepts corrections; a closed one does not',
        () {
      expect(TableStatus.paused.acceptsPlay, isTrue);
      expect(TableStatus.active.acceptsPlay, isTrue);
      expect(TableStatus.closed.acceptsPlay, isFalse);
    });

    test('closing stamps a time, reopening clears it', () async {
      final s = _session();
      await TableService.addTable(s, name: 'Table 2');
      await TableService.closeTable(s, 'table-2');
      expect(TableService.tableById(s, 'table-2').closedAt, isNotNull);
      await TableService.reopenTable(s, 'table-2');
      expect(TableService.tableById(s, 'table-2').closedAt, isNull);
      expect(TableService.tableById(s, 'table-2').status, TableStatus.active);
    });

    test('status survives a save/reload', () async {
      final s = _session();
      await TableService.addTable(s, name: 'Table 2');
      await TableService.pauseTable(s, 'table-2');
      final reloaded = HiveService.sessions.get(s.id)!;
      expect(TableService.tableById(reloaded, 'table-2').status,
          TableStatus.paused);
    });
  });

  group('Money is protected', () {
    test('a table with unsettled players cannot be closed', () async {
      final s = _session();
      await TableService.addTable(s, name: 'Table 2');
      final p = _p(s.id, 'Live', seat: 1, tableId: 'table-2');
      await _tx(s.id, p.id, TransactionType.buyIn, 500);

      expect(TableService.closeBlocker(s, 'table-2'), isNotNull);
      await TableService.closeTable(s, 'table-2');
      expect(TableService.tableById(s, 'table-2').status, TableStatus.active,
          reason: 'closing must be refused while money is on the table');
    });

    test('once everyone has cashed out the table can close', () async {
      final s = _session();
      await TableService.addTable(s, name: 'Table 2');
      final p = _p(s.id, 'Done', seat: 1, tableId: 'table-2');
      await _tx(s.id, p.id, TransactionType.buyIn, 500);
      await _tx(s.id, p.id, TransactionType.cashOut, 500);

      expect(TableService.closeBlocker(s, 'table-2'), isNull);
      await TableService.closeTable(s, 'table-2');
      expect(TableService.tableById(s, 'table-2').status, TableStatus.closed);
    });

    test('a busted player (zero cash-out) does not block closing', () async {
      final s = _session();
      await TableService.addTable(s, name: 'Table 2');
      final p = _p(s.id, 'Busted', seat: 1, tableId: 'table-2');
      await _tx(s.id, p.id, TransactionType.buyIn, 300);
      await _tx(s.id, p.id, TransactionType.cashOut, 0);
      expect(TableService.closeBlocker(s, 'table-2'), isNull);
    });

    test('players cannot be moved onto a closed table', () async {
      final s = _session();
      await TableService.addTable(s, name: 'Table 2');
      final t1 = TableService.tablesFor(s).first.id;
      await TableService.closeTable(s, 'table-2');
      final p = _p(s.id, 'Mover', seat: 1, tableId: t1);

      expect(TableService.seatingBlocker(s, 'table-2'), isNotNull);
      expect(() => TableService.movePlayer(s, p, 'table-2'),
          throwsA(isA<StateError>()));
    });

    test('closing a table leaves the ledger untouched', () async {
      final s = _session();
      await TableService.addTable(s, name: 'Table 2');
      final p = _p(s.id, 'A', seat: 1, tableId: 'table-2');
      await _tx(s.id, p.id, TransactionType.buyIn, 400);
      await _tx(s.id, p.id, TransactionType.cashOut, 400);
      final before = SessionService.checkBalance(s.id);

      await TableService.closeTable(s, 'table-2');

      final after = SessionService.checkBalance(s.id);
      expect(after.moneyIn, before.moneyIn);
      expect(after.moneyOut, before.moneyOut);
      expect(after.isBalanced, isTrue);
    });
  });
}
