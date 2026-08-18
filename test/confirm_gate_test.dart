// Phase: Back / Cancel must never confirm a money write.
//
// The UI collects funding BEFORE SessionService / Chip / Financial
// writes. These tests lock the commit decision and the actual ledger
// effects of abort vs explicit confirm.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:poker_ledger/models/chip_movement.dart';
import 'package:poker_ledger/models/enums.dart';
import 'package:poker_ledger/models/financial_event.dart';
import 'package:poker_ledger/models/player.dart';
import 'package:poker_ledger/models/player_identity.dart';
import 'package:poker_ledger/models/session.dart';
import 'package:poker_ledger/models/transaction.dart';
import 'package:poker_ledger/services/confirm_gate.dart';
import 'package:poker_ledger/services/financial_capture.dart';
import 'package:poker_ledger/services/financial_ledger_service.dart';
import 'package:poker_ledger/services/hive_service.dart';
import 'package:poker_ledger/services/player_identity_service.dart';
import 'package:poker_ledger/services/session_service.dart';
import 'package:uuid/uuid.dart';

import 'test_helper.dart';

const _uuid = Uuid();
late Directory _tmp;
late String _personId;
late String _sessionId;
late String _playerId;

Future<void> _open() async {
  _tmp = await Directory.systemTemp.createTemp('pl_confirm_');
  Hive.init(_tmp.path);
  registerTestAdapters();
  await Hive.openBox<PokerSession>(HiveService.sessionsBox);
  await Hive.openBox<Player>(HiveService.playersBox);
  await Hive.openBox<LedgerTransaction>(HiveService.transactionsBox);
  await Hive.openBox(HiveService.settingsBox);
  await Hive.openBox<PlayerIdentity>(HiveService.playerIdentitiesBox);
  await Hive.openBox<FinancialEvent>(HiveService.financialEventsBox);
  await Hive.openBox<ChipMovement>(HiveService.chipMovementsBox);

  _personId = (await PlayerIdentityService.createNew('Ali'))!.id;
  _sessionId = _uuid.v4();
  await HiveService.sessions.put(
    _sessionId,
    PokerSession(
      id: _sessionId,
      name: 'Night',
      location: 'Home',
      dateTime: DateTime.now(),
      smallBlind: 1,
      bigBlind: 2,
      tableNumber: '1',
    ),
  );
  _playerId = _uuid.v4();
  await HiveService.players.put(
    _playerId,
    Player(
      id: _playerId,
      sessionId: _sessionId,
      name: 'Ali',
      seatNumber: 1,
      personId: _personId,
    ),
  );
}

Future<void> _close() async {
  await Hive.deleteFromDisk();
  if (await _tmp.exists()) await _tmp.delete(recursive: true);
}

/// Applies a commit plan the same way the UI must: write nothing on
/// abort; on confirm write the chip tx then the financial row.
Future<LedgerTransaction?> applyPlan(ChipMoneyCommitPlan plan) async {
  if (!plan.shouldCommit) return null;
  final tx = await SessionService.recordTransaction(
    sessionId: _sessionId,
    playerId: _playerId,
    type: plan.type,
    amount: plan.amount,
    hostSignatureBase64: 'sig',
  );
  if (plan.type == TransactionType.cashOut && plan.cashOutFunding != null) {
    await FinancialCapture.recordCashOutFunding(
      personId: _personId,
      currency: AppCurrency.usd,
      funding: plan.cashOutFunding!,
      amount: plan.amount,
      sessionId: _sessionId,
      linkedTransactionId: tx.id,
    );
  }
  if ((plan.type == TransactionType.buyIn ||
          plan.type == TransactionType.rebuy) &&
      plan.buyInFunding != null) {
    await FinancialCapture.recordFunding(
      personId: _personId,
      currency: AppCurrency.usd,
      funding: plan.buyInFunding!,
      amount: plan.amount,
      sessionId: _sessionId,
      linkedTransactionId: tx.id,
    );
  }
  return tx;
}

void main() {
  setUp(_open);
  tearDown(_close);

  group('ConfirmGate', () {
    test('null sheet result is abort, never a default', () {
      expect(ConfirmGate.aborted(null), isTrue);
      expect(ConfirmGate.aborted(ChipCashOutFunding.paidCash), isFalse);
      expect(ConfirmGate.aborted(ChipCashOutFunding.notRecorded), isFalse);
    });

    test('positive cash-out / buy-in / rebuy require funding', () {
      expect(ConfirmGate.fundingRequired(TransactionType.cashOut, 500), isTrue);
      expect(ConfirmGate.fundingRequired(TransactionType.buyIn, 1000), isTrue);
      expect(ConfirmGate.fundingRequired(TransactionType.rebuy, 200), isTrue);
      expect(ConfirmGate.fundingRequired(TransactionType.cashOut, 0), isFalse);
      expect(ConfirmGate.fundingRequired(TransactionType.rakeCollection, 50),
          isFalse);
    });
  });

  group('ChipMoneyCommitPlan — cash-out', () {
    test('explicit paid-cash confirm may commit', () {
      final plan = ChipMoneyCommitPlan.fromSheetResults(
        type: TransactionType.cashOut,
        amount: 700,
        cashOutFunding: ChipCashOutFunding.paidCash,
      );
      expect(plan.shouldCommit, isTrue);
      expect(plan.writesFinancialCashOut, isTrue);
      expect(plan.writesChipDistribution, isFalse);
    });

    test('Back before funding (null) does not commit', () {
      final plan = ChipMoneyCommitPlan.fromSheetResults(
        type: TransactionType.cashOut,
        amount: 700,
        cashOutFunding: null,
      );
      expect(plan.shouldCommit, isFalse);
      expect(plan.writesFinancialCashOut, isFalse);
      expect(plan.writesChipDistribution, isFalse);
    });

    test('dismiss flag does not commit even if a leftover value is present',
        () {
      final plan = ChipMoneyCommitPlan.fromSheetResults(
        type: TransactionType.cashOut,
        amount: 700,
        cashOutFunding: ChipCashOutFunding.paidCash,
        fundingSheetDismissed: true,
      );
      expect(plan.shouldCommit, isFalse);
    });

    test('explicit Skip — not recorded still commits the chip cash-out', () {
      final plan = ChipMoneyCommitPlan.fromSheetResults(
        type: TransactionType.cashOut,
        amount: 700,
        cashOutFunding: ChipCashOutFunding.notRecorded,
      );
      expect(plan.shouldCommit, isTrue);
      expect(plan.writesFinancialCashOut, isFalse);
    });

    test('\$0 bust does not require a funding sheet', () {
      final plan = ChipMoneyCommitPlan.fromSheetResults(
        type: TransactionType.cashOut,
        amount: 0,
      );
      expect(plan.shouldCommit, isTrue);
      expect(plan.writesFinancialCashOut, isFalse);
    });
  });

  group('ChipMoneyCommitPlan — buy-in / rebuy', () {
    test('dismissed funding aborts buy-in', () {
      final plan = ChipMoneyCommitPlan.fromSheetResults(
        type: TransactionType.buyIn,
        amount: 1000,
        buyInFunding: null,
      );
      expect(plan.shouldCommit, isFalse);
      expect(plan.writesFinancialBuyIn, isFalse);
    });

    test('explicit paid cash buy-in commits', () {
      final plan = ChipMoneyCommitPlan.fromSheetResults(
        type: TransactionType.buyIn,
        amount: 1000,
        buyInFunding: const ChipFundingChoice(ChipFunding.paidCash),
      );
      expect(plan.shouldCommit, isTrue);
      expect(plan.writesFinancialBuyIn, isTrue);
    });

    test('optional chip skip does not abort a confirmed buy-in', () {
      final plan = ChipMoneyCommitPlan.fromSheetResults(
        type: TransactionType.rebuy,
        amount: 200,
        buyInFunding: const ChipFundingChoice(ChipFunding.credit),
        chipDistribution: const {},
      );
      expect(plan.shouldCommit, isTrue);
      expect(plan.writesChipDistribution, isFalse);
    });
  });

  group('ledger effects', () {
    test('confirmed cash-out writes Session + Financial cashOutForChips',
        () async {
      final plan = ChipMoneyCommitPlan.fromSheetResults(
        type: TransactionType.cashOut,
        amount: 700,
        cashOutFunding: ChipCashOutFunding.paidCash,
      );
      final tx = await applyPlan(plan);
      expect(tx, isNotNull);
      expect(SessionService.playerTotalCashOut(_sessionId, _playerId), 700);
      final events = FinancialLedgerService.eventsFor(_personId);
      expect(events.length, 1);
      expect(events.single.type, FinancialEventType.cashOutForChips);
      expect(events.single.amountMajor, 700);
    });

    test('Back before funding writes nothing to any ledger', () async {
      final plan = ChipMoneyCommitPlan.fromSheetResults(
        type: TransactionType.cashOut,
        amount: 700,
        cashOutFunding: null,
      );
      final tx = await applyPlan(plan);
      expect(tx, isNull);
      expect(SessionService.playerTotalCashOut(_sessionId, _playerId), 0);
      expect(SessionService.hasCashedOut(_sessionId, _playerId), isFalse);
      expect(FinancialLedgerService.eventsFor(_personId), isEmpty);
      expect(
        FinancialLedgerService.accountFor(_personId).hasHistory,
        isFalse,
      );
      expect(HiveService.chipMovements.isEmpty, isTrue);
    });

    test('dismiss before funding writes nothing', () async {
      final plan = ChipMoneyCommitPlan.fromSheetResults(
        type: TransactionType.cashOut,
        amount: 400,
        fundingSheetDismissed: true,
      );
      expect(await applyPlan(plan), isNull);
      expect(SessionService.transactionsFor(_sessionId), isEmpty);
      expect(FinancialLedgerService.eventsFor(_personId), isEmpty);
    });

    test('explicit not-recorded cash-out writes Session only', () async {
      final plan = ChipMoneyCommitPlan.fromSheetResults(
        type: TransactionType.cashOut,
        amount: 300,
        cashOutFunding: ChipCashOutFunding.notRecorded,
      );
      await applyPlan(plan);
      expect(SessionService.playerTotalCashOut(_sessionId, _playerId), 300);
      expect(FinancialLedgerService.eventsFor(_personId), isEmpty);
    });

    test('aborted buy-in writes no seat money and no financial event',
        () async {
      final plan = ChipMoneyCommitPlan.fromSheetResults(
        type: TransactionType.buyIn,
        amount: 1000,
        buyInFunding: null,
      );
      expect(await applyPlan(plan), isNull);
      expect(SessionService.playerTotalIn(_sessionId, _playerId), 0);
      expect(FinancialLedgerService.eventsFor(_personId), isEmpty);
    });

    test('confirmed buy-in still writes cashInForChips', () async {
      final plan = ChipMoneyCommitPlan.fromSheetResults(
        type: TransactionType.buyIn,
        amount: 1000,
        buyInFunding: const ChipFundingChoice(ChipFunding.paidCash),
      );
      await applyPlan(plan);
      expect(SessionService.playerTotalIn(_sessionId, _playerId), 1000);
      expect(
        FinancialLedgerService.eventsFor(_personId).single.type,
        FinancialEventType.cashInForChips,
      );
    });
  });
}
