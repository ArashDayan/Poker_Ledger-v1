// Tests for the three V2 features: cross-session player history,
// multi-table support, and privacy mode.
//
// The priority here is proving that NONE of them can affect the money:
// the settlement engine, the balance check and every existing saved
// session must behave exactly as they did before.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:poker_ledger/core/utils/currency_formatter.dart';
import 'package:poker_ledger/models/player.dart';
import 'package:poker_ledger/models/session.dart';
import 'package:poker_ledger/models/transaction.dart';
import 'package:poker_ledger/services/hive_service.dart';
import 'package:poker_ledger/services/player_history_service.dart';
import 'package:poker_ledger/services/session_service.dart';
import 'package:poker_ledger/services/table_service.dart';
import 'package:uuid/uuid.dart';
import 'test_helper.dart';

const _uuid = Uuid();
late Directory _tempDir;

Future<void> _openTestBoxes() async {
  _tempDir = await Directory.systemTemp.createTemp('pl_v2_test_');
  Hive.init(_tempDir.path);
  registerTestAdapters();
  await Hive.openBox<PokerSession>(HiveService.sessionsBox);
  await Hive.openBox<Player>(HiveService.playersBox);
  await Hive.openBox<LedgerTransaction>(HiveService.transactionsBox);
  await Hive.openBox(HiveService.settingsBox);
}

Future<void> _closeTestBoxes() async {
  await Hive.deleteFromDisk();
  if (await _tempDir.exists()) await _tempDir.delete(recursive: true);
}

PokerSession _session({
  String name = 'Session',
  DateTime? when,
  AppCurrency currency = AppCurrency.usd,
  SessionStatus status = SessionStatus.active,
}) {
  final s = PokerSession(
    id: _uuid.v4(),
    name: name,
    location: 'Room',
    dateTime: when ?? DateTime.now(),
    smallBlind: 1,
    bigBlind: 2,
    tableNumber: '1',
    currency: currency,
    status: status,
  );
  HiveService.sessions.put(s.id, s);
  return s;
}

Player _player(String sessionId, String name,
    {int seat = 1, String? tableId}) {
  final p = Player(
    id: _uuid.v4(),
    sessionId: sessionId,
    name: name,
    seatNumber: seat,
    tableId: tableId,
  );
  HiveService.players.put(p.id, p);
  return p;
}

Future<void> _tx(String sessionId, String playerId, TransactionType t,
    double amount) async {
  await SessionService.recordTransaction(
    sessionId: sessionId,
    playerId: playerId,
    type: t,
    amount: amount,
    hostSignatureBase64: 'sig',
  );
}

void main() {
  setUp(_openTestBoxes);
  tearDown(() async {
    CurrencyFormatter.privacyMode = false;
    await _closeTestBoxes();
  });

  // -------------------------------------------------------------------
  group('Player history across sessions', () {
    test('aggregates the same player across several sessions', () async {
      final s1 = _session(name: 'Week 1', when: DateTime(2026, 1, 1));
      final s2 = _session(name: 'Week 2', when: DateTime(2026, 1, 8));

      final p1 = _player(s1.id, 'Reza');
      await _tx(s1.id, p1.id, TransactionType.buyIn, 200);
      await _tx(s1.id, p1.id, TransactionType.cashOut, 500); // +300

      final p2 = _player(s2.id, 'Reza');
      await _tx(s2.id, p2.id, TransactionType.buyIn, 200);
      await _tx(s2.id, p2.id, TransactionType.rebuy, 100);
      await _tx(s2.id, p2.id, TransactionType.cashOut, 0); // -300

      final c = PlayerHistoryService.careerForName('Reza');
      expect(c.sessionsPlayed, 2);
      expect(c.totalBuyIn, 400);
      expect(c.totalRebuy, 100);
      expect(c.totalCashOut, 500);
      expect(c.netResult, 0);
      expect(c.sessionsWon, 1);
      expect(c.sessionsLost, 1);
      expect(c.totalRebuys, 1);
    });

    test('groups names case- and whitespace-insensitively', () async {
      final s1 = _session(when: DateTime(2026, 2, 1));
      final s2 = _session(when: DateTime(2026, 2, 8));
      _player(s1.id, 'Ali Reza');
      _player(s2.id, '  ali   reza ');
      expect(PlayerHistoryService.careerForName('ALI REZA').sessionsPlayed, 2);
    });

    test('recent sessions are newest first', () async {
      final older = _session(name: 'Older', when: DateTime(2026, 3, 1));
      final newer = _session(name: 'Newer', when: DateTime(2026, 3, 20));
      _player(older.id, 'Sam');
      _player(newer.id, 'Sam');
      final c = PlayerHistoryService.careerForName('Sam');
      expect(c.recentSessions.first.session.name, 'Newer');
      expect(c.lastPlayed, DateTime(2026, 3, 20));
      expect(c.firstPlayed, DateTime(2026, 3, 1));
    });

    test('a player still in play is not counted as a win or a loss',
        () async {
      final s = _session();
      final p = _player(s.id, 'Live');
      await _tx(s.id, p.id, TransactionType.buyIn, 200);
      final c = PlayerHistoryService.careerForName('Live');
      expect(c.sessionsPlayed, 1);
      expect(c.completedSessions, 0);
      expect(c.sessionsWon, 0);
      expect(c.sessionsLost, 0);
      expect(c.winRate, isNull, reason: 'no completed sessions yet');
    });

    test('mixed currencies are flagged so totals are never nonsense',
        () async {
      final usd = _session(currency: AppCurrency.usd);
      final toman = _session(currency: AppCurrency.toman);
      _player(usd.id, 'Mo');
      _player(toman.id, 'Mo');
      final c = PlayerHistoryService.careerForName('Mo');
      expect(c.hasConsistentCurrency, isFalse);
      expect(c.currencies.length, 2);
    });

    test('a zero cash-out counts as a completed, losing session', () async {
      final s = _session();
      final p = _player(s.id, 'Busted');
      await _tx(s.id, p.id, TransactionType.buyIn, 300);
      await _tx(s.id, p.id, TransactionType.cashOut, 0);
      final c = PlayerHistoryService.careerForName('Busted');
      expect(c.completedSessions, 1);
      expect(c.sessionsLost, 1);
      expect(c.netResult, -300);
    });

    test('history is read-only — it never changes the ledger', () async {
      final s = _session();
      final p = _player(s.id, 'Reza');
      await _tx(s.id, p.id, TransactionType.buyIn, 200);
      final before = SessionService.checkBalance(s.id);
      PlayerHistoryService.allCareers();
      PlayerHistoryService.careerForName('Reza');
      final after = SessionService.checkBalance(s.id);
      expect(after.moneyIn, before.moneyIn);
      expect(after.moneyOut, before.moneyOut);
      expect(after.discrepancy, before.discrepancy);
    });
  });

  // -------------------------------------------------------------------
  group('Multi-table support', () {
    test('a legacy session with no tables reads as one table', () {
      final s = _session();
      expect(s.tables, isNull);
      final tables = TableService.tablesFor(s);
      expect(tables.length, 1);
      expect(TableService.isMultiTable(s), isFalse);
      expect(tables.first.seatCount, s.tableSeatCount);
    });

    test('legacy players with a null tableId belong to the first table', () {
      final s = _session();
      _player(s.id, 'Old', seat: 3); // tableId == null
      final first = TableService.tablesFor(s).first;
      expect(TableService.playersAt(s, first.id).length, 1);
    });

    test('adding a table does not move anyone or touch the money', () async {
      final s = _session();
      final p = _player(s.id, 'Ari', seat: 1);
      await _tx(s.id, p.id, TransactionType.buyIn, 500);
      final before = SessionService.checkBalance(s.id);

      await TableService.addTable(s, name: 'Table 2', seatCount: 8);

      expect(TableService.isMultiTable(s), isTrue);
      final first = TableService.tablesFor(s).first;
      expect(TableService.playersAt(s, first.id).length, 1,
          reason: 'existing player stays where they were');
      expect(TableService.playersAt(s, 'table-2'), isEmpty);

      final after = SessionService.checkBalance(s.id);
      expect(after.moneyIn, before.moneyIn);
      expect(after.moneyOut, before.moneyOut);
      expect(SessionService.totalBuyIn(s.id), 500);
    });

    test('seat numbers are unique per table, not per session', () async {
      final s = _session();
      await TableService.addTable(s, name: 'Table 2');
      final t1 = TableService.tablesFor(s).first.id;
      _player(s.id, 'A', seat: 3, tableId: t1);
      _player(s.id, 'B', seat: 3, tableId: 'table-2');

      expect(TableService.occupiedSeats(s, t1), {3});
      expect(TableService.occupiedSeats(s, 'table-2'), {3});
      expect(TableService.playersAt(s, t1).single.name, 'A');
      expect(TableService.playersAt(s, 'table-2').single.name, 'B');
    });

    test('moving a player keeps every transaction intact', () async {
      final s = _session();
      await TableService.addTable(s, name: 'Table 2');
      final t1 = TableService.tablesFor(s).first.id;
      final p = _player(s.id, 'Mover', seat: 2, tableId: t1);
      await _tx(s.id, p.id, TransactionType.buyIn, 400);
      await _tx(s.id, p.id, TransactionType.rebuy, 200);

      await TableService.movePlayer(s, p, 'table-2');

      expect(p.tableId, 'table-2');
      expect(SessionService.playerTotalIn(s.id, p.id), 600,
          reason: 'a seat change must never alter money');
      expect(SessionService.checkBalance(s.id).moneyIn, 600);
      expect(TableService.playersAt(s, t1), isEmpty);
      expect(TableService.playersAt(s, 'table-2').single.id, p.id);
    });

    test('moving into a taken seat is refused', () async {
      final s = _session();
      await TableService.addTable(s, name: 'Table 2');
      final t1 = TableService.tablesFor(s).first.id;
      _player(s.id, 'Sitting', seat: 1, tableId: 'table-2');
      final p = _player(s.id, 'Mover', seat: 1, tableId: t1);

      expect(
        () => TableService.movePlayer(s, p, 'table-2', seat: 1),
        throwsA(isA<StateError>()),
      );
    });

    test('the last table cannot be removed, nor an occupied one', () async {
      final s = _session();
      final t1 = TableService.tablesFor(s).first.id;
      expect(TableService.removalBlocker(s, t1), isNotNull);

      await TableService.addTable(s, name: 'Table 2');
      _player(s.id, 'Seated', seat: 1, tableId: 'table-2');
      expect(TableService.removalBlocker(s, 'table-2'), isNotNull,
          reason: 'must not silently strand a seated player');

      await TableService.removeTable(s, 'table-2');
      expect(TableService.tablesFor(s).length, 2, reason: 'removal blocked');
    });

    test('an empty table can be removed', () async {
      final s = _session();
      await TableService.addTable(s, name: 'Table 2');
      expect(TableService.tablesFor(s).length, 2);
      await TableService.removeTable(s, 'table-2');
      expect(TableService.tablesFor(s).length, 1);
    });

    test('the balance check stays session-wide across tables', () async {
      final s = _session();
      await TableService.addTable(s, name: 'Table 2');
      final t1 = TableService.tablesFor(s).first.id;

      final a = _player(s.id, 'A', seat: 1, tableId: t1);
      final b = _player(s.id, 'B', seat: 1, tableId: 'table-2');
      await _tx(s.id, a.id, TransactionType.buyIn, 1000);
      await _tx(s.id, b.id, TransactionType.buyIn, 1000);
      await _tx(s.id, a.id, TransactionType.cashOut, 1500);
      await _tx(s.id, b.id, TransactionType.cashOut, 500);

      final bal = SessionService.checkBalance(s.id);
      expect(bal.moneyIn, 2000);
      expect(bal.moneyOut, 2000);
      expect(bal.isBalanced, isTrue,
          reason: 'one bank for the whole floor, not one per table');
    });

    test('per-table money in play splits the same session-wide money',
        () async {
      final s = _session();
      await TableService.addTable(s, name: 'Table 2');
      final t1 = TableService.tablesFor(s).first.id;
      final a = _player(s.id, 'A', seat: 1, tableId: t1);
      final b = _player(s.id, 'B', seat: 1, tableId: 'table-2');
      await _tx(s.id, a.id, TransactionType.buyIn, 300);
      await _tx(s.id, b.id, TransactionType.buyIn, 700);

      expect(TableService.moneyInPlayAt(s, t1), 300);
      expect(TableService.moneyInPlayAt(s, 'table-2'), 700);
    });

    test('table ids are never reused after a removal', () async {
      final s = _session();
      await TableService.addTable(s, name: 'T2');
      await TableService.removeTable(s, 'table-2');
      await TableService.addTable(s, name: 'Another');
      final ids = TableService.tablesFor(s).map((t) => t.id).toList();
      expect(ids.toSet().length, ids.length);
    });

    test('a session survives a save/reload with its tables', () async {
      final s = _session();
      await TableService.addTable(s, name: 'Table 2', seatCount: 6);
      final reloaded = HiveService.sessions.get(s.id)!;
      final tables = TableService.tablesFor(reloaded);
      expect(tables.length, 2);
      expect(tables.last.name, 'Table 2');
      expect(tables.last.seatCount, 6);
    });
  });

  // -------------------------------------------------------------------
  group('Privacy mode', () {
    test('masks displayed amounts but never the underlying value', () {
      final fmt = CurrencyFormatter(AppCurrency.usd);
      final real = fmt.format(1234);
      expect(real.contains('1,234'), isTrue);

      CurrencyFormatter.privacyMode = true;
      expect(fmt.format(1234), CurrencyFormatter.maskedText);
      expect(fmt.format(1234).contains('1'), isFalse);

      CurrencyFormatter.privacyMode = false;
      expect(fmt.format(1234), real);
    });

    test('formatRaw always shows the real figure, for exports', () {
      final fmt = CurrencyFormatter(AppCurrency.usd);
      CurrencyFormatter.privacyMode = true;
      expect(fmt.formatRaw(999).contains('999'), isTrue,
          reason: 'an exported report must never be masked');
    });

    test('privacy mode does not affect the settlement engine', () async {
      final s = _session();
      final p = _player(s.id, 'A');
      await _tx(s.id, p.id, TransactionType.buyIn, 500);
      await _tx(s.id, p.id, TransactionType.cashOut, 500);

      CurrencyFormatter.privacyMode = true;
      final bal = SessionService.checkBalance(s.id);
      expect(bal.moneyIn, 500);
      expect(bal.moneyOut, 500);
      expect(bal.isBalanced, isTrue);
      expect(SessionService.playerProfitLoss(s.id, p.id), 0);
    });

    test('the mask is a fixed width so layouts do not jump', () {
      final usd = CurrencyFormatter(AppCurrency.usd);
      final toman = CurrencyFormatter(AppCurrency.toman);
      CurrencyFormatter.privacyMode = true;
      expect(usd.format(1), usd.format(999999));
      expect(usd.format(5), toman.format(5),
          reason: 'same mask regardless of currency or magnitude');
    });
  });
}
