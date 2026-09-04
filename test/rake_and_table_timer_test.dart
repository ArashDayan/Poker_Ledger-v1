// Quick Rake (both modes) and independent per-table timers.
//
// The rule that matters most here: attributing a rake to a player is a
// record of WHOSE POT it came from. It must never be charged against
// that player's profit/loss, and both modes must feed the same
// session-wide rake total.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:poker_ledger/models/player.dart';
import 'package:poker_ledger/models/player_identity.dart';
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
  _tmp = await Directory.systemTemp.createTemp('pl_rake_');
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

PokerSession _session() {
  final s = PokerSession(
    id: _uuid.v4(),
    name: 'Rake night',
    location: 'Room',
    dateTime: DateTime.now(),
    smallBlind: 1,
    bigBlind: 2,
    tableNumber: '1',
  );
  HiveService.sessions.put(s.id, s);
  return s;
}

Future<Player> _p(String sid, String name, {int seat = 1, String? tableId}) async {
  final personId = _uuid.v4();
  final p = Player(
      id: _uuid.v4(), sessionId: sid, name: name, seatNumber: seat,
      tableId: tableId, personId: personId);
  await HiveService.playerIdentities.put(
      personId, PlayerIdentity(id: personId, displayName: name));
  await HiveService.players.put(p.id, p);
  return p;
}

Future<LedgerTransaction> _tx(String sid, String? pid, TransactionType t,
        double amt, {String? tableId}) =>
    SessionService.recordTransaction(
        sessionId: sid, playerId: pid, type: t, amount: amt,
        hostSignatureBase64: t == TransactionType.rakeCollection ? '' : 'sig',
        tableId: tableId);

void main() {
  setUp(_open);
  tearDown(_close);

  group('Quick Rake — two modes', () {
    test('Mode 1: rake attributed to a player is stored against them',
        () async {
      final s = _session();
      final p = await _p(s.id, 'Ari');
      final rake = await _tx(s.id, p.id, TransactionType.rakeCollection, 50);

      expect(rake.playerId, p.id);
      expect(SessionService.playerRakeTotal(s.id, p.id), 50);
      expect(SessionService.totalRake(s.id), 50,
          reason: 'attributed rake still counts as session income');
    });

    test('Mode 2: general rake has no player ownership', () async {
      final s = _session();
      final rake = await _tx(s.id, null, TransactionType.rakeCollection, 40);

      expect(rake.playerId, isNull);
      expect(SessionService.unattributedRake(s.id), 40);
      expect(SessionService.totalRake(s.id), 40);
    });

    test('both modes feed the same session total', () async {
      final s = _session();
      final p = await _p(s.id, 'Ari');
      await _tx(s.id, p.id, TransactionType.rakeCollection, 30);
      await _tx(s.id, null, TransactionType.rakeCollection, 20);

      expect(SessionService.totalRake(s.id), 50);
      expect(SessionService.playerRakeTotal(s.id, p.id), 30);
      expect(SessionService.unattributedRake(s.id), 20);
      expect(SessionService.hostProfit(s.id), 50);
    });

    test('attributed rake NEVER changes the player profit or loss',
        () async {
      final s = _session();
      final p = await _p(s.id, 'Ari');
      await _tx(s.id, p.id, TransactionType.buyIn, 500);
      await _tx(s.id, p.id, TransactionType.cashOut, 800);
      final plBefore = SessionService.playerProfitLoss(s.id, p.id);

      await _tx(s.id, p.id, TransactionType.rakeCollection, 100);

      expect(SessionService.playerProfitLoss(s.id, p.id), plBefore,
          reason: 'rake is house income, not a charge on the player');
      expect(SessionService.playerProfitLoss(s.id, p.id), 300);
      expect(SessionService.playerTotalIn(s.id, p.id), 500,
          reason: 'rake must not inflate what the player put in');
    });

    test('attributed rake behaves identically in the balance check',
        () async {
      final s = _session();
      final p = await _p(s.id, 'Ari');
      await _tx(s.id, p.id, TransactionType.buyIn, 1000);
      await _tx(s.id, p.id, TransactionType.rakeCollection, 100);
      await _tx(s.id, p.id, TransactionType.cashOut, 900);

      final bal = SessionService.checkBalance(s.id);
      expect(bal.moneyIn, 1000);
      expect(bal.moneyOut, 1000, reason: 'cash-out + rake');
      expect(bal.isBalanced, isTrue);
    });

    test('rake carries the table it was taken at', () async {
      final s = _session();
      await TableService.addTable(s, name: 'Table 2');
      final p = await _p(s.id, 'B', seat: 1, tableId: 'table-2');
      final attributed =
          await _tx(s.id, p.id, TransactionType.rakeCollection, 25);
      final general = await _tx(s.id, null, TransactionType.rakeCollection, 15,
          tableId: 'table-2');

      expect(attributed.tableId, 'table-2');
      expect(general.tableId, 'table-2');
    });
  });

  group('Per-table timers', () {
    test('each table keeps its own independent clock', () async {
      final s = _session();
      await TableService.addTable(s, name: 'Table 2');
      final t1 = TableService.tablesFor(s).first.id;

      await TableService.startTableTimer(s, t1);
      expect(TableService.tableById(s, t1).timerRunning, isTrue);
      expect(TableService.tableById(s, 'table-2').timerRunning, isFalse,
          reason: 'starting one table must not start another');
    });

    test('tables can start at different times', () async {
      final s = _session();
      await TableService.addTable(s, name: 'Table 2');
      final t1 = TableService.tablesFor(s).first.id;
      await TableService.startTableTimer(s, t1);
      await TableService.startTableTimer(s, 'table-2');

      expect(TableService.tableById(s, t1).timerRunning, isTrue);
      expect(TableService.tableById(s, 'table-2').timerRunning, isTrue);
      // Both hold their own start stamp rather than a shared one.
      expect(TableService.tableById(s, t1).runningSince, isNotNull);
      expect(TableService.tableById(s, 'table-2').runningSince, isNotNull);
    });

    test('pausing banks the elapsed time instead of losing it', () async {
      final s = _session();
      final t1 = TableService.tablesFor(s).first.id;
      await TableService.startTableTimer(s, t1);
      await TableService.pauseTableTimer(s, t1);

      final t = TableService.tableById(s, t1);
      expect(t.timerRunning, isFalse);
      expect(t.runningSince, isNull);
      expect(t.bankedSeconds, greaterThanOrEqualTo(0));
    });

    test('reset clears the banked time', () async {
      final s = _session();
      final t1 = TableService.tablesFor(s).first.id;
      await TableService.startTableTimer(s, t1);
      await TableService.pauseTableTimer(s, t1);
      await TableService.resetTableTimer(s, t1);
      expect(TableService.tableById(s, t1).bankedSeconds, 0);
      expect(TableService.tableById(s, t1).elapsed, Duration.zero);
    });

    test('closing a table stops its clock', () async {
      final s = _session();
      await TableService.addTable(s, name: 'Table 2');
      await TableService.startTableTimer(s, 'table-2');
      await TableService.closeTable(s, 'table-2');

      final t = TableService.tableById(s, 'table-2');
      expect(t.timerRunning, isFalse,
          reason: 'a table not being dealt should not accrue play time');
      expect(t.status, TableStatus.closed);
    });

    test('timer state survives a save/reload', () async {
      final s = _session();
      final t1 = TableService.tablesFor(s).first.id;
      await TableService.startTableTimer(s, t1);
      final reloaded = HiveService.sessions.get(s.id)!;
      expect(TableService.tableById(reloaded, t1).timerRunning, isTrue);
    });

    test('the session timer is untouched by table timers', () async {
      final s = _session();
      s.plannedMinutes = 120;
      await s.save();
      final t1 = TableService.tablesFor(s).first.id;
      await TableService.startTableTimer(s, t1);

      final reloaded = HiveService.sessions.get(s.id)!;
      expect(reloaded.plannedMinutes, 120);
      expect(reloaded.hasTimer, isTrue);
    });
  });
}
