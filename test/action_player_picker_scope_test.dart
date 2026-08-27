// Issue #3B — the Action player picker must be scoped to the active
// table in a multi-table session.
//
// The bug was not a refresh failure: `provider.players` is read live from
// Hive at tap time and was always current. It was a SCOPE bug — the
// picker listed every player in the session while PlayersTab already
// scoped to the active table. Because seat numbers repeat across tables,
// "Seat 3" could mean two different people and a buy-in could be recorded
// against the wrong player.
//
// These tests assert on the exact expression the screen now uses:
//   provider.isMultiTable ? provider.playersAtActiveTable : provider.players
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

const _hostSig = 'BASE64_HOST_SIG';

Future<void> _open() async {
  _tmp = await Directory.systemTemp.createTemp('pl_picker_scope_');
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

/// Mirrors exactly what TransactionsTab now computes for the picker.
List<Player> actionPlayers(SessionProvider p) =>
    p.isMultiTable ? p.playersAtActiveTable : p.players;

void main() {
  setUp(_open);
  tearDown(_close);

  group('1. single-table sessions are unchanged', () {
    test('the picker shows every player in the session', () async {
      final provider = await _provider();
      await provider.addPlayer(name: 'Ali', seatNumber: 1);
      await provider.addPlayer(name: 'Sara', seatNumber: 2);
      await provider.addPlayer(name: 'Nima', seatNumber: 3);

      expect(provider.isMultiTable, isFalse);
      final list = actionPlayers(provider);
      expect(list.length, 3);
      expect(list.map((p) => p.name), containsAll(['Ali', 'Sara', 'Nima']));
      // Identical to the pre-fix behaviour.
      expect(list.map((p) => p.id), provider.players.map((p) => p.id));
    });

    test('an empty single-table session yields an empty list', () async {
      final provider = await _provider();
      expect(actionPlayers(provider), isEmpty);
    });
  });

  group('2. multi-table sessions are scoped to the active table', () {
    test('only active-table players are offered', () async {
      final provider = await _provider();
      await provider.addTable(name: 'Table 2');
      final ids = TableService.tablesFor(_live).map((t) => t.id).toList();

      await provider.addPlayer(
          name: 'Ali', seatNumber: 1, tableId: ids[0]);
      await provider.addPlayer(
          name: 'Sara', seatNumber: 2, tableId: ids[1]);

      expect(provider.isMultiTable, isTrue);

      provider.setActiveTable(ids[0]);
      expect(actionPlayers(provider).map((p) => p.name), ['Ali']);

      provider.setActiveTable(ids[1]);
      expect(actionPlayers(provider).map((p) => p.name), ['Sara']);
    });
  });

  group('3. switching tables changes the picker contents', () {
    test('the list follows the active table without any reload',
        () async {
      final provider = await _provider();
      await provider.addTable(name: 'Table 2');
      final ids = TableService.tablesFor(_live).map((t) => t.id).toList();

      await provider.addPlayer(name: 'A1', seatNumber: 1, tableId: ids[0]);
      await provider.addPlayer(name: 'A2', seatNumber: 2, tableId: ids[0]);
      await provider.addPlayer(name: 'B1', seatNumber: 1, tableId: ids[1]);

      provider.setActiveTable(ids[0]);
      expect(actionPlayers(provider).map((p) => p.name), ['A1', 'A2']);

      // No navigation, no reload — just flip the active table.
      provider.setActiveTable(ids[1]);
      expect(actionPlayers(provider).map((p) => p.name), ['B1']);

      provider.setActiveTable(ids[0]);
      expect(actionPlayers(provider).map((p) => p.name), ['A1', 'A2']);
    });
  });

  group('4-5. cross-table isolation', () {
    test('a Table 1 player never appears while Table 2 is active',
        () async {
      final provider = await _provider();
      await provider.addTable(name: 'Table 2');
      final ids = TableService.tablesFor(_live).map((t) => t.id).toList();

      final t1 = await provider.addPlayer(
          name: 'Ali', seatNumber: 1, tableId: ids[0]);

      provider.setActiveTable(ids[1]);
      expect(actionPlayers(provider).map((p) => p.id),
          isNot(contains(t1.id)));
    });

    test('a Table 2 player never appears while Table 1 is active',
        () async {
      final provider = await _provider();
      await provider.addTable(name: 'Table 2');
      final ids = TableService.tablesFor(_live).map((t) => t.id).toList();

      final t2 = await provider.addPlayer(
          name: 'Sara', seatNumber: 1, tableId: ids[1]);

      provider.setActiveTable(ids[0]);
      expect(actionPlayers(provider).map((p) => p.id),
          isNot(contains(t2.id)));
    });

    test('three tables each expose only their own players', () async {
      final provider = await _provider();
      await provider.addTable(name: 'Table 2');
      await provider.addTable(name: 'Table 3');
      final ids = TableService.tablesFor(_live).map((t) => t.id).toList();

      await provider.addPlayer(name: 'A', seatNumber: 1, tableId: ids[0]);
      await provider.addPlayer(name: 'B', seatNumber: 1, tableId: ids[1]);
      await provider.addPlayer(name: 'C', seatNumber: 1, tableId: ids[2]);

      for (var i = 0; i < 3; i++) {
        provider.setActiveTable(ids[i]);
        final names = actionPlayers(provider).map((p) => p.name).toList();
        expect(names.length, 1);
        expect(names.single, ['A', 'B', 'C'][i]);
      }
    });
  });

  group('6. a newly added player appears immediately', () {
    test('no leaving or re-entering the session is required', () async {
      final provider = await _provider();
      await provider.addTable(name: 'Table 2');
      final ids = TableService.tablesFor(_live).map((t) => t.id).toList();

      provider.setActiveTable(ids[1]);
      expect(actionPlayers(provider), isEmpty);

      // Seat a player at the table the banker is looking at.
      final fresh = await provider.addPlayer(
          name: 'Sara', seatNumber: 3, tableId: ids[1]);

      // The very next read already has them — the list is derived from
      // Hive on demand, not cached.
      expect(actionPlayers(provider).map((p) => p.id), contains(fresh.id));
    });

    test('a player added to the OTHER table does not appear here',
        () async {
      final provider = await _provider();
      await provider.addTable(name: 'Table 2');
      final ids = TableService.tablesFor(_live).map((t) => t.id).toList();

      provider.setActiveTable(ids[1]);
      final other = await provider.addPlayer(
          name: 'Ali', seatNumber: 1, tableId: ids[0]);

      expect(actionPlayers(provider).map((p) => p.id),
          isNot(contains(other.id)));
    });
  });

  group('7. selecting a player still records correctly', () {
    test('the transaction lands on the chosen player', () async {
      final provider = await _provider();
      await provider.addTable(name: 'Table 2');
      final ids = TableService.tablesFor(_live).map((t) => t.id).toList();

      await provider.addPlayer(name: 'Ali', seatNumber: 3, tableId: ids[0]);
      final sara = await provider.addPlayer(
          name: 'Sara', seatNumber: 3, tableId: ids[1]);

      provider.setActiveTable(ids[1]);
      final picked = actionPlayers(provider).single;
      expect(picked.id, sara.id);

      await provider.recordTransaction(
        playerId: picked.id,
        type: TransactionType.buyIn,
        amount: 1000,
        hostSignatureBase64: _hostSig,
      );

      // Charged to Sara, and NOT to the same-seat player on Table 1.
      expect(SessionService.playerTotalIn('session-1', sara.id), 1000);
      final ali = provider.players.firstWhere((p) => p.name == 'Ali');
      expect(SessionService.playerTotalIn('session-1', ali.id), 0);
      expect(SessionService.totalBuyIn('session-1'), 1000);
    });
  });

  group('8. identical seat numbers stay distinguishable', () {
    test('same seat on two tables resolves to different people',
        () async {
      final provider = await _provider();
      await provider.addTable(name: 'Table 2');
      final ids = TableService.tablesFor(_live).map((t) => t.id).toList();

      final a = await provider.addPlayer(
          name: 'Ali', seatNumber: 3, tableId: ids[0]);
      final s = await provider.addPlayer(
          name: 'Sara', seatNumber: 3, tableId: ids[1]);

      expect(a.seatNumber, s.seatNumber);
      expect(a.id, isNot(s.id));

      provider.setActiveTable(ids[0]);
      expect(actionPlayers(provider).single.id, a.id);
      provider.setActiveTable(ids[1]);
      expect(actionPlayers(provider).single.id, s.id);
    });

    test('the table label shown for each player is correct', () async {
      final provider = await _provider();
      await provider.addTable(name: 'Table 2');
      final ids = TableService.tablesFor(_live).map((t) => t.id).toList();

      final a = await provider.addPlayer(
          name: 'Ali', seatNumber: 3, tableId: ids[0]);
      final s = await provider.addPlayer(
          name: 'Sara', seatNumber: 3, tableId: ids[1]);

      // This is the subtitle the picker renders.
      expect(TableService.tableById(_live, a.tableId).name,
          TableService.tablesFor(_live)[0].name);
      expect(TableService.tableById(_live, s.tableId).name, 'Table 2');
    });
  });

  group('legacy backward compatibility', () {
    test('a null-tableId player appears on Table 1', () async {
      final provider = await _provider();
      // Created before any second table existed -> tableId stays null.
      final legacy = await provider.addPlayer(name: 'Old', seatNumber: 1);
      expect(legacy.tableId, isNull);

      await provider.addTable(name: 'Table 2');
      final ids = TableService.tablesFor(_live).map((t) => t.id).toList();

      provider.setActiveTable(ids[0]);
      expect(actionPlayers(provider).map((p) => p.id), contains(legacy.id),
          reason: 'playersAt() maps a null tableId to the first table');

      provider.setActiveTable(ids[1]);
      expect(actionPlayers(provider).map((p) => p.id),
          isNot(contains(legacy.id)));
    });

    test('a null-tableId player is labelled with the first table',
        () async {
      final provider = await _provider();
      final legacy = await provider.addPlayer(name: 'Old', seatNumber: 1);
      await provider.addTable(name: 'Table 2');

      // tableById(null) -> first table, matching where playersAt() puts
      // them, so the label can never contradict the list.
      expect(TableService.tableById(_live, legacy.tableId).id,
          TableService.tablesFor(_live).first.id);
    });
  });

  group('the session-wide list is still available', () {
    test('provider.players remains unscoped for Timeline/name lookups',
        () async {
      final provider = await _provider();
      await provider.addTable(name: 'Table 2');
      final ids = TableService.tablesFor(_live).map((t) => t.id).toList();

      await provider.addPlayer(name: 'Ali', seatNumber: 1, tableId: ids[0]);
      await provider.addPlayer(name: 'Sara', seatNumber: 2, tableId: ids[1]);

      provider.setActiveTable(ids[1]);

      // Scoped for actions...
      expect(actionPlayers(provider).length, 1);
      // ...but the full list is intact for resolving any transaction's
      // player name in the recent-activity feed.
      expect(provider.players.length, 2);
    });
  });
}
