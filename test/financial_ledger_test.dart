// Step 2 — Financial Ledger foundation.
//
// Outstanding Balance is derived. cashIn/cashOutForChips never move it.
// Chip Ledger totals and Buy-in/Rebuy are never read. A missing history
// is "Not recorded", never 0.
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
import 'package:poker_ledger/services/backup_service.dart';
import 'package:poker_ledger/services/financial_ledger_service.dart';
import 'package:poker_ledger/services/hive_service.dart';
import 'package:poker_ledger/services/player_identity_service.dart';
import 'package:poker_ledger/services/session_service.dart';

import 'test_helper.dart';

late Directory _tmp;
late String _personId;

Future<void> _open() async {
  _tmp = await Directory.systemTemp.createTemp('pl_financial_');
  Hive.init(_tmp.path);
  registerTestAdapters();
  await Hive.openBox<PokerSession>(HiveService.sessionsBox);
  await Hive.openBox<Player>(HiveService.playersBox);
  await Hive.openBox<LedgerTransaction>(HiveService.transactionsBox);
  await Hive.openBox(HiveService.settingsBox);
  await Hive.openBox<PlayerIdentity>(HiveService.playerIdentitiesBox);
  await Hive.openBox<FinancialEvent>(HiveService.financialEventsBox);
  final identity = await PlayerIdentityService.createNew('Ali');
  _personId = identity!.id;
}

Future<void> _close() async {
  await Hive.deleteFromDisk();
  if (await _tmp.exists()) await _tmp.delete(recursive: true);
}

Future<FinancialEvent> _record(
  FinancialEventType type,
  double amount, {
  AppCurrency currency = AppCurrency.usd,
  int? adjustmentSign,
  String? reason,
  String? sessionId,
  String? linkedTransactionId,
  DateTime? occurredAt,
}) {
  return FinancialLedgerService.record(
    personId: _personId,
    currency: currency,
    type: type,
    amount: amount,
    adjustmentSign: adjustmentSign,
    reason: reason,
    sessionId: sessionId,
    linkedTransactionId: linkedTransactionId,
    occurredAt: occurredAt,
  );
}

OutstandingBalance _usd() =>
    FinancialLedgerService.balance(_personId, AppCurrency.usd);

OutstandingBalance _toman() =>
    FinancialLedgerService.balance(_personId, AppCurrency.toman);

void main() {
  setUp(_open);
  tearDown(_close);

  group('model / storage contract', () {
    test('typeIds 12–14 are the approved mapping', () {
      expect(const FinancialEventAdapter().typeId, 12);
      expect(const FinancialEventTypeAdapter().typeId, 13);
      expect(const PaymentMethodAdapter().typeId, 14);
    });

    test('USD exponent is 2 and Toman exponent is 0', () {
      expect(MoneyUnits.exponent(AppCurrency.usd), 2);
      expect(MoneyUnits.exponent(AppCurrency.toman), 0);
      expect(MoneyUnits.toMinor(AppCurrency.usd, 500), 50000);
      expect(MoneyUnits.toMajor(AppCurrency.usd, 50000), 500);
      expect(MoneyUnits.toMinor(AppCurrency.toman, 2000), 2000);
      expect(MoneyUnits.toMajor(AppCurrency.toman, 2000), 2000);
    });

    test('JSON round-trip keeps currency explicit', () async {
      final e = await _record(FinancialEventType.creditIssued, 500);
      final copy = FinancialEvent.fromJson(e.toJson());
      expect(copy.currency, AppCurrency.usd);
      expect(copy.amountMinor, 50000);
      expect(copy.personId, _personId);
      expect(copy.toJson().containsKey('currency'), isTrue);
    });

    test('amount must be positive', () async {
      expect(
        () => _record(FinancialEventType.creditIssued, 0),
        throwsArgumentError,
      );
      expect(
        () => _record(FinancialEventType.creditIssued, -10),
        throwsArgumentError,
      );
    });
  });

  group('approved balance formula', () {
    test('A. cashInForChips → 0', () async {
      await _record(FinancialEventType.cashInForChips, 500);
      expect(_usd().recorded, isTrue);
      expect(_usd().amountMajor, 0);
    });

    test('B. cashOutForChips → 0', () async {
      await _record(FinancialEventType.cashOutForChips, 500);
      expect(_usd().recorded, isTrue);
      expect(_usd().amountMajor, 0);
    });

    test('C. creditIssued 500 → +500', () async {
      await _record(FinancialEventType.creditIssued, 500);
      expect(_usd().amountMajor, 500);
      expect(_usd().playerOwes, isTrue);
    });

    test('D. creditIssued 500 + creditRepaid 500 → 0', () async {
      await _record(FinancialEventType.creditIssued, 500);
      await _record(FinancialEventType.creditRepaid, 500);
      expect(_usd().amountMajor, 0);
      expect(_usd().isSettled, isTrue);
    });

    test('E. frontMoneyIn 2000 → -2000', () async {
      await _record(FinancialEventType.frontMoneyIn, 2000);
      expect(_usd().amountMajor, -2000);
      expect(_usd().bankerHolds, isTrue);
    });

    test('F. frontMoneyIn 2000 + frontMoneyOut 2000 → 0', () async {
      await _record(FinancialEventType.frontMoneyIn, 2000);
      await _record(FinancialEventType.frontMoneyOut, 2000);
      expect(_usd().amountMajor, 0);
      expect(_usd().isSettled, isTrue);
    });

    test('G. cashOutUnbacked → positive balance', () async {
      await _record(FinancialEventType.cashOutUnbacked, 300);
      expect(_usd().amountMajor, 300);
      expect(_usd().playerOwes, isTrue);
    });

    test('H. reversal excludes the reversed event', () async {
      final issued = await _record(FinancialEventType.creditIssued, 500);
      expect(_usd().amountMajor, 500);
      final reversal = await FinancialLedgerService.reverse(issued.id);
      expect(reversal.isReversal, isTrue);
      expect(reversal.reversesEventId, issued.id);
      expect(_usd().amountMajor, 0);
      expect(_usd().recorded, isTrue);
      // Original is untouched — append-only.
      expect(HiveService.financialEvents.get(issued.id)!.amountMinor, 50000);
      expect(
        HiveService.financialEvents.get(issued.id)!.reversesEventId,
        isNull,
      );
    });

    test('I. adjustment changes balance and requires a reason', () async {
      await _record(FinancialEventType.creditIssued, 500);
      await _record(
        FinancialEventType.adjustment,
        100,
        adjustmentSign: 1,
        reason: 'missed marker from Friday',
      );
      expect(_usd().amountMajor, 600);

      expect(
        () => _record(
          FinancialEventType.adjustment,
          50,
          adjustmentSign: 1,
        ),
        throwsA(isA<FinancialLedgerException>()),
      );
      expect(
        () => _record(
          FinancialEventType.adjustment,
          50,
          reason: 'no sign',
        ),
        throwsA(isA<FinancialLedgerException>()),
      );

      await _record(
        FinancialEventType.adjustment,
        100,
        adjustmentSign: -1,
        reason: 'overstated the marker',
      );
      expect(_usd().amountMajor, 500);
    });

    test('J. multiple currencies never net against each other', () async {
      await _record(FinancialEventType.creditIssued, 500);
      await _record(
        FinancialEventType.creditIssued,
        500,
        currency: AppCurrency.toman,
      );
      expect(_usd().amountMajor, 500);
      expect(_toman().amountMajor, 500);
      expect(_usd().currency, AppCurrency.usd);
      expect(_toman().currency, AppCurrency.toman);
      final account = FinancialLedgerService.accountFor(_personId);
      expect(account.balances, hasLength(2));
      // There is no combined figure — each currency stands alone.
      expect(account.balances.every((b) => b.amountMajor == 500), isTrue);
    });

    test('K. no financial history → Not recorded, never 0', () {
      final b = _usd();
      expect(b.isNotRecorded, isTrue);
      expect(b.recorded, isFalse);
      final account = FinancialLedgerService.accountFor(_personId);
      expect(account.hasHistory, isFalse);
      expect(account.balances, isEmpty);
    });

    test('L. financial event remains writable after session close', () async {
      final session = PokerSession(
        id: 'closed-1',
        name: 'Ended night',
        location: 'Home',
        dateTime: DateTime.now(),
        smallBlind: 1,
        bigBlind: 2,
        tableNumber: '1',
        status: SessionStatus.ended,
      );
      await HiveService.sessions.put(session.id, session);

      expect(
        () => SessionService.assertSessionActive(session.id),
        throwsA(isA<SessionEndedException>()),
      );

      final event = await _record(
        FinancialEventType.creditIssued,
        250,
        sessionId: session.id,
      );
      expect(event.sessionId, session.id);
      expect(_usd().amountMajor, 250);
    });

    test('M. linkedTransactionId does not affect balance', () async {
      await _record(
        FinancialEventType.creditIssued,
        500,
        linkedTransactionId: 'chip-tx-buyin-1',
      );
      expect(_usd().amountMajor, 500);
      await _record(
        FinancialEventType.cashInForChips,
        500,
        linkedTransactionId: 'chip-tx-buyin-1',
      );
      // The linked chip buy-in is audit only. It does not cancel the
      // credit and does not count as repayment.
      expect(_usd().amountMajor, 500);
    });
  });

  group('reversal rules', () {
    test('reversal of a reversal is refused', () async {
      final issued = await _record(FinancialEventType.creditIssued, 500);
      final reversal = await FinancialLedgerService.reverse(issued.id);
      expect(
        () => FinancialLedgerService.reverse(reversal.id),
        throwsA(isA<FinancialLedgerException>()),
      );
    });

    test('a second reversal of the same event is refused', () async {
      final issued = await _record(FinancialEventType.creditIssued, 500);
      await FinancialLedgerService.reverse(issued.id);
      expect(
        () => FinancialLedgerService.reverse(issued.id),
        throwsA(isA<FinancialLedgerException>()),
      );
    });
  });

  group('isolation from the Chip Ledger', () {
    test('a buy-in sitting in the chip ledger does not create a balance',
        () async {
      final session = PokerSession(
        id: 's-chip',
        name: 'Live',
        location: 'Home',
        dateTime: DateTime.now(),
        smallBlind: 1,
        bigBlind: 2,
        tableNumber: '1',
      );
      await HiveService.sessions.put(session.id, session);
      await HiveService.transactions.put(
        'tx-1',
        LedgerTransaction(
          id: 'tx-1',
          sessionId: session.id,
          playerId: 'seat-1',
          type: TransactionType.buyIn,
          amount: 999,
          hostSignatureBase64: 'sig',
        ),
      );
      expect(_usd().isNotRecorded, isTrue);
      expect(SessionService.totalBuyIn(session.id), 999);
    });

    test('record refuses an unknown personId', () async {
      expect(
        () => FinancialLedgerService.record(
          personId: 'ghost',
          currency: AppCurrency.usd,
          type: FinancialEventType.creditIssued,
          amount: 10,
        ),
        throwsA(isA<FinancialLedgerException>()),
      );
    });
  });

  group('backup includes typed financial events', () {
    test('a valid event round-trips and a malformed one is skipped', () async {
      await _record(FinancialEventType.creditIssued, 500);
      final payload = BackupService.exportPayload();
      expect((payload['financialEvents'] as List), hasLength(1));

      await HiveService.financialEvents.clear();
      expect(_usd().isNotRecorded, isTrue);

      final result = await BackupService.importPayload(payload);
      expect(result.financialEventsImported, 1);
      expect(_usd().amountMajor, 500);

      final malformed = await BackupService.importPayload({
        'formatVersion': 5,
        'financialEvents': [
          {'id': 'fe-1', 'amount': 500},
        ],
      });
      expect(malformed.financialEventsSkipped, 1);
      expect(malformed.financialEventsReserved, 1);
      expect(HiveService.financialEvents.get('fe-1'), isNull);
    });
  });

  group('PlayerAccount is derived', () {
    test('account lists each currency separately', () async {
      await _record(FinancialEventType.creditIssued, 100);
      await _record(
        FinancialEventType.frontMoneyIn,
        2000,
        currency: AppCurrency.toman,
      );
      final account = FinancialLedgerService.accountFor(_personId);
      expect(account.hasHistory, isTrue);
      expect(account.balances, hasLength(2));
      expect(account.displayName, 'Ali');
    });
  });
}
