// Phase 1 — Pre-seat player registration.
//
// Registration and seating are separate concepts:
//   * a player can be registered for the session before any seat;
//   * seating/unseating moves only the seat pointer;
//   * financial history (transactions, financial events, identity)
//     survives every seat change by construction.
//
// These tests assert on the STORED records and on the derived seat
// logic (playersAt / occupiedSeats / checkBalance), which is what the
// UI and the settlement engine read.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:poker_ledger/models/enums.dart';
import 'package:poker_ledger/models/financial_event.dart';
import 'package:poker_ledger/models/hand.dart';
import 'package:poker_ledger/models/player.dart';
import 'package:poker_ledger/models/player_identity.dart';
import 'package:poker_ledger/models/session.dart';
import 'package:poker_ledger/models/transaction.dart';
import 'package:poker_ledger/providers/session_provider.dart';
import 'package:poker_ledger/services/deposit_to_chips.dart';
import 'package:poker_ledger/services/financial_ledger_service.dart';
import 'package:poker_ledger/services/hive_service.dart';
import 'package:poker_ledger/services/player_history_service.dart';
import 'package:poker_ledger/services/player_identity_service.dart';
import 'package:poker_ledger/services/session_service.dart';
import 'package:poker_ledger/services/table_service.dart';

import 'test_helper.dart';

late Directory _tmp;
bool _tmpInitialized = false;

Future<void> _open() async {
  if (!_tmpInitialized) {
    _tmp = await Directory.systemTemp.createTemp('pl_preset_');
    _tmpInitialized = true;
  }
  Hive.init(_tmp.path);
  registerTestAdapters();
  await Hive.openBox<PokerSession>(HiveService.sessionsBox);
  await Hive.openBox<Player>(HiveService.playersBox);
  await Hive.openBox<LedgerTransaction>(HiveService.transactionsBox);
  await Hive.openBox(HiveService.settingsBox);
  await Hive.openBox<PlayerIdentity>(HiveService.playerIdentitiesBox);
  await Hive.openBox<FinancialEvent>(HiveService.financialEventsBox);
  await Hive.openBox<Hand>(HiveService.handsBox);
}

Future<void> _close() async {
  await Hive.deleteFromDisk();
  if (_tmpInitialized && await _tmp.exists()) {
    await _tmp.delete(recursive: true);
  }
  _tmpInitialized = false;
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

Future<String> _person(String name) async =>
    (await PlayerIdentityService.createNew(name))!.id;

Player _stored(String id) => HiveService.players.get(id)!;

void main() {
  setUp(_open);
  tearDown(_close);

  group('registration without a seat', () {
    test('registerPlayer creates an unseated row with no money written',
        () async {
      final provider = await _provider();
      final pid = await _person('Ali');

      final player =
          await provider.registerPlayer(personId: pid, name: 'Ali');

      // Stored state: registered, not seated, no table.
      expect(player.seated, isFalse);
      expect(player.tableId, isNull);
      expect(player.personId, pid);
      expect(player.sessionId, 'session-1');

      // No transaction, financial event or money of any kind.
      expect(SessionService.transactionsFor('session-1'), isEmpty);
      expect(FinancialLedgerService.eventsFor(pid), isEmpty);
    });

    test('registration is idempotent per (session, person)', () async {
      final provider = await _provider();
      final pid = await _person('Ali');

      final first = await provider.registerPlayer(personId: pid, name: 'Ali');
      final second =
          await provider.registerPlayer(personId: pid, name: 'ALI  Reza');

      expect(second.id, first.id);
      expect(SessionService.playersFor('session-1').length, 1);
    });

    test('seated/unseated helpers partition the session roster', () async {
      final provider = await _provider();
      final pidA = await _person('Ali');
      final pidB = await _person('Reza');

      await provider.registerPlayer(personId: pidA, name: 'Ali');
      final seated =
          await provider.addPlayer(name: 'Reza', seatNumber: 1, personId: pidB);

      expect(provider.seatedPlayers.map((p) => p.id), [seated.id]);
      expect(provider.unseatedPlayers.map((p) => p.personId), [pidA]);
      // provider.players still sees the whole roster (name lookups).
      expect(provider.players.length, 2);
    });
  });

  group('seat logic never sees unseated players', () {
    test('unseated registration with null tableId does not occupy the first table',
        () async {
      final provider = await _provider();
      final pid = await _person('Ali');
      await provider.addTable(name: 'Table 2');
      final firstTable = TableService.tablesFor(_live).first.id;

      final unseated =
          await provider.registerPlayer(personId: pid, name: 'Ali');

      // The trap: tableId == null maps to the FIRST table for legacy
      // rows. An unseated row must NOT be absorbed by that mapping.
      expect(unseated.tableId, isNull);
      expect(TableService.playersAt(_live, firstTable), isEmpty);
      expect(TableService.playerCountAt(_live, firstTable), 0);
      expect(TableService.occupiedSeats(_live, firstTable), isEmpty);
      expect(TableService.firstFreeSeat(_live, firstTable), 1);
    });

    test('movePlayer refuses an unseated player', () async {
      final provider = await _provider();
      final pid = await _person('Ali');
      await provider.addTable(name: 'Table 2');
      final second = TableService.tablesFor(_live)[1].id;

      final unseated =
          await provider.registerPlayer(personId: pid, name: 'Ali');

      expect(
        () => TableService.movePlayer(_live, unseated, second),
        throwsStateError,
      );
    });

    test('checkBalance does not flag unseated players as never-cashed-out',
        () async {
      final provider = await _provider();
      final pid = await _person('Ali');
      await provider.registerPlayer(personId: pid, name: 'Ali');

      final result = SessionService.checkBalance('session-1');
      expect(result.playersNeverCashedOut, isEmpty);
    });

    test('DepositToChips.seatedPlayer ignores unseated registrations',
        () async {
      final provider = await _provider();
      final pid = await _person('Ali');
      await provider.registerPlayer(personId: pid, name: 'Ali');

      expect(DepositToChips.seatedPlayer('session-1', pid), isNull);

      final unseated = SessionService.unseatedPlayersFor('session-1').first;
      await provider.seatRegisteredPlayer(
          unseated, TableService.tablesFor(_live).first.id);
      expect(DepositToChips.seatedPlayer('session-1', pid), isNotNull);
    });
  });

  group('seating and unseating', () {
    test('seatRegisteredPlayer assigns a free seat and only seat fields',
        () async {
      final provider = await _provider();
      final pid = await _person('Ali');
      final unseated = await provider.registerPlayer(personId: pid, name: 'Ali');
      final tableId = TableService.tablesFor(_live).first.id;

      // A financial fact exists BEFORE seating — it must survive.
      await FinancialLedgerService.record(
        personId: pid,
        currency: AppCurrency.usd,
        type: FinancialEventType.frontMoneyIn,
        amount: 100,
        sessionId: 'session-1',
      );
      final before = FinancialLedgerService.balance(pid, AppCurrency.usd);
      expect(before.amountMinor, -10000);

      await provider.seatRegisteredPlayer(unseated, tableId);
      final seated = _stored(unseated.id);

      expect(seated.seated, isTrue);
      expect(seated.tableId, tableId);
      expect(seated.seatNumber, 1);
      expect(TableService.playersAt(_live, tableId).map((p) => p.id),
          [seated.id]);
      expect(TableService.occupiedSeats(_live, tableId), {1});

      // Seating wrote no money and changed no financial state.
      expect(SessionService.transactionsFor('session-1'), isEmpty);
      final after = FinancialLedgerService.balance(pid, AppCurrency.usd);
      expect(after.amountMinor, before.amountMinor);
    });

    test('seating into a full table throws; explicit taken seat throws',
        () async {
      final provider = await _provider();
      final pidA = await _person('Ali');
      final pidB = await _person('Reza');
      final a = await provider.registerPlayer(personId: pidA, name: 'Ali');
      final b = await provider.registerPlayer(personId: pidB, name: 'Reza');
      final tableId = TableService.tablesFor(_live).first.id;
      final table = TableService.tableById(_live, tableId);

      // Fill every seat with other players.
      for (var i = 1; i <= table.seatCount; i++) {
        await provider.addPlayer(name: 'Filler $i', seatNumber: i);
      }
      expect(() => provider.seatRegisteredPlayer(a, tableId), throwsStateError);
      // A valid row, but the table is full: explicit seat cannot save it.
      expect(
          () => provider.seatRegisteredPlayer(b, tableId, seat: 1),
          throwsStateError);
    });

    test('seating an already-seated player is a no-op', () async {
      final provider = await _provider();
      final pid = await _person('Ali');
      final a = await provider.registerPlayer(personId: pid, name: 'Ali');
      final tableId = TableService.tablesFor(_live).first.id;
      await provider.seatRegisteredPlayer(a, tableId);
      final again = await provider.seatRegisteredPlayer(a, tableId);
      expect(again.seatNumber, 1);
      expect(provider.unseatedPlayers, isEmpty);
    });

    test('unseatPlayer frees the seat and preserves every record',
        () async {
      final provider = await _provider();
      final pid = await _person('Ali');
      final a = await provider.registerPlayer(personId: pid, name: 'Ali');
      final tableId = TableService.tablesFor(_live).first.id;
      await provider.seatRegisteredPlayer(a, tableId);

      // Play some money while seated.
      await SessionService.recordTransaction(
        sessionId: 'session-1',
        playerId: a.id,
        type: TransactionType.buyIn,
        amount: 500,
        hostSignatureBase64: 'sig',
        tableId: tableId,
      );
      expect(SessionService.playerTotalIn('session-1', a.id), 500);

      // Unseat.
      await provider.unseatPlayer(_stored(a.id));
      final now = _stored(a.id);

      // Seat is gone…
      expect(now.seated, isFalse);
      expect(now.tableId, isNull);
      expect(TableService.playersAt(_live, tableId), isEmpty);
      expect(TableService.occupiedSeats(_live, tableId), isEmpty);
      expect(TableService.firstFreeSeat(_live, tableId), 1);

      // …and the history is exactly as it was.
      expect(now.personId, pid);
      expect(SessionService.playerTotalIn('session-1', a.id), 500);
      expect(SessionService.transactionsFor('session-1').length, 1);
      // The career keeps this session: unseated BUT has records.
      expect(PlayerHistoryService.recordFor(now), isNotNull);

      // The seat can be taken by someone else immediately.
      final pid2 = await _person('Reza');
      final b = await provider.registerPlayer(personId: pid2, name: 'Reza');
      await provider.seatRegisteredPlayer(b, tableId);
      expect(_stored(b.id).seatNumber, 1);
    });

    test('unseating is idempotent and keeps the registration listed',
        () async {
      final provider = await _provider();
      final pid = await _person('Ali');
      final a = await provider.registerPlayer(personId: pid, name: 'Ali');
      await provider.unseatPlayer(a);
      await provider.unseatPlayer(_stored(a.id)); // no-op
      expect(provider.unseatedPlayers.map((p) => p.id), [a.id]);
    });
  });

  group('career and history integrity', () {
    test('a fresh unseated registration is not a session appearance',
        () async {
      final provider = await _provider();
      final pid = await _person('Ali');
      final a = await provider.registerPlayer(personId: pid, name: 'Ali');
      expect(PlayerHistoryService.recordFor(a), isNull);
    });
  });

  group('removal rules', () {
    test('a clean unseated registration can be removed; the person survives',
        () async {
      final provider = await _provider();
      final pid = await _person('Ali');
      final a = await provider.registerPlayer(personId: pid, name: 'Ali');

      await provider.removeRegistration(a);

      expect(HiveService.players.get(a.id), isNull);
      // The identity (and everything attached to it) is untouched.
      expect(PlayerIdentityService.byId(pid), isNotNull);
    });

    test('an unseated registration WITH records cannot be removed', () async {
      final provider = await _provider();
      final pid = await _person('Ali');
      final a = await provider.registerPlayer(personId: pid, name: 'Ali');
      final tableId = TableService.tablesFor(_live).first.id;
      await provider.seatRegisteredPlayer(a, tableId);
      await SessionService.recordTransaction(
        sessionId: 'session-1',
        playerId: a.id,
        type: TransactionType.buyIn,
        amount: 100,
        hostSignatureBase64: 'sig',
        tableId: tableId,
      );
      await provider.unseatPlayer(_stored(a.id));

      expect(() => provider.removeRegistration(_stored(a.id)),
          throwsStateError);
      // Still there, with the record.
      expect(HiveService.players.get(a.id), isNotNull);
      expect(SessionService.playerTotalIn('session-1', a.id), 100);
    });

    test('a seated player cannot be removed directly', () async {
      final provider = await _provider();
      final pid = await _person('Ali');
      final a = await provider.registerPlayer(personId: pid, name: 'Ali');
      final tableId = TableService.tablesFor(_live).first.id;
      await provider.seatRegisteredPlayer(a, tableId);

      expect(() => provider.removeRegistration(_stored(a.id)),
          throwsStateError);
    });
  });

  group('persistence', () {
    test('seated flag survives a close/reopen round-trip', () async {
      final provider = await _provider();
      final pidA = await _person('Ali');
      final pidB = await _person('Reza');
      final a = await provider.registerPlayer(personId: pidA, name: 'Ali');
      final b = await provider.addPlayer(name: 'Reza', seatNumber: 1, personId: pidB);

      await Hive.close();
    await _open();

      final a2 = HiveService.players.get(a.id)!;
      final b2 = HiveService.players.get(b.id)!;
      expect(a2.seated, isFalse);
      expect(b2.seated, isTrue); // default for the add-player path
    });

    test('JSON round-trip preserves seated and defaults legacy rows to seated',
        () async {
      final p = Player(id: 'x', sessionId: 's', name: 'Ali', seatNumber: 0, seated: false);
      final decoded = Player.fromJson(p.toJson());
      expect(decoded.seated, isFalse);

      // A JSON written before the field existed has no 'seated' key.
      final legacy = p.toJson()..remove('seated');
      expect(Player.fromJson(legacy).seated, isTrue);
    });
  });

  group('financial invariants', () {
    test('seat operations never change the Financial Ledger (F-1/F-4)',
        () async {
      final provider = await _provider();
      final pid = await _person('Ali');
      await FinancialLedgerService.record(
        personId: pid,
        currency: AppCurrency.usd,
        type: FinancialEventType.frontMoneyIn,
        amount: 10000,
        sessionId: 'session-1',
      );
      final baseline = FinancialLedgerService.eventsFor(pid).length;
      final balance0 =
          FinancialLedgerService.balance(pid, AppCurrency.usd).amountMinor;

      final a = await provider.registerPlayer(personId: pid, name: 'Ali');
      final tableId = TableService.tablesFor(_live).first.id;
      await provider.seatRegisteredPlayer(a, tableId);
      await provider.unseatPlayer(_stored(a.id));
      await provider.seatRegisteredPlayer(_stored(a.id), tableId);

      expect(FinancialLedgerService.eventsFor(pid).length, baseline);
      expect(
          FinancialLedgerService.balance(pid, AppCurrency.usd).amountMinor,
          balance0);
      // outstanding = -1000000 (banker holds), formula intact.
      expect(balance0, -1000000);
    });

    test('append-only: registration/seating writes no transaction rows',
        () async {
      final provider = await _provider();
      final pid = await _person('Ali');
      final a = await provider.registerPlayer(personId: pid, name: 'Ali');
      final tableId = TableService.tablesFor(_live).first.id;
      await provider.seatRegisteredPlayer(a, tableId);
      await provider.unseatPlayer(_stored(a.id));

      expect(SessionService.transactionsFor('session-1',
          includeVoided: true),
          isEmpty);
    });
  });
}
