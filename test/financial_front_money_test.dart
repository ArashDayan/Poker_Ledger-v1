// Step 4 — Deposit (internal type: front money).
//
// A Deposit is cash the banker holds. It is not a chip buy-in, not
// credit, and not a Discount/rebate base until explicitly converted.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:poker_ledger/core/localization/app_localizations.dart';
import 'package:poker_ledger/models/enums.dart';
import 'package:poker_ledger/models/financial_event.dart';
import 'package:poker_ledger/models/player.dart';
import 'package:poker_ledger/models/player_identity.dart';
import 'package:poker_ledger/models/session.dart';
import 'package:poker_ledger/models/transaction.dart';
import 'package:poker_ledger/services/deposit_to_chips.dart';
import 'package:poker_ledger/services/financial_capture.dart';
import 'package:poker_ledger/services/financial_ledger_service.dart';
import 'package:poker_ledger/services/hive_service.dart';
import 'package:poker_ledger/services/player_identity_service.dart';
import 'package:poker_ledger/services/session_service.dart';

import 'test_helper.dart';

late Directory _tmp;
late String _personId;

Future<void> _open() async {
  _tmp = await Directory.systemTemp.createTemp('pl_front_money_');
  Hive.init(_tmp.path);
  registerTestAdapters();
  await Hive.openBox<PokerSession>(HiveService.sessionsBox);
  await Hive.openBox<Player>(HiveService.playersBox);
  await Hive.openBox<LedgerTransaction>(HiveService.transactionsBox);
  await Hive.openBox(HiveService.settingsBox);
  await Hive.openBox<PlayerIdentity>(HiveService.playerIdentitiesBox);
  await Hive.openBox<FinancialEvent>(HiveService.financialEventsBox);
  _personId = (await PlayerIdentityService.createNew('Ali'))!.id;
}

Future<void> _close() async {
  await Hive.deleteFromDisk();
  if (await _tmp.exists()) await _tmp.delete(recursive: true);
}

OutstandingBalance _usd() =>
    FinancialLedgerService.balance(_personId, AppCurrency.usd);

double _deposit() =>
    FinancialLedgerService.depositHeldMajor(_personId, AppCurrency.usd);

double _cashInSum() {
  return FinancialLedgerService.eventsFor(_personId,
          currency: AppCurrency.usd)
      .where((e) =>
          e.type == FinancialEventType.cashInForChips && !e.isReversal)
      .fold<double>(0, (s, e) => s + e.amountMajor);
}

Future<Player> _seat(String sessionId) async {
  final player = Player(
    id: 'seat-1',
    sessionId: sessionId,
    name: 'Ali',
    seatNumber: 1,
    personId: _personId,
  );
  await HiveService.players.put(player.id, player);
  return player;
}

void main() {
  setUp(_open);
  tearDown(_close);

  group('deposit writes', () {
    test('deposit $1000 is held and is not cashInForChips', () async {
      final e = await FinancialCapture.recordFrontMoneyIn(
        personId: _personId,
        currency: AppCurrency.usd,
        amount: 1000,
      );
      expect(e!.type, FinancialEventType.frontMoneyIn);
      expect(_deposit(), 1000);
      expect(_usd().amountMajor, -1000);
      expect(_cashInSum(), 0);
      expect(HiveService.transactions.isEmpty, isTrue);
    });

    test('full return settles the deposit', () async {
      await FinancialCapture.recordFrontMoneyIn(
        personId: _personId,
        currency: AppCurrency.usd,
        amount: 2000,
      );
      final out = await FinancialCapture.recordFrontMoneyOut(
        personId: _personId,
        currency: AppCurrency.usd,
        amount: 2000,
      );
      expect(out!.type, FinancialEventType.frontMoneyOut);
      expect(_deposit(), 0);
      expect(_usd().isSettled, isTrue);
    });

    test('cannot return more than remaining deposit', () async {
      await FinancialCapture.recordFrontMoneyIn(
        personId: _personId,
        currency: AppCurrency.usd,
        amount: 200,
      );
      expect(
        () => FinancialCapture.recordFrontMoneyOut(
          personId: _personId,
          currency: AppCurrency.usd,
          amount: 201,
        ),
        throwsA(isA<FinancialLedgerException>()),
      );
      expect(_deposit(), 200);
    });

    test('no personId writes nothing', () async {
      final e = await FinancialCapture.recordFrontMoneyIn(
        personId: null,
        currency: AppCurrency.usd,
        amount: 100,
      );
      expect(e, isNull);
    });

    test('zero amount writes nothing', () async {
      final e = await FinancialCapture.recordFrontMoneyIn(
        personId: _personId,
        currency: AppCurrency.usd,
        amount: 0,
      );
      expect(e, isNull);
      expect(_usd().isNotRecorded, isTrue);
    });
  });

  group('use deposit for chips', () {
    test('deposit 1000 then convert 600 leaves 400 and writes cash-in',
        () async {
      final session = PokerSession(
        id: 's-dep',
        name: 'Night',
        location: 'Home',
        dateTime: DateTime.now(),
        smallBlind: 1,
        bigBlind: 2,
        tableNumber: '1',
      );
      await HiveService.sessions.put(session.id, session);
      final player = await _seat(session.id);

      await FinancialCapture.recordFrontMoneyIn(
        personId: _personId,
        currency: AppCurrency.usd,
        amount: 1000,
        sessionId: session.id,
      );

      final result = await DepositToChips.convert(
        personId: _personId,
        sessionId: session.id,
        playerId: player.id,
        currency: AppCurrency.usd,
        amount: 600,
        hostSignatureBase64: 'sig',
      );

      expect(result.frontMoneyOut.type, FinancialEventType.frontMoneyOut);
      expect(result.frontMoneyOut.amountMajor, 600);
      expect(result.cashInForChips.type, FinancialEventType.cashInForChips);
      expect(result.cashInForChips.amountMajor, 600);
      expect(result.frontMoneyOut.linkedTransactionId, result.chipTransaction.id);
      expect(result.cashInForChips.linkedTransactionId, result.chipTransaction.id);
      expect(result.chipTransaction.amount, 600);
      expect(result.chipTransaction.type, TransactionType.buyIn);
      expect(result.chipTransaction.playerId, player.id);

      expect(_deposit(), 400);
      expect(_cashInSum(), 600);
      expect(SessionService.totalBuyIn(session.id), 600);
      expect(SessionService.playerTotalIn(session.id, player.id), 600);
      // Outstanding: deposit remaining only. cashInForChips contributes 0.
      expect(_usd().amountMajor, -400);
      expect(SessionService.hostProfit(session.id), 0);
    });

    test('returning remaining 400 writes only frontMoneyOut', () async {
      final session = PokerSession(
        id: 's-ret',
        name: 'Night',
        location: 'Home',
        dateTime: DateTime.now(),
        smallBlind: 1,
        bigBlind: 2,
        tableNumber: '1',
      );
      await HiveService.sessions.put(session.id, session);
      final player = await _seat(session.id);
      await FinancialCapture.recordFrontMoneyIn(
        personId: _personId,
        currency: AppCurrency.usd,
        amount: 1000,
        sessionId: session.id,
      );
      await DepositToChips.convert(
        personId: _personId,
        sessionId: session.id,
        playerId: player.id,
        currency: AppCurrency.usd,
        amount: 600,
        hostSignatureBase64: 'sig',
      );

      final out = await FinancialCapture.recordFrontMoneyOut(
        personId: _personId,
        currency: AppCurrency.usd,
        amount: 400,
        sessionId: session.id,
      );
      expect(out!.type, FinancialEventType.frontMoneyOut);
      expect(_deposit(), 0);
      expect(_cashInSum(), 600);
      expect(
        FinancialLedgerService.eventsFor(_personId)
            .where((e) => e.type == FinancialEventType.cashOutForChips),
        isEmpty,
      );
      expect(SessionService.totalCashOut(session.id), 0);
    });

    test('deposit itself is never a Discount base', () async {
      await FinancialCapture.recordFrontMoneyIn(
        personId: _personId,
        currency: AppCurrency.usd,
        amount: 1000,
      );
      // No conversion → no cash-in. Rebate (Step 6) reads cashInForChips
      // only, so an unused deposit cannot qualify.
      expect(_cashInSum(), 0);
      expect(
        FinancialLedgerService.eventsFor(_personId)
            .every((e) => e.type.index <= 7),
        isTrue,
      );
    });

    test('cannot convert more than remaining deposit', () async {
      final session = PokerSession(
        id: 's-over',
        name: 'Night',
        location: 'Home',
        dateTime: DateTime.now(),
        smallBlind: 1,
        bigBlind: 2,
        tableNumber: '1',
      );
      await HiveService.sessions.put(session.id, session);
      final player = await _seat(session.id);
      await FinancialCapture.recordFrontMoneyIn(
        personId: _personId,
        currency: AppCurrency.usd,
        amount: 1000,
      );
      expect(
        () => DepositToChips.convert(
          personId: _personId,
          sessionId: session.id,
          playerId: player.id,
          currency: AppCurrency.usd,
          amount: 1001,
          hostSignatureBase64: 'sig',
        ),
        throwsA(isA<FinancialLedgerException>()),
      );
      expect(SessionService.totalBuyIn(session.id), 0);
      expect(_deposit(), 1000);
    });

    test('a second convert uses rebuy and does not double-count', () async {
      final session = PokerSession(
        id: 's-two',
        name: 'Night',
        location: 'Home',
        dateTime: DateTime.now(),
        smallBlind: 1,
        bigBlind: 2,
        tableNumber: '1',
      );
      await HiveService.sessions.put(session.id, session);
      final player = await _seat(session.id);
      await FinancialCapture.recordFrontMoneyIn(
        personId: _personId,
        currency: AppCurrency.usd,
        amount: 1000,
      );
      await DepositToChips.convert(
        personId: _personId,
        sessionId: session.id,
        playerId: player.id,
        currency: AppCurrency.usd,
        amount: 600,
        hostSignatureBase64: 'sig',
      );
      final second = await DepositToChips.convert(
        personId: _personId,
        sessionId: session.id,
        playerId: player.id,
        currency: AppCurrency.usd,
        amount: 400,
        hostSignatureBase64: 'sig',
      );
      expect(second.chipTransaction.type, TransactionType.rebuy);
      expect(SessionService.totalBuyIn(session.id), 600);
      expect(SessionService.totalRebuy(session.id), 400);
      expect(_cashInSum(), 1000);
      expect(_deposit(), 0);
    });
  });

  group('isolation', () {
    test('accepting a deposit does not create a chip buy-in', () async {
      await FinancialCapture.recordFrontMoneyIn(
        personId: _personId,
        currency: AppCurrency.usd,
        amount: 2000,
        sessionId: 's-fm',
      );
      expect(HiveService.transactions.isEmpty, isTrue);
      expect(SessionService.totalBuyIn('s-fm'), 0);
    });

    test('a chip buy-in is not inferred as a deposit', () async {
      final session = PokerSession(
        id: 's-chip',
        name: 'Night',
        location: 'Home',
        dateTime: DateTime.now(),
        smallBlind: 1,
        bigBlind: 2,
        tableNumber: '1',
      );
      await HiveService.sessions.put(session.id, session);
      await HiveService.transactions.put(
        'tx1',
        LedgerTransaction(
          id: 'tx1',
          sessionId: session.id,
          playerId: 'seat-1',
          type: TransactionType.buyIn,
          amount: 2000,
          hostSignatureBase64: 'sig',
        ),
      );
      expect(SessionService.totalBuyIn(session.id), 2000);
      expect(_usd().isNotRecorded, isTrue);
      expect(_deposit(), 0);
    });

    test('deposit does not change host profit', () async {
      final session = PokerSession(
        id: 's-rake',
        name: 'Night',
        location: 'Home',
        dateTime: DateTime.now(),
        smallBlind: 1,
        bigBlind: 2,
        tableNumber: '1',
      );
      await HiveService.sessions.put(session.id, session);
      await HiveService.transactions.put(
        'rake-1',
        LedgerTransaction(
          id: 'rake-1',
          sessionId: session.id,
          type: TransactionType.rakeCollection,
          amount: 50,
          hostSignatureBase64: '',
        ),
      );
      expect(SessionService.hostProfit(session.id), 50);
      await FinancialCapture.recordFrontMoneyIn(
        personId: _personId,
        currency: AppCurrency.usd,
        amount: 2000,
        sessionId: session.id,
      );
      expect(SessionService.hostProfit(session.id), 50);
      expect(SessionService.hostProfit(session.id),
          SessionService.totalRake(session.id));
    });
  });

  group('localization', () {
    test('EN/FA deposit keys exist and differ', () {
      const keys = [
        'accept_deposit',
        'return_deposit',
        'use_deposit_for_chips',
        'remaining_deposit',
        'deposit_in_hint',
        'deposit_out_hint',
        'deposit_use_chips_hint',
        'fin_deposit_in',
        'fin_deposit_out',
      ];
      for (final key in keys) {
        final en = AppLocalizations.lookup('en', key);
        final fa = AppLocalizations.lookup('fa', key);
        expect(en, isNot(key), reason: key);
        expect(fa, isNot(key), reason: key);
        expect(en, isNot(fa), reason: key);
      }
    });
  });
}
