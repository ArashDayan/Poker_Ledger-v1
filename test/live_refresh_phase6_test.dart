// Phase 6 — live refresh / cold start.
//
// These tests do not treat Hive.watch() emitting as sufficient. They
// construct a fresh SessionProvider, mutate through the same write
// paths the banker uses, and assert the *provider state* listeners
// see changes without any navigation.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:poker_ledger/models/enums.dart';
import 'package:poker_ledger/models/financial_event.dart';
import 'package:poker_ledger/models/hand.dart';
import 'package:poker_ledger/models/player.dart';
import 'package:poker_ledger/models/player_identity.dart';
import 'package:poker_ledger/models/session.dart';
import 'package:poker_ledger/models/table_participation.dart';
import 'package:poker_ledger/models/transaction.dart';
import 'package:poker_ledger/providers/session_provider.dart';
import 'package:poker_ledger/services/box_watch_hub.dart';
import 'package:poker_ledger/services/financial_ledger_service.dart';
import 'package:poker_ledger/services/hive_service.dart';
import 'package:poker_ledger/services/session_service.dart';
import 'package:poker_ledger/services/table_service.dart';
import 'package:uuid/uuid.dart';

import 'test_helper.dart';

const _uuid = Uuid();
late Directory _tmp;

Future<void> _openAll() async {
  _tmp = await Directory.systemTemp.createTemp('pl_phase6_');
  Hive.init(_tmp.path);
  registerTestAdapters();
  await Hive.openBox<PokerSession>(HiveService.sessionsBox);
  await Hive.openBox<Player>(HiveService.playersBox);
  await Hive.openBox<LedgerTransaction>(HiveService.transactionsBox);
  await Hive.openBox(HiveService.settingsBox);
  await Hive.openBox<PlayerIdentity>(HiveService.playerIdentitiesBox);
  await Hive.openBox<FinancialEvent>(HiveService.financialEventsBox);
  await Hive.openBox<TableParticipation>(HiveService.participationsBox);
  await Hive.openBox<Hand>(HiveService.handsBox);
}

Future<void> _close() async {
  await Hive.deleteFromDisk();
  if (await _tmp.exists()) await _tmp.delete(recursive: true);
}

PokerSession _session() {
  final s = PokerSession(
    id: _uuid.v4(),
    name: 'Night',
    location: 'Room',
    dateTime: DateTime.now(),
    smallBlind: 1,
    bigBlind: 2,
    tableNumber: '1',
  );
  HiveService.sessions.put(s.id, s);
  return s;
}

void main() {
  group('BoxWatchHub', () {
    test('one failed attach does not block the others', () {
      final hub = BoxWatchHub(onEvent: () {});
      final ok = hub.attach('good', () => const Stream<BoxEvent>.empty());
      final bad = hub.attach('bad', () => throw StateError('closed'));
      expect(ok, isTrue);
      expect(bad, isFalse);
      expect(hub.isAttached('good'), isTrue);
      expect(hub.failedNames, contains('bad'));
      expect(hub.attachedCount, 1);
      hub.dispose();
    });

    test('retry recovers a previously failed name', () {
      final hub = BoxWatchHub(onEvent: () {});
      var open = false;
      hub.attach('late', () {
        if (!open) throw StateError('not yet');
        return const Stream<BoxEvent>.empty();
      });
      expect(hub.failedNames, contains('late'));
      open = true;
      hub.retryFailed((name) {
        hub.attach(name, () => const Stream<BoxEvent>.empty());
      });
      expect(hub.isAttached('late'), isTrue);
      expect(hub.failedNames, isEmpty);
      hub.dispose();
    });
  });

  group('Fresh SessionProvider', () {
    setUp(_openAll);
    tearDown(_close);

    test('1. initialization attaches watchers', () {
      final p = SessionProvider();
      expect(p.watchersHealthy, isTrue);
      expect(p.attachedWatcherNames, containsAll(['players', 'transactions', 'sessions']));
      p.dispose();
    });

    test('2. adding a player changes provider state', () async {
      final p = SessionProvider();
      p.loadSession(_session());
      var ticks = 0;
      p.addListener(() => ticks++);
      final before = p.players.length;
      await p.addPlayer(name: 'Ada', seatNumber: 1);
      expect(p.players.length, before + 1);
      expect(p.players.any((x) => x.name == 'Ada'), isTrue);
      expect(ticks, greaterThan(0));
      p.dispose();
    });

    test('3. table view source list includes the new player immediately',
        () async {
      final p = SessionProvider();
      p.loadSession(_session());
      await p.addPlayer(name: 'Ben', seatNumber: 3);
      final atTable = TableService.playersAt(p.current!, p.activeTableId);
      expect(atTable.map((x) => x.name), contains('Ben'));
      expect(p.playersAtActiveTable.map((x) => x.name), contains('Ben'));
      p.dispose();
    });

    test('4. table switching uses current state immediately', () async {
      final p = SessionProvider();
      final s = _session();
      p.loadSession(s);
      await p.addTable(name: 'Table 2');
      final t1 = TableService.tablesFor(p.current!).first.id;
      final t2 = TableService.tablesFor(p.current!).last.id;
      await p.addPlayer(name: 'On1', seatNumber: 1, tableId: t1);
      await p.addPlayer(name: 'On2', seatNumber: 1, tableId: t2);

      p.setActiveTable(t1);
      expect(p.playersAtActiveTable.map((x) => x.name), ['On1']);
      p.setActiveTable(t2);
      expect(p.playersAtActiveTable.map((x) => x.name), ['On2']);
      p.setActiveTable(t1);
      expect(p.playersAtActiveTable.map((x) => x.name), ['On1']);
      p.dispose();
    });

    test('5. player list updates immediately', () async {
      final p = SessionProvider();
      p.loadSession(_session());
      await p.addPlayer(name: 'Cara', seatNumber: 2);
      expect(p.players.map((x) => x.name), contains('Cara'));
      final cara = p.players.firstWhere((x) => x.name == 'Cara');
      cara.name = 'Cara-X';
      await p.updatePlayer(cara);
      expect(p.players.map((x) => x.name), contains('Cara-X'));
      p.dispose();
    });

    test('6. transaction changes propagate immediately', () async {
      final p = SessionProvider();
      p.loadSession(_session());
      final player = await p.addPlayer(name: 'Dan', seatNumber: 1);
      await p.recordTransaction(
        playerId: player.id,
        type: TransactionType.buyIn,
        amount: 200,
        hostSignatureBase64: 'sig',
      );
      expect(p.totalBuyIn, 200);
      expect(p.transactions.length, 1);
      expect(SessionService.playerTotalIn(p.current!.id, player.id), 200);
      p.dispose();
    });

    test('7. financial event changes notify the session provider', () async {
      final p = SessionProvider();
      final s = _session();
      p.loadSession(s);
      var ticks = 0;
      p.addListener(() => ticks++);
      final ev = FinancialEvent(
        id: _uuid.v4(),
        personId: 'person-1',
        currency: AppCurrency.usd,
        type: FinancialEventType.cashInForChips,
        amountMinor: 5000,
        occurredAt: DateTime.now(),
        createdAt: DateTime.now(),
        sessionId: s.id,
      );
      await HiveService.financialEvents.put(ev.id, ev);
      await Future<void>.delayed(Duration.zero);
      expect(ticks, greaterThan(0));
      p.dispose();
    });

    test('8. dashboard totals follow the authoritative session books',
        () async {
      final p = SessionProvider();
      p.loadSession(_session());
      final player = await p.addPlayer(name: 'Eve', seatNumber: 1);
      await p.recordTransaction(
        playerId: player.id,
        type: TransactionType.buyIn,
        amount: 100,
        hostSignatureBase64: 'sig',
      );
      expect(p.balance!.moneyIn, 100);
      expect(p.moneyStillInPlay, 100);
      expect(p.hostProfit, 0);
      p.dispose();
    });

    test('9. watcher init failure does not permanently disable refresh',
        () async {
      final hub = BoxWatchHub(onEvent: () {});
      var open = false;
      hub.attach('players', () {
        if (!open) throw StateError('cold');
        return HiveService.players.watch();
      });
      expect(hub.failedNames, contains('players'));
      open = true;
      hub.retryFailed((name) {
        hub.attach(name, () => HiveService.players.watch());
      });
      expect(hub.isAttached('players'), isTrue);

      final p = SessionProvider();
      expect(p.retryFailedWatchers(), isTrue);
      p.loadSession(_session());
      await p.addPlayer(name: 'Fay', seatNumber: 4);
      expect(p.players.map((x) => x.name), contains('Fay'));
      hub.dispose();
      p.dispose();
    });

    test('10. committed change is visible without navigation', () async {
      final p = SessionProvider();
      p.loadSession(_session());
      final seen = <int>[];
      p.addListener(() => seen.add(p.players.length));
      await p.addPlayer(name: 'Gus', seatNumber: 5);
      expect(seen, isNotEmpty);
      expect(p.players.length, 1);
      expect(p.revision, greaterThan(0));
      p.dispose();
    });
  });

  group('Cold-start attach before boxes exist', () {
    test('retry after boxes open attaches watchers', () async {
      final p = SessionProvider();
      // Boxes may or may not be open depending on isolate order; force
      // a retry after a guaranteed open.
      _tmp = await Directory.systemTemp.createTemp('pl_phase6_cold_');
      Hive.init(_tmp.path);
      registerTestAdapters();
      await Hive.openBox<PokerSession>(HiveService.sessionsBox);
      await Hive.openBox<Player>(HiveService.playersBox);
      await Hive.openBox<LedgerTransaction>(HiveService.transactionsBox);
      await Hive.openBox(HiveService.settingsBox);
      await Hive.openBox<FinancialEvent>(HiveService.financialEventsBox);
      expect(p.retryFailedWatchers() || p.watchersHealthy, isTrue);
      p.dispose();
      await Hive.deleteFromDisk();
      if (await _tmp.exists()) await _tmp.delete(recursive: true);
    });
  });
}
