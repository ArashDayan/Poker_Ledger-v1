// Step 4 — Front Money deposit and return.
//
// Front money is cash the banker holds for a player. It is not a chip
// buy-in, not credit, and not a Discount/rebate event.
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

void main() {
  setUp(_open);
  tearDown(_close);

  group('front money writes', () {
    test('deposit makes the banker hold the cash', () async {
      final e = await FinancialCapture.recordFrontMoneyIn(
        personId: _personId,
        currency: AppCurrency.usd,
        amount: 2000,
      );
      expect(e, isNotNull);
      expect(e!.type, FinancialEventType.frontMoneyIn);
      expect(_usd().recorded, isTrue);
      expect(_usd().amountMajor, -2000);
      expect(_usd().bankerHolds, isTrue);
    });

    test('full return settles the held cash', () async {
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
      expect(_usd().amountMajor, 0);
      expect(_usd().isSettled, isTrue);
    });

    test('partial return leaves the remainder held', () async {
      await FinancialCapture.recordFrontMoneyIn(
        personId: _personId,
        currency: AppCurrency.usd,
        amount: 2000,
      );
      await FinancialCapture.recordFrontMoneyOut(
        personId: _personId,
        currency: AppCurrency.usd,
        amount: 500,
      );
      expect(_usd().amountMajor, -1500);
      expect(_usd().bankerHolds, isTrue);
    });

    test('cannot return more than is held', () async {
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
      expect(_usd().amountMajor, -200);
    });

    test('cannot return when nothing is held', () async {
      expect(
        () => FinancialCapture.recordFrontMoneyOut(
          personId: _personId,
          currency: AppCurrency.usd,
          amount: 100,
        ),
        throwsA(isA<FinancialLedgerException>()),
      );
      expect(_usd().isNotRecorded, isTrue);
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

  group('isolation', () {
    test('front money does not create a chip buy-in', () async {
      await FinancialCapture.recordFrontMoneyIn(
        personId: _personId,
        currency: AppCurrency.usd,
        amount: 2000,
        sessionId: 's-fm',
      );
      expect(HiveService.transactions.isEmpty, isTrue);
      expect(SessionService.totalBuyIn('s-fm'), 0);
    });

    test('a chip buy-in does not become front money', () async {
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
    });

    test('front money does not change host profit', () async {
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

    test('cash-in for chips is not front money', () async {
      await FinancialCapture.recordFunding(
        personId: _personId,
        currency: AppCurrency.usd,
        funding: ChipFunding.paidCash,
        amount: 1000,
      );
      expect(_usd().amountMajor, 0);
      expect(_usd().bankerHolds, isFalse);
      final events = FinancialLedgerService.eventsFor(_personId);
      expect(events.single.type, FinancialEventType.cashInForChips);
    });
  });

  group('localization', () {
    test('EN/FA front-money keys exist and differ', () {
      const keys = [
        'accept_front_money',
        'return_front_money',
        'front_money_in_hint',
        'front_money_out_hint',
        'fin_front_money_in',
        'fin_front_money_out',
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
