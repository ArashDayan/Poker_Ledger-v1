// Step 3 — Cash-in / Credit / Marker capture.
//
// A chip Buy-in is never inferred as payment. The banker must choose.
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
  _tmp = await Directory.systemTemp.createTemp('pl_capture_');
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

  group('mapping', () {
    test('paid cash maps to cashInForChips', () {
      expect(FinancialCapture.typeForFunding(ChipFunding.paidCash),
          FinancialEventType.cashInForChips);
    });
    test('credit and marker both map to creditIssued', () {
      expect(FinancialCapture.typeForFunding(ChipFunding.credit),
          FinancialEventType.creditIssued);
      expect(FinancialCapture.typeForFunding(ChipFunding.marker),
          FinancialEventType.creditIssued);
      expect(FinancialCapture.markerRequiresSignature(ChipFunding.marker),
          isTrue);
      expect(FinancialCapture.markerRequiresSignature(ChipFunding.credit),
          isFalse);
    });
    test('skip maps to nothing', () {
      expect(FinancialCapture.typeForFunding(ChipFunding.notRecorded), isNull);
      expect(FinancialCapture.typeForCashOut(ChipCashOutFunding.notRecorded),
          isNull);
    });
    test('cash-out paid vs unbacked', () {
      expect(FinancialCapture.typeForCashOut(ChipCashOutFunding.paidCash),
          FinancialEventType.cashOutForChips);
      expect(FinancialCapture.typeForCashOut(ChipCashOutFunding.unbacked),
          FinancialEventType.cashOutUnbacked);
    });
  });

  group('writes', () {
    test('paid cash on a buy-in does not create a debt', () async {
      final e = await FinancialCapture.recordFunding(
        personId: _personId,
        currency: AppCurrency.usd,
        funding: ChipFunding.paidCash,
        amount: 1000,
        linkedTransactionId: 'tx-buyin-1',
      );
      expect(e, isNotNull);
      expect(e!.type, FinancialEventType.cashInForChips);
      expect(e.linkedTransactionId, 'tx-buyin-1');
      expect(_usd().recorded, isTrue);
      expect(_usd().amountMajor, 0);
    });

    test('credit on a buy-in creates a +debt', () async {
      await FinancialCapture.recordFunding(
        personId: _personId,
        currency: AppCurrency.usd,
        funding: ChipFunding.credit,
        amount: 1000,
      );
      expect(_usd().amountMajor, 1000);
      expect(_usd().playerOwes, isTrue);
    });

    test('marker without a signature is refused', () async {
      expect(
        () => FinancialCapture.recordFunding(
          personId: _personId,
          currency: AppCurrency.usd,
          funding: ChipFunding.marker,
          amount: 500,
        ),
        throwsA(isA<FinancialLedgerException>()),
      );
      expect(_usd().isNotRecorded, isTrue);
    });

    test('marker with a signature is creditIssued', () async {
      final e = await FinancialCapture.recordFunding(
        personId: _personId,
        currency: AppCurrency.usd,
        funding: ChipFunding.marker,
        amount: 500,
        signatureBase64: 'SIG',
      );
      expect(e!.type, FinancialEventType.creditIssued);
      expect(e.signatureBase64, 'SIG');
      expect(_usd().amountMajor, 500);
    });

    test('skip writes nothing', () async {
      final e = await FinancialCapture.recordFunding(
        personId: _personId,
        currency: AppCurrency.usd,
        funding: ChipFunding.notRecorded,
        amount: 1000,
      );
      expect(e, isNull);
      expect(_usd().isNotRecorded, isTrue);
    });

    test('no personId writes nothing', () async {
      final e = await FinancialCapture.recordFunding(
        personId: null,
        currency: AppCurrency.usd,
        funding: ChipFunding.paidCash,
        amount: 1000,
      );
      expect(e, isNull);
    });

    test('cash-out paid cash does not create a debt', () async {
      await FinancialCapture.recordCashOutFunding(
        personId: _personId,
        currency: AppCurrency.usd,
        funding: ChipCashOutFunding.paidCash,
        amount: 700,
      );
      expect(_usd().amountMajor, 0);
    });

    test('cash-out unbacked creates a +debt', () async {
      await FinancialCapture.recordCashOutFunding(
        personId: _personId,
        currency: AppCurrency.usd,
        funding: ChipCashOutFunding.unbacked,
        amount: 700,
      );
      expect(_usd().amountMajor, 700);
    });

    test('zero cash-out writes nothing', () async {
      final e = await FinancialCapture.recordCashOutFunding(
        personId: _personId,
        currency: AppCurrency.usd,
        funding: ChipCashOutFunding.paidCash,
        amount: 0,
      );
      expect(e, isNull);
      expect(_usd().isNotRecorded, isTrue);
    });

    test('a chip buy-in sitting in SessionService does not fund the account',
        () async {
      final session = PokerSession(
        id: 's1',
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
          amount: 1000,
          hostSignatureBase64: 'sig',
        ),
      );
      expect(SessionService.totalBuyIn(session.id), 1000);
      expect(_usd().isNotRecorded, isTrue);
    });

    test('credit then repay returns to settled', () async {
      await FinancialCapture.recordFunding(
        personId: _personId,
        currency: AppCurrency.usd,
        funding: ChipFunding.credit,
        amount: 500,
      );
      await FinancialLedgerService.record(
        personId: _personId,
        currency: AppCurrency.usd,
        type: FinancialEventType.creditRepaid,
        amount: 500,
      );
      expect(_usd().isSettled, isTrue);
    });
  });

  group('localization', () {
    test('EN/FA capture keys exist and differ', () {
      const keys = [
        'how_was_this_paid',
        'funding_paid_cash',
        'funding_credit',
        'funding_marker',
        'funding_not_recorded',
        'how_was_cashout_paid',
        'cashout_paid_cash',
        'cashout_unbacked',
        'record_credit_repaid',
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
