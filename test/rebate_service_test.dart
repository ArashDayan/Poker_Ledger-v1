// Step 6 — Loss rebate / Discount.
//
// Own-cash only. Types 8/9 contribute 0 to Outstanding Balance.
// SessionService formulas are never read or written.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:poker_ledger/core/localization/app_localizations.dart';
import 'package:poker_ledger/models/chip_movement.dart';
import 'package:poker_ledger/models/chip_type.dart';
import 'package:poker_ledger/models/enums.dart';
import 'package:poker_ledger/models/financial_event.dart';
import 'package:poker_ledger/models/player.dart';
import 'package:poker_ledger/models/player_identity.dart';
import 'package:poker_ledger/models/session.dart';
import 'package:poker_ledger/models/transaction.dart';
import 'package:poker_ledger/services/chip_tracking_service.dart';
import 'package:poker_ledger/services/deposit_to_chips.dart';
import 'package:poker_ledger/services/financial_capture.dart';
import 'package:poker_ledger/services/financial_ledger_service.dart';
import 'package:poker_ledger/services/hive_service.dart';
import 'package:poker_ledger/services/player_identity_service.dart';
import 'package:poker_ledger/services/rebate_service.dart';
import 'package:poker_ledger/services/session_service.dart';
import 'package:poker_ledger/widgets/rebate_grant_sheet.dart';

import 'test_helper.dart';

late Directory _tmp;
late String _personId;
late String _otherId;

Future<void> _open() async {
  _tmp = await Directory.systemTemp.createTemp('pl_rebate_');
  Hive.init(_tmp.path);
  registerTestAdapters();
  await Hive.openBox<PokerSession>(HiveService.sessionsBox);
  await Hive.openBox<Player>(HiveService.playersBox);
  await Hive.openBox<LedgerTransaction>(HiveService.transactionsBox);
  await Hive.openBox(HiveService.settingsBox);
  await Hive.openBox<PlayerIdentity>(HiveService.playerIdentitiesBox);
  await Hive.openBox<FinancialEvent>(HiveService.financialEventsBox);
  await Hive.openBox<ChipType>(HiveService.chipsBox);
  await Hive.openBox<ChipMovement>(HiveService.chipMovementsBox);
  _personId = (await PlayerIdentityService.createNew('Ali'))!.id;
  _otherId = (await PlayerIdentityService.createNew('Baba'))!.id;
}

Future<void> _close() async {
  await Hive.deleteFromDisk();
  if (await _tmp.exists()) await _tmp.delete(recursive: true);
}

Future<PokerSession> _session(
  String id, {
  bool rebate = true,
  double minLoss = 1000,
  double percent = 10,
  SessionMode mode = SessionMode.cashGame,
  DateTime? start,
  DateTime? plannedEnd,
}) async {
  final s = PokerSession(
    id: id,
    name: 'Night',
    location: 'Home',
    dateTime: start ?? DateTime.now(),
    smallBlind: 1,
    bigBlind: 2,
    tableNumber: '1',
    mode: mode,
    rebateEnabled: rebate,
    rebateMinLoss: minLoss,
    rebatePercent: percent,
    plannedEndAt: plannedEnd,
  );
  await HiveService.sessions.put(s.id, s);
  return s;
}

Future<Player> _seat(String sessionId, {String id = 'seat-1'}) async {
  final p = Player(
    id: id,
    sessionId: sessionId,
    name: 'Ali',
    seatNumber: 1,
    personId: _personId,
  );
  await HiveService.players.put(p.id, p);
  return p;
}

Future<void> _cashIn(
  String sessionId,
  double amount, {
  String? personId,
  DateTime? at,
}) {
  return FinancialLedgerService.record(
    personId: personId ?? _personId,
    currency: AppCurrency.usd,
    type: FinancialEventType.cashInForChips,
    amount: amount,
    sessionId: sessionId,
    occurredAt: at,
  );
}

Future<FinancialEvent> _cashOut(
  String sessionId,
  double amount, {
  String? personId,
  String? linked,
  DateTime? at,
}) {
  return FinancialLedgerService.record(
    personId: personId ?? _personId,
    currency: AppCurrency.usd,
    type: FinancialEventType.cashOutForChips,
    amount: amount,
    sessionId: sessionId,
    linkedTransactionId: linked,
    occurredAt: at,
  );
}

RebateSnapshot _snap(String sessionId, {String? personId}) =>
    RebateService.snapshot(
      sessionId: sessionId,
      personId: personId ?? _personId,
      currency: AppCurrency.usd,
    );

void main() {
  setUp(_open);
  tearDown(_close);

  group('types and isolation', () {
    test('23. rebate event types use Hive bytes 8 and 9', () {
      expect(FinancialEventType.rebateGranted.index, 8);
      expect(FinancialEventType.rebateRecovered.index, 9);
      final adapter = FinancialEventTypeAdapter();
      expect(adapter.typeId, 13);
    });

    test('rebate events contribute 0 to Outstanding Balance', () async {
      final s = await _session('s-bal');
      await FinancialLedgerService.record(
        personId: _personId,
        currency: AppCurrency.usd,
        type: FinancialEventType.rebateGranted,
        amount: 150,
        sessionId: s.id,
        baseLossMinor: 150000,
        grantedAsChips: false,
      );
      await FinancialLedgerService.record(
        personId: _personId,
        currency: AppCurrency.usd,
        type: FinancialEventType.rebateRecovered,
        amount: 70,
        sessionId: s.id,
        reason: RebateRecoveryKind.lostInPlay,
      );
      final b = FinancialLedgerService.balance(_personId, AppCurrency.usd);
      expect(b.amountMinor, 0);
      expect(
        FinancialLedgerService.contributionOf(
          HiveService.financialEvents.values.firstWhere(
            (e) => e.type == FinancialEventType.rebateGranted,
          ),
        ),
        0,
      );
    });
  });

  group('eligibility origin', () {
    test('1. no cash-in → no eligible Discount', () async {
      final s = await _session('s1');
      final sug = RebateService.suggest(
        sessionId: s.id,
        personId: _personId,
        currency: AppCurrency.usd,
      );
      expect(sug.canGrant, isFalse);
      expect(_snap(s.id).grossLoss, 0);
    });

    test('2. Buy-in alone is not cash payment', () async {
      final s = await _session('s2');
      final p = await _seat(s.id);
      await SessionService.recordTransaction(
        sessionId: s.id,
        playerId: p.id,
        type: TransactionType.buyIn,
        amount: 1500,
        hostSignatureBase64: 'sig',
      );
      expect(SessionService.totalBuyIn(s.id), 1500);
      final sug = RebateService.suggest(
        sessionId: s.id,
        personId: _personId,
        currency: AppCurrency.usd,
      );
      expect(sug.canGrant, isFalse);
      expect(_snap(s.id).playerCashIn, 0);
    });

    test('3. paid cash-in is eligible only after a realized cash-out', () async {
      final s = await _session('s3');
      await _cashIn(s.id, 1500);
      expect(
        RebateService.suggest(
          sessionId: s.id,
          personId: _personId,
          currency: AppCurrency.usd,
        ).canGrant,
        isFalse,
      );
      final sug = RebateService.suggest(
        sessionId: s.id,
        personId: _personId,
        currency: AppCurrency.usd,
        bustRealized: true,
      );
      expect(sug.canGrant, isTrue);
      expect(sug.grantMinor, 15000);
      expect(sug.eligibleLossMinor, 150000);
    });

    test('4. Credit is not eligible', () async {
      final s = await _session('s4');
      await FinancialCapture.recordFunding(
        personId: _personId,
        currency: AppCurrency.usd,
        funding: ChipFunding.credit,
        amount: 1500,
        sessionId: s.id,
      );
      expect(
        RebateService.suggest(
          sessionId: s.id,
          personId: _personId,
          currency: AppCurrency.usd,
        ).canGrant,
        isFalse,
      );
    });

    test('5. Marker is not eligible', () async {
      final s = await _session('s5');
      await FinancialCapture.recordFunding(
        personId: _personId,
        currency: AppCurrency.usd,
        funding: ChipFunding.marker,
        amount: 1500,
        sessionId: s.id,
        signatureBase64: 'mark',
      );
      expect(
        RebateService.suggest(
          sessionId: s.id,
          personId: _personId,
          currency: AppCurrency.usd,
        ).canGrant,
        isFalse,
      );
    });

    test('6. unconverted Deposit is not eligible', () async {
      final s = await _session('s6');
      await FinancialCapture.recordFrontMoneyIn(
        personId: _personId,
        currency: AppCurrency.usd,
        amount: 1500,
        sessionId: s.id,
      );
      expect(_snap(s.id).playerCashIn, 0);
      expect(
        RebateService.suggest(
          sessionId: s.id,
          personId: _personId,
          currency: AppCurrency.usd,
        ).canGrant,
        isFalse,
      );
    });

    test('7. Deposit → Chips cash-in becomes eligible', () async {
      final s = await _session('s7');
      final p = await _seat(s.id);
      await FinancialCapture.recordFrontMoneyIn(
        personId: _personId,
        currency: AppCurrency.usd,
        amount: 1500,
        sessionId: s.id,
      );
      await DepositToChips.convert(
        personId: _personId,
        sessionId: s.id,
        playerId: p.id,
        currency: AppCurrency.usd,
        amount: 1500,
        hostSignatureBase64: 'sig',
      );
      expect(_snap(s.id).playerCashIn, 1500);
      expect(
        RebateService.suggest(
          sessionId: s.id,
          personId: _personId,
          currency: AppCurrency.usd,
          bustRealized: true,
        ).canGrant,
        isTrue,
      );
    });

    test('8. chip transfer creates no cash-in', () async {
      final s = await _session('s8');
      await HiveService.chips.put(
        'c100',
        ChipType(id: 'c100', value: 100, quantity: 50),
      );
      await ChipTrackingService.recordPlayerTransfer(
        fromPlayerId: 'seat-other',
        toPlayerId: 'seat-1',
        distribution: {'c100': 10},
        sessionId: s.id,
      );
      expect(_snap(s.id).playerCashIn, 0);
      expect(
        RebateService.suggest(
          sessionId: s.id,
          personId: _personId,
          currency: AppCurrency.usd,
        ).canGrant,
        isFalse,
      );
    });

    test('9. chips won from another player create no cash-in', () async {
      final s = await _session('s9');
      await _cashIn(s.id, 1500, personId: _otherId);
      expect(_snap(s.id).playerCashIn, 0);
      expect(_snap(s.id, personId: _otherId).playerCashIn, 1500);
    });
  });

  group('economic example and recovery', () {
    test('canonical \$1500 / \$150 / \$80 / \$70 / house \$1420', () async {
      final s = await _session('econ');
      await _cashIn(s.id, 1500);
      await RebateService.grant(
        sessionId: s.id,
        personId: _personId,
        currency: AppCurrency.usd,
        asChips: true,
        bustRealized: true,
      );
      var snap = _snap(s.id);
      expect(snap.granted, 150);
      expect(snap.playerCashIn, 1500);
      expect(FinancialLedgerService.balance(_personId, AppCurrency.usd).amountMinor, 0);
      expect(SessionService.hostProfit(s.id), 0);
      expect(SessionService.checkBalance(s.id).moneyIn, 0);

      final plan = RebateService.previewRealization(
        sessionId: s.id,
        personId: _personId,
        currency: AppCurrency.usd,
        cashOutMinor: 8000,
      );
      expect(plan.actualCashPaidMinor, 8000);
      expect(plan.returnedMinor, 7000);
      expect(plan.paidOutFromDiscountMinor, 8000);
      expect(plan.clawbackMinor, 0);
      expect(plan.recoveryKind, RebateRecoveryKind.lostInPlay);

      await _cashOut(s.id, 80);
      await Future.delayed(const Duration(milliseconds: 30));
      await RebateService.realizeCashOut(
        sessionId: s.id,
        personId: _personId,
        currency: AppCurrency.usd,
        cashOutMinor: 8000,
      );
      snap = _snap(s.id);
      expect(snap.playerCashIn, 1500);
      expect(snap.playerCashOut, 80);
      expect(snap.granted, 150);
      expect(snap.returned, 70);
      expect(snap.paidOut, 80);
      expect(snap.exposed, 0);
      expect(snap.actualCashPaid, 80);
      expect(snap.houseRetained, 1420);
      expect(snap.lostInPlay, 70);
      expect(snap.clawback, 0);
      expect(snap.playerEconomicNet, -1420);
      // Cash-out row is not reduced by the $80 that was paid out.
      expect(
        FinancialLedgerService.snapshotForSession(
          s.id,
          currency: AppCurrency.usd,
          personId: _personId,
        ).cashOutForChips,
        80,
      );
    });

    test('11. \$150 grant + \$80 cash-out recovers \$70, player receives \$80',
        () async {
      final s = await _session('s11', minLoss: 100);
      await _cashIn(s.id, 1500);
      await RebateService.grant(
        sessionId: s.id,
        personId: _personId,
        currency: AppCurrency.usd,
        asChips: true,
        bustRealized: true,
      );
      await _cashOut(s.id, 80);
      await Future.delayed(const Duration(milliseconds: 30));
      await RebateService.realizeCashOut(
        sessionId: s.id,
        personId: _personId,
        currency: AppCurrency.usd,
        cashOutMinor: 8000,
      );
      final snap = _snap(s.id);
      expect(snap.returned, 70);
      expect(snap.actualCashPaid, 80);
      expect(snap.paidOut, 80);
    });

    test('12. cash-out above remaining grant reconciles remaining entitlement',
        () async {
      final s = await _session('s12');
      await _cashIn(s.id, 1500);
      await RebateService.grant(
        sessionId: s.id,
        personId: _personId,
        currency: AppCurrency.usd,
        asChips: true,
        bustRealized: true,
      );
      final plan = RebateService.previewRealization(
        sessionId: s.id,
        personId: _personId,
        currency: AppCurrency.usd,
        cashOutMinor: 250000,
      );
      // C=$2,500 > L+G; remaining loss 0; recon = G = $150; paid $2,350.
      expect(plan.clawbackMinor, 15000);
      expect(plan.actualCashPaidMinor, 235000);
      expect(plan.returnedMinor, 15000);
      await _cashOut(s.id, 2500);
      await RebateService.realizeCashOut(
        sessionId: s.id,
        personId: _personId,
        currency: AppCurrency.usd,
        cashOutMinor: 250000,
      );
      final snap = _snap(s.id);
      expect(snap.paidOut, 0);
      expect(snap.returned, 150);
      expect(snap.actualCashPaid, 2350);
      expect(snap.houseRetained, 1500 - 2350);
    });

    test('13. multiple cash-outs do not invent a second \$150', () async {
      final s = await _session('s13');
      await _cashIn(s.id, 1500);
      await Future.delayed(const Duration(milliseconds: 30));
      await RebateService.grant(
        sessionId: s.id,
        personId: _personId,
        currency: AppCurrency.usd,
        asChips: true,
        bustRealized: true,
      );
      await Future.delayed(const Duration(milliseconds: 30));
      await _cashOut(s.id, 80);
      await Future.delayed(const Duration(milliseconds: 30));
      await RebateService.realizeCashOut(
        sessionId: s.id,
        personId: _personId,
        currency: AppCurrency.usd,
        cashOutMinor: 8000,
      );
      final later = RebateService.previewRealization(
        sessionId: s.id,
        personId: _personId,
        currency: AppCurrency.usd,
        cashOutMinor: 20000,
      );
      expect(later.exposedBeforeMinor, 0);
      expect(later.returnedMinor, 0);
      await Future.delayed(const Duration(milliseconds: 30));
      await _cashOut(s.id, 200);
      await RebateService.realizeCashOut(
        sessionId: s.id,
        personId: _personId,
        currency: AppCurrency.usd,
        cashOutMinor: 20000,
      );
      expect(_snap(s.id).granted, 150);
      expect(_snap(s.id).returned, 70);
    });

    test('14/15. later own cash is a new cycle and must meet the minimum',
        () async {
      final s = await _session('s14');
      await _cashIn(s.id, 1500);
      await RebateService.grant(
        sessionId: s.id,
        personId: _personId,
        currency: AppCurrency.usd,
        asChips: true,
        bustRealized: true,
      );
      await _cashOut(s.id, 80);
      await Future.delayed(const Duration(milliseconds: 30));
      await RebateService.realizeCashOut(
        sessionId: s.id,
        personId: _personId,
        currency: AppCurrency.usd,
        cashOutMinor: 8000,
      );
      expect(_snap(s.id).playerCashIn, 1500);
      await _cashIn(s.id, 500);
      expect(_snap(s.id).playerCashIn, 2000);
      final sug = RebateService.suggest(
        sessionId: s.id,
        personId: _personId,
        currency: AppCurrency.usd,
        bustRealized: true,
      );
      // New cycle loss = $500 < session minimum $1,000.
      expect(sug.alreadyQualified, isTrue);
      expect(sug.incrementalLossMinor, 50000);
      expect(sug.canGrant, isFalse);
      expect(sug.blockReason, contains('minimum'));
    });

    test('10. losing rebate then new own cash only rebates the new cash',
        () async {
      final s = await _session('s10b');
      await _cashIn(s.id, 1500);
      await RebateService.grant(
        sessionId: s.id,
        personId: _personId,
        currency: AppCurrency.usd,
        asChips: true,
        bustRealized: true,
      );
      // Leave with nothing of the grant — treat as $0.01 dust so the
      // ledger can store a positive minor amount, then realise.
      await FinancialLedgerService.record(
        personId: _personId,
        currency: AppCurrency.usd,
        type: FinancialEventType.cashOutForChips,
        amount: 0.01,
        sessionId: s.id,
      );
      await RebateService.realizeCashOut(
        sessionId: s.id,
        personId: _personId,
        currency: AppCurrency.usd,
        cashOutMinor: 1,
      );
      expect(_snap(s.id).returned, closeTo(149.99, 0.001));
      await _cashIn(s.id, 500);
      final sug = RebateService.suggest(
        sessionId: s.id,
        personId: _personId,
        currency: AppCurrency.usd,
        bustRealized: true,
      );
      // New cycle loss ≈ $500, below the $1,000 minimum.
      expect(sug.canGrant, isFalse);
      expect(sug.blockReason, contains('minimum'));
    });
  });

  group('session isolation and config', () {
    test('16. Session A Discount does not affect Session B', () async {
      final a = await _session('sa');
      final b = await _session('sb');
      await _cashIn(a.id, 1500);
      await RebateService.grant(
        sessionId: a.id,
        personId: _personId,
        currency: AppCurrency.usd,
        asChips: false,
        bustRealized: true,
      );
      expect(_snap(a.id).granted, 150);
      expect(_snap(b.id).granted, 0);
      expect(_snap(b.id).playerCashIn, 0);
    });

    test('tournament sessions never suggest Discount', () async {
      final s = await _session('tour', mode: SessionMode.tournament);
      await _cashIn(s.id, 1500);
      expect(
        RebateService.suggest(
          sessionId: s.id,
          personId: _personId,
          currency: AppCurrency.usd,
        ).canGrant,
        isFalse,
      );
    });

    test('below minimum at cash-out → no rebate', () async {
      final s = await _session('min');
      await _cashIn(s.id, 1000);
      await _cashOut(s.id, 400);
      // GrossLoss = 600 < 1000
      expect(
        RebateService.suggest(
          sessionId: s.id,
          personId: _personId,
          currency: AppCurrency.usd,
        ).canGrant,
        isFalse,
      );
    });
  });

  group('deposit remaining and reversals', () {
    test('17. remaining Deposit is not eligible loss', () async {
      final s = await _session('dep');
      await FinancialCapture.recordFrontMoneyIn(
        personId: _personId,
        currency: AppCurrency.usd,
        amount: 2000,
        sessionId: s.id,
      );
      await _cashIn(s.id, 400);
      expect(_snap(s.id).grossLoss, 400);
      expect(
        RebateService.suggest(
          sessionId: s.id,
          personId: _personId,
          currency: AppCurrency.usd,
        ).canGrant,
        isFalse,
      );
    });

    test('18. reversed grant is excluded', () async {
      final s = await _session('rev');
      await _cashIn(s.id, 1500);
      final g = await RebateService.grant(
        sessionId: s.id,
        personId: _personId,
        currency: AppCurrency.usd,
        asChips: false,
        bustRealized: true,
      );
      await RebateService.reverseGrant(g.id);
      expect(_snap(s.id).granted, 0);
      expect(_snap(s.id).exposed, 0);
    });

    test('19. void + linked reverse of recovery is auditable', () async {
      final s = await _session('void');
      await _cashIn(s.id, 1500);
      await RebateService.grant(
        sessionId: s.id,
        personId: _personId,
        currency: AppCurrency.usd,
        asChips: true,
        bustRealized: true,
      );
      final cashOut = await _cashOut(s.id, 80, linked: 'tx-co');
      final rec = await RebateService.realizeCashOut(
        sessionId: s.id,
        personId: _personId,
        currency: AppCurrency.usd,
        cashOutMinor: 8000,
        linkedTransactionId: cashOut.id,
      );
      expect(rec, isNotNull);
      expect(
        FinancialLedgerService.activeEventsLinkedTo(cashOut.id),
        hasLength(1),
      );
      await FinancialLedgerService.reverseLinkedTo(cashOut.id);
      await FinancialLedgerService.reverse(cashOut.id);
      expect(_snap(s.id).returned, 0);
      expect(_snap(s.id).exposed, 150);
      expect(HiveService.financialEvents.get(rec!.id), isNotNull);
    });

    test('20. grant is not created until banker confirms', () async {
      final s = await _session('conf');
      await _cashIn(s.id, 1500);
      final sug = RebateService.suggest(
        sessionId: s.id,
        personId: _personId,
        currency: AppCurrency.usd,
        bustRealized: true,
      );
      expect(sug.canGrant, isTrue);
      expect(_snap(s.id).granted, 0);
      await RebateService.grant(
        sessionId: s.id,
        personId: _personId,
        currency: AppCurrency.usd,
        asChips: false,
        bustRealized: true,
      );
      expect(_snap(s.id).granted, 150);
    });
  });

  group('cash vs chips', () {
    test('21/22. cash and chip grants are distinguished; chips are not buy-in',
        () async {
      final s = await _session('form');
      await _seat(s.id);
      await _cashIn(s.id, 1500);
      final grant = await RebateService.grant(
        sessionId: s.id,
        personId: _personId,
        currency: AppCurrency.usd,
        asChips: true,
        bustRealized: true,
      );
      await HiveService.chips.put(
        'c50',
        ChipType(id: 'c50', value: 50, quantity: 20),
      );
      await RebateService.issueGrantChips(
        grantEvent: grant,
        playerId: 'seat-1',
        distribution: {'c50': 3},
      );
      expect(grant.grantedAsChips, isTrue);
      expect(_snap(s.id).chipGrant, 150);
      expect(_snap(s.id).cashGrant, 0);
      expect(SessionService.totalBuyIn(s.id), 0);
      expect(SessionService.totalRebuy(s.id), 0);
      expect(SessionService.hostProfit(s.id), 0);
      final moves = ChipTrackingService.allMovements(sessionId: s.id);
      expect(moves, hasLength(1));
      expect(moves.first.reasonEnum, ChipMovementReason.lossRebate);
      expect(moves.first.transactionId, grant.id);
    });

    test('chip grant does not change frozen settlement formulas', () async {
      final s = await _session('settle');
      final p = await _seat(s.id);
      await SessionService.recordTransaction(
        sessionId: s.id,
        playerId: p.id,
        type: TransactionType.buyIn,
        amount: 1500,
        hostSignatureBase64: 'sig',
      );
      await _cashIn(s.id, 1500);
      await RebateService.grant(
        sessionId: s.id,
        personId: _personId,
        currency: AppCurrency.usd,
        asChips: true,
        bustRealized: true,
      );
      expect(SessionService.checkBalance(s.id).moneyIn, 1500);
      expect(SessionService.moneyStillInPlay(s.id), 1500);
      expect(SessionService.hostProfit(s.id), SessionService.totalRake(s.id));
      expect(
        RebateService.chipGrantsIssuedMinor(s.id, AppCurrency.usd),
        15000,
      );
    });
  });

  group('realization gates and origin', () {
    test('sitting with chips and no cash-out cannot grant', () async {
      final s = await _session('sit');
      await _cashIn(s.id, 1500);
      final sug = RebateService.suggest(
        sessionId: s.id,
        personId: _personId,
        currency: AppCurrency.usd,
      );
      expect(sug.canGrant, isFalse);
      expect(sug.blockReason, contains('realized'));
    });

    test('12b. \$0 bust realises loss and allows a grant', () async {
      final s = await _session('bust');
      await _cashIn(s.id, 1500);
      final plan = RebateService.previewRealization(
        sessionId: s.id,
        personId: _personId,
        currency: AppCurrency.usd,
        cashOutMinor: 0,
      );
      expect(plan.closesGrant, isFalse);
      expect(plan.actualCashPaidMinor, 0);
      expect(
        await FinancialCapture.recordCashOutFunding(
          personId: _personId,
          currency: AppCurrency.usd,
          funding: ChipCashOutFunding.paidCash,
          amount: 0,
          sessionId: s.id,
        ),
        isNull,
      );
      final sug = RebateService.suggest(
        sessionId: s.id,
        personId: _personId,
        currency: AppCurrency.usd,
        bustRealized: true,
      );
      expect(sug.canGrant, isTrue);
      expect(sug.grantMinor, 15000);
      await RebateService.grant(
        sessionId: s.id,
        personId: _personId,
        currency: AppCurrency.usd,
        asChips: false,
        bustRealized: true,
      );
      expect(_snap(s.id).granted, 150);
      expect(
        FinancialLedgerService.eventsForSession(
          s.id,
          personId: _personId,
          currency: AppCurrency.usd,
        ).where((e) => e.type == FinancialEventType.cashOutForChips),
        isEmpty,
      );
      expect(
        FinancialLedgerService.balance(_personId, AppCurrency.usd).amountMinor,
        0,
      );
    });

    test('13b. not-recorded cash-out does not invent cashOutForChips', () async {
      final s = await _session('unfunded');
      await _cashIn(s.id, 1500);
      await RebateService.grant(
        sessionId: s.id,
        personId: _personId,
        currency: AppCurrency.usd,
        asChips: true,
        bustRealized: true,
      );
      final sug = RebateService.suggest(
        sessionId: s.id,
        personId: _personId,
        currency: AppCurrency.usd,
        chipCashOutWithoutFunding: true,
      );
      expect(sug.canGrant, isFalse);
      expect(sug.blockReason, contains('not recorded'));
      expect(_snap(s.id).playerCashOut, 0);
      expect(_snap(s.id).hasOwnCashOutEvent, isFalse);
    });

    test('P2P transfer does not move Discount eligibility', () async {
      final s = await _session('p2p');
      await _cashIn(s.id, 1500);
      await RebateService.grant(
        sessionId: s.id,
        personId: _personId,
        currency: AppCurrency.usd,
        asChips: true,
        bustRealized: true,
      );
      await HiveService.chips.put(
        'c25',
        ChipType(id: 'c25', value: 25, quantity: 20),
      );
      await ChipTrackingService.recordPlayerTransfer(
        fromPlayerId: 'seat-1',
        toPlayerId: 'seat-2',
        distribution: {'c25': 4},
        sessionId: s.id,
      );
      expect(_snap(s.id).granted, 150);
      expect(_snap(s.id, personId: _otherId).granted, 0);
      expect(_snap(s.id, personId: _otherId).playerCashIn, 0);
      expect(
        RebateService.suggest(
          sessionId: s.id,
          personId: _otherId,
          currency: AppCurrency.usd,
          bustRealized: true,
        ).canGrant,
        isFalse,
      );
    });

    test('Case C reconciles remaining entitlement, not the full grant',
        () async {
      final s = await _session('casec');
      await _cashIn(s.id, 1500);
      await RebateService.grant(
        sessionId: s.id,
        personId: _personId,
        currency: AppCurrency.usd,
        asChips: true,
        bustRealized: true,
      );
      final plan = RebateService.previewRealization(
        sessionId: s.id,
        personId: _personId,
        currency: AppCurrency.usd,
        cashOutMinor: 20000,
      );
      // C=$200: remaining loss $1,300; entitlement $130; recon $20; paid $180.
      expect(plan.exposedBeforeMinor, 15000);
      expect(plan.remainingLossMinor, 130000);
      expect(plan.remainingEntitlementMinor, 13000);
      expect(plan.clawbackMinor, 2000);
      expect(plan.actualCashPaidMinor, 18000);
      expect(plan.recoveryKind, RebateRecoveryKind.clawback);
    });

    test('Discount chips are a reconciling item, not Money In', () async {
      final s = await _session('recon');
      final p = await _seat(s.id);
      await SessionService.recordTransaction(
        sessionId: s.id,
        playerId: p.id,
        type: TransactionType.buyIn,
        amount: 1500,
        hostSignatureBase64: 'sig',
      );
      await _cashIn(s.id, 1500);
      await RebateService.grant(
        sessionId: s.id,
        personId: _personId,
        currency: AppCurrency.usd,
        asChips: true,
        bustRealized: true,
      );
      await SessionService.recordTransaction(
        sessionId: s.id,
        playerId: p.id,
        type: TransactionType.cashOut,
        amount: 1650,
        hostSignatureBase64: 'sig',
      );
      final books = SessionService.checkBalance(s.id);
      expect(books.moneyIn, 1500);
      expect(books.moneyOut, 1650);
      expect(books.discrepancy, -150);
      expect(SessionService.hostProfit(s.id), 0);
      final rec = RebateService.chipReconciliation(
        sessionId: s.id,
        currency: AppCurrency.usd,
        rawDiscrepancy: books.discrepancy,
        moneyStillInPlay: SessionService.moneyStillInPlay(s.id),
      );
      expect(rec.issuedMajor, 150);
      expect(rec.explainsGap, isTrue);
    });
  });

  group('close-out C1–C5', () {
    test('askRebateGrant accepts bust and unfunded flags', () {
      Future<FinancialEvent?> Function(
        BuildContext, {
        required String sessionId,
        required String personId,
        required AppCurrency currency,
        String? playerId,
        bool bustRealized,
        bool chipCashOutWithoutFunding,
      }) fn = askRebateGrant;
      expect(fn, isNotNull);
    });

    test('lost-in-play journals after cash-out even if the sheet is dismissed',
        () async {
      final s = await _session('dismiss');
      await _cashIn(s.id, 1500);
      await RebateService.grant(
        sessionId: s.id,
        personId: _personId,
        currency: AppCurrency.usd,
        asChips: false,
        bustRealized: true,
      );
      await _cashOut(s.id, 80);
      final plan = RebateService.previewRealization(
        sessionId: s.id,
        personId: _personId,
        currency: AppCurrency.usd,
        cashOutMinor: 8000,
      );
      expect(plan.returnedMinor, 7000);
      expect(plan.clawbackMinor, 0);
      expect(plan.actualCashPaidMinor, 8000);
      expect(plan.recoveryKind, RebateRecoveryKind.lostInPlay);
      expect(
        RebateService.shouldPersistRealization(plan, confirmed: null),
        isTrue,
      );
      expect(
        RebateService.shouldPersistRealization(plan, confirmed: false),
        isTrue,
      );
      final first = await RebateService.realizeCashOut(
        sessionId: s.id,
        personId: _personId,
        currency: AppCurrency.usd,
        cashOutMinor: 8000,
      );
      expect(first, isNotNull);
      expect(first!.reason, RebateRecoveryKind.lostInPlay);
      expect(first.amountMajor, 70);
      final snap = _snap(s.id);
      expect(snap.playerCashOut, 80);
      expect(snap.granted, 150);
      expect(snap.lostInPlay, 70);
      expect(snap.clawback, 0);
      expect(snap.actualCashPaid, 80);
      expect(snap.houseRetained, 1420);
      expect(snap.paidOut, 80);
      expect(snap.exposed, 0);
      expect(
        FinancialLedgerService.snapshotForSession(
          s.id,
          currency: AppCurrency.usd,
          personId: _personId,
        ).cashOutForChips,
        80,
      );
      final second = await RebateService.realizeCashOut(
        sessionId: s.id,
        personId: _personId,
        currency: AppCurrency.usd,
        cashOutMinor: 8000,
      );
      expect(second, isNull);
      expect(
        FinancialLedgerService.eventsForSession(
          s.id,
          personId: _personId,
          currency: AppCurrency.usd,
        )
            .where((e) =>
                e.type == FinancialEventType.rebateRecovered && !e.isReversal)
            .length,
        1,
      );
    });

    test('clawback still requires confirm and is not lost-in-play', () async {
      final s = await _session('claw');
      await _cashIn(s.id, 1500);
      await RebateService.grant(
        sessionId: s.id,
        personId: _personId,
        currency: AppCurrency.usd,
        asChips: false,
        bustRealized: true,
      );
      final plan = RebateService.previewRealization(
        sessionId: s.id,
        personId: _personId,
        currency: AppCurrency.usd,
        cashOutMinor: 250000,
      );
      expect(plan.clawbackMinor, 15000);
      expect(plan.recoveryKind, RebateRecoveryKind.clawback);
      expect(
        RebateService.shouldPersistRealization(plan, confirmed: null),
        isFalse,
      );
      expect(
        RebateService.shouldPersistRealization(plan, confirmed: false),
        isFalse,
      );
      expect(
        RebateService.shouldPersistRealization(plan, confirmed: true),
        isTrue,
      );
    });

    test('chip Discount cannot be recorded without issuing chips', () async {
      final s = await _session('nochip');
      await _seat(s.id);
      await _cashIn(s.id, 1500);
      expect(
        () => RebateService.grantAsChips(
          sessionId: s.id,
          personId: _personId,
          currency: AppCurrency.usd,
          playerId: 'seat-1',
          distribution: const {},
          bustRealized: true,
        ),
        throwsA(isA<FinancialLedgerException>()),
      );
      expect(_snap(s.id).granted, 0);
      expect(_snap(s.id).chipGrant, 0);
      expect(
        RebateService.chipGrantsIssuedMinor(s.id, AppCurrency.usd),
        0,
      );
    });

    test('cash Discount stays off the chip books', () async {
      final s = await _session('cashform');
      final p = await _seat(s.id);
      await SessionService.recordTransaction(
        sessionId: s.id,
        playerId: p.id,
        type: TransactionType.buyIn,
        amount: 1500,
        hostSignatureBase64: 'sig',
      );
      await _cashIn(s.id, 1500);
      await RebateService.grant(
        sessionId: s.id,
        personId: _personId,
        currency: AppCurrency.usd,
        asChips: false,
        bustRealized: true,
      );
      expect(_snap(s.id).cashGrant, 150);
      expect(_snap(s.id).chipGrant, 0);
      expect(SessionService.checkBalance(s.id).moneyIn, 1500);
      expect(SessionService.moneyStillInPlay(s.id), 1500);
      expect(SessionService.hostProfit(s.id), 0);
      expect(
        RebateService.chipGrantsIssuedMinor(s.id, AppCurrency.usd),
        0,
      );
      expect(ChipTrackingService.allMovements(sessionId: s.id), isEmpty);
    });

    test('grantAsChips writes the flag only after chips move', () async {
      final s = await _session('chipok');
      await _seat(s.id);
      await _cashIn(s.id, 1500);
      await HiveService.chips.put(
        'c50',
        ChipType(id: 'c50', value: 50, quantity: 20),
      );
      final grant = await RebateService.grantAsChips(
        sessionId: s.id,
        personId: _personId,
        currency: AppCurrency.usd,
        playerId: 'seat-1',
        distribution: const {'c50': 3},
        bustRealized: true,
      );
      expect(grant.grantedAsChips, isTrue);
      expect(_snap(s.id).chipGrant, 150);
      expect(SessionService.totalBuyIn(s.id), 0);
      final moves = ChipTrackingService.allMovements(sessionId: s.id);
      expect(moves, hasLength(1));
      expect(moves.first.reasonEnum, ChipMovementReason.lossRebate);
      expect(moves.first.transactionId, grant.id);
    });
  });

  group('localization', () {
    test('24. EN/FA rebate keys exist and differ', () {
      const keys = [
        'rebate_title',
        'rebate_granted',
        'rebate_returned',
        'rebate_paid_out',
        'rebate_house_retained',
        'rebate_lost_in_play',
        'rebate_clawback',
        'rebate_actual_paid',
        'rebate_exposed',
        'fin_rebate_granted',
        'fin_rebate_recovered',
        'fin_rebate_lost_in_play',
        'fin_rebate_clawback',
        'rebate_need_chips',
        'reason_loss_rebate',
        'confirm_rebate_grant',
        'rebate_as_chips',
        'rebate_as_cash',
      ];
      for (final key in keys) {
        final en = AppLocalizations.lookup('en', key);
        final fa = AppLocalizations.lookup('fa', key);
        expect(en, isNot(key), reason: key);
        expect(fa, isNot(key), reason: key);
        expect(en, isNot(fa), reason: key);
      }
    });

    test('EN and FA key sets stay in parity', () {
      expect(
        AppLocalizations.keysOf('en').toSet(),
        AppLocalizations.keysOf('fa').toSet(),
      );
    });
  });

  group('D1/D2 compile and backup integrity', () {
    test('unjournaled realization after cash-out is \$70 lost in play',
        () async {
      final s = await _session('pending');
      await _cashIn(s.id, 1500);
      await RebateService.grant(
        sessionId: s.id,
        personId: _personId,
        currency: AppCurrency.usd,
        asChips: false,
        bustRealized: true,
      );
      // Ensure the cash-out happens after the grant timestamp.
      await Future.delayed(const Duration(milliseconds: 30));
      await _cashOut(s.id, 80);
      final pending = RebateService.unjournaledRealization(
        sessionId: s.id,
        personId: _personId,
        currency: AppCurrency.usd,
      );
      expect(pending, isNotNull);
      expect(pending!.returnedMinor, 7000);
      expect(pending.clawbackMinor, 0);
      expect(pending.actualCashPaidMinor, 8000);
      expect(pending.recoveryKind, RebateRecoveryKind.lostInPlay);
    });

    test('grant JSON round-trips baseLossMinor and grantedAsChips', () {
      final original = FinancialEvent(
        id: 'g-1',
        personId: _personId,
        currency: AppCurrency.usd,
        type: FinancialEventType.rebateGranted,
        amountMinor: 15000,
        occurredAt: DateTime(2026, 8, 12, 20),
        createdAt: DateTime(2026, 8, 12, 20),
        sessionId: 'econ',
        baseLossMinor: 150000,
        grantedAsChips: true,
        grantPercent: 10,
        cycleIndex: 1,
      );
      final json = original.toJson();
      expect(json['baseLossMinor'], 150000);
      expect(json['grantedAsChips'], isTrue);
      expect(json['grantPercent'], 10);
      expect(json['cycleIndex'], 1);
      expect(json['type'], FinancialEventType.rebateGranted.index);
      final copy = FinancialEvent.fromJson(json);
      expect(copy.id, original.id);
      expect(copy.personId, original.personId);
      expect(copy.currency, AppCurrency.usd);
      expect(copy.type, FinancialEventType.rebateGranted);
      expect(copy.amountMinor, 15000);
      expect(copy.sessionId, 'econ');
      expect(copy.baseLossMinor, 150000);
      expect(copy.grantedAsChips, isTrue);
      expect(copy.grantPercent, 10);
      expect(copy.cycleIndex, 1);
      expect(copy.reversesEventId, isNull);
    });

    test('older JSON without grant fields still loads as null', () {
      final json = {
        'id': 'legacy',
        'personId': _personId,
        'currency': AppCurrency.usd.index,
        'type': FinancialEventType.cashInForChips.index,
        'amountMinor': 150000,
        'occurredAt': DateTime(2026, 1, 1).toIso8601String(),
        'createdAt': DateTime(2026, 1, 1).toIso8601String(),
        'isBackdated': false,
        'sessionId': 'old',
      };
      final copy = FinancialEvent.fromJson(json);
      expect(copy.baseLossMinor, isNull);
      expect(copy.grantedAsChips, isNull);
      expect(copy.grantPercent, isNull);
      expect(copy.cycleIndex, isNull);
      expect(copy.type, FinancialEventType.cashInForChips);
    });

    test('restored grant keeps consumed base loss so the same \$1500 is not rebated again',
        () async {
      final s = await _session('restore');
      await _cashIn(s.id, 1500);
      final grant = await RebateService.grant(
        sessionId: s.id,
        personId: _personId,
        currency: AppCurrency.usd,
        asChips: true,
        bustRealized: true,
      );
      expect(grant.baseLossMinor, 150000);
      expect(grant.grantedAsChips, isTrue);
      expect(grant.grantPercent, 10);
      expect(grant.cycleIndex, 1);

      final payload = grant.toJson();
      await HiveService.financialEvents.delete(grant.id);
      expect(_snap(s.id).granted, 0);

      final restored = FinancialEvent.fromJson(payload);
      await HiveService.financialEvents.put(restored.id, restored);
      expect(restored.baseLossMinor, 150000);
      expect(restored.grantedAsChips, isTrue);
      expect(
        RebateService.chipGrantsIssuedMinor(s.id, AppCurrency.usd),
        15000,
      );

      final sug = RebateService.suggest(
        sessionId: s.id,
        personId: _personId,
        currency: AppCurrency.usd,
        bustRealized: true,
      );
      expect(sug.alreadyQualified, isTrue);
      expect(sug.canGrant, isFalse);
      expect(sug.blockReason, contains('still open'));
    });
  });

  group('finalized remaining-loss lifecycle', () {
    Future<void> grant1500(String sessionId) async {
      await _cashIn(sessionId, 1500);
      await RebateService.grant(
        sessionId: sessionId,
        personId: _personId,
        currency: AppCurrency.usd,
        asChips: false,
        bustRealized: true,
      );
    }

    test('A: \$1,500 loss at 10% grants \$150', () async {
      final s = await _session('fa');
      await grant1500(s.id);
      final snap = _snap(s.id);
      expect(snap.granted, 150);
      expect(snap.originalLoss, 1500);
      expect(snap.grantPercent, 10);
      expect(snap.cycleIndex, 1);
    });

    test('B: \$80 cash-out pays \$80 with \$70 lost in play', () async {
      final s = await _session('fb');
      await grant1500(s.id);
      final plan = RebateService.previewRealization(
        sessionId: s.id,
        personId: _personId,
        currency: AppCurrency.usd,
        cashOutMinor: 8000,
      );
      expect(plan.actualCashPaidMinor, 8000);
      expect(plan.clawbackMinor, 0);
      expect(plan.returnedMinor, 7000);
      await _cashOut(s.id, 80);
      await Future.delayed(const Duration(milliseconds: 30));
      await RebateService.realizeCashOut(
        sessionId: s.id,
        personId: _personId,
        currency: AppCurrency.usd,
        cashOutMinor: 8000,
      );
      expect(_snap(s.id).lostInPlay, 70);
      expect(_snap(s.id).actualCashPaid, 80);
      expect(
        RebateService.suggest(
          sessionId: s.id,
          personId: _personId,
          currency: AppCurrency.usd,
          bustRealized: true,
        ).canGrant,
        isFalse,
      );
    });

    test('C: \$500 cash-out reconciles \$50 and pays \$450', () async {
      final s = await _session('fc');
      await grant1500(s.id);
      final plan = RebateService.previewRealization(
        sessionId: s.id,
        personId: _personId,
        currency: AppCurrency.usd,
        cashOutMinor: 50000,
      );
      expect(plan.remainingLossMinor, 100000);
      expect(plan.remainingEntitlementMinor, 10000);
      expect(plan.clawbackMinor, 5000);
      expect(plan.actualCashPaidMinor, 45000);
    });

    test('D: \$1,500 cash-out reconciles \$150 and pays \$1,350', () async {
      final s = await _session('fd');
      await grant1500(s.id);
      final plan = RebateService.previewRealization(
        sessionId: s.id,
        personId: _personId,
        currency: AppCurrency.usd,
        cashOutMinor: 150000,
      );
      expect(plan.remainingLossMinor, 0);
      expect(plan.clawbackMinor, 15000);
      expect(plan.actualCashPaidMinor, 135000);
    });

    test('E: \$1,650 cash-out pays \$1,500 and fully settles', () async {
      final s = await _session('fe');
      await grant1500(s.id);
      final plan = RebateService.previewRealization(
        sessionId: s.id,
        personId: _personId,
        currency: AppCurrency.usd,
        cashOutMinor: 165000,
      );
      expect(plan.clawbackMinor, 15000);
      expect(plan.actualCashPaidMinor, 150000);
      await _cashOut(s.id, 1650);
      await RebateService.realizeCashOut(
        sessionId: s.id,
        personId: _personId,
        currency: AppCurrency.usd,
        cashOutMinor: 165000,
      );
      expect(_snap(s.id).exposed, 0);
      expect(_snap(s.id).clawback, 150);
    });

    test('F: \$1,700 cash-out still reconciles only \$150 and pays \$1,550',
        () async {
      final s = await _session('ff');
      await grant1500(s.id);
      final plan = RebateService.previewRealization(
        sessionId: s.id,
        personId: _personId,
        currency: AppCurrency.usd,
        cashOutMinor: 170000,
      );
      expect(plan.clawbackMinor, 15000);
      expect(plan.actualCashPaidMinor, 155000);
    });

    test('G: new \$1,200 cycle after settlement grants \$120', () async {
      final s = await _session('fg');
      await grant1500(s.id);
      await _cashOut(s.id, 1650);
      await RebateService.realizeCashOut(
        sessionId: s.id,
        personId: _personId,
        currency: AppCurrency.usd,
        cashOutMinor: 165000,
      );
      await _cashIn(s.id, 1200);
      final sug = RebateService.suggest(
        sessionId: s.id,
        personId: _personId,
        currency: AppCurrency.usd,
        bustRealized: true,
      );
      expect(sug.canGrant, isTrue);
      expect(sug.eligibleLossMinor, 120000);
      expect(sug.grantMinor, 12000);
      expect(sug.cycleIndex, 2);
      final g = await RebateService.grant(
        sessionId: s.id,
        personId: _personId,
        currency: AppCurrency.usd,
        asChips: false,
        bustRealized: true,
      );
      expect(g.amountMajor, 120);
      expect(g.baseLossMinor, 120000);
      expect(g.cycleIndex, 2);
    });

    test('H: new \$700 cycle below \$1,000 minimum grants nothing', () async {
      final s = await _session('fh');
      await grant1500(s.id);
      await _cashOut(s.id, 1650);
      await RebateService.realizeCashOut(
        sessionId: s.id,
        personId: _personId,
        currency: AppCurrency.usd,
        cashOutMinor: 165000,
      );
      await _cashIn(s.id, 700);
      final sug = RebateService.suggest(
        sessionId: s.id,
        personId: _personId,
        currency: AppCurrency.usd,
        bustRealized: true,
      );
      expect(sug.canGrant, isFalse);
      expect(sug.blockReason, contains('minimum'));
    });

    test('I: configurable \$500 minimum grants \$50 on a \$500 cycle', () async {
      final s = await _session('fi', minLoss: 500);
      await _cashIn(s.id, 500);
      final sug = RebateService.suggest(
        sessionId: s.id,
        personId: _personId,
        currency: AppCurrency.usd,
        bustRealized: true,
      );
      expect(sug.canGrant, isTrue);
      expect(sug.grantMinor, 5000);
    });

    test('J: 15% of a \$1,200 cycle grants \$180', () async {
      final s = await _session('fj', percent: 15);
      await _cashIn(s.id, 1200);
      final sug = RebateService.suggest(
        sessionId: s.id,
        personId: _personId,
        currency: AppCurrency.usd,
        bustRealized: true,
      );
      expect(sug.grantMinor, 18000);
    });

    test('K: Banker override pays \$200, waives \$20, closes the cycle',
        () async {
      final s = await _session('fk');
      await grant1500(s.id);
      final normal = RebateService.previewRealization(
        sessionId: s.id,
        personId: _personId,
        currency: AppCurrency.usd,
        cashOutMinor: 20000,
      );
      expect(normal.clawbackMinor, 2000);
      expect(normal.actualCashPaidMinor, 18000);
      await _cashOut(s.id, 200);
      final row = await RebateService.realizeCashOut(
        sessionId: s.id,
        personId: _personId,
        currency: AppCurrency.usd,
        cashOutMinor: 20000,
        override: true,
      );
      expect(row, isNotNull);
      expect(row!.reason, RebateRecoveryKind.override);
      expect(row.amountMajor, 20);
      final snap = _snap(s.id);
      expect(snap.waived, 20);
      expect(snap.clawback, 0);
      expect(snap.actualCashPaid, 200);
      expect(snap.houseRetained, 1300);
      expect(snap.exposed, 0);
      expect(snap.playerCashOut, 200);
    });

    test('L: later cash-out cannot reclaim a waived \$20', () async {
      final s = await _session('fl');
      await grant1500(s.id);
      await _cashOut(s.id, 200);
      await RebateService.realizeCashOut(
        sessionId: s.id,
        personId: _personId,
        currency: AppCurrency.usd,
        cashOutMinor: 20000,
        override: true,
      );
      final later = RebateService.previewRealization(
        sessionId: s.id,
        personId: _personId,
        currency: AppCurrency.usd,
        cashOutMinor: 10000,
      );
      expect(later.exposedBeforeMinor, 0);
      expect(later.clawbackMinor, 0);
      expect(later.waivedMinor, 0);
      expect(later.hasJournalRow, isFalse);
      final second = await RebateService.realizeCashOut(
        sessionId: s.id,
        personId: _personId,
        currency: AppCurrency.usd,
        cashOutMinor: 10000,
        override: true,
      );
      expect(second, isNull);
      expect(_snap(s.id).waived, 20);
    });

    test('M: after override a new \$1,200 loss starts cycle 2 at \$120',
        () async {
      final s = await _session('fm');
      await grant1500(s.id);
      await _cashOut(s.id, 200);
      await RebateService.realizeCashOut(
        sessionId: s.id,
        personId: _personId,
        currency: AppCurrency.usd,
        cashOutMinor: 20000,
        override: true,
      );
      await _cashIn(s.id, 1200);
      final sug = RebateService.suggest(
        sessionId: s.id,
        personId: _personId,
        currency: AppCurrency.usd,
        bustRealized: true,
      );
      expect(sug.canGrant, isTrue);
      expect(sug.grantMinor, 12000);
      expect(sug.cycleIndex, 2);
    });

    test('N: after override a \$700 new cycle is still below the minimum',
        () async {
      final s = await _session('fn');
      await grant1500(s.id);
      await _cashOut(s.id, 200);
      await RebateService.realizeCashOut(
        sessionId: s.id,
        personId: _personId,
        currency: AppCurrency.usd,
        cashOutMinor: 20000,
        override: true,
      );
      await _cashIn(s.id, 700);
      expect(
        RebateService.suggest(
          sessionId: s.id,
          personId: _personId,
          currency: AppCurrency.usd,
          bustRealized: true,
        ).canGrant,
        isFalse,
      );
    });

    test('O: changing Session B percent does not rewrite Session A history',
        () async {
      final a = await _session('fo-a', percent: 10);
      final b = await _session('fo-b', percent: 10);
      await _cashIn(a.id, 1500);
      await RebateService.grant(
        sessionId: a.id,
        personId: _personId,
        currency: AppCurrency.usd,
        asChips: false,
        bustRealized: true,
      );
      b.rebatePercent = 15;
      b.rebateMinLoss = 500;
      await b.save();
      expect(_snap(a.id).granted, 150);
      expect(
        HiveService.financialEvents.values
            .firstWhere((e) =>
                e.sessionId == a.id &&
                e.type == FinancialEventType.rebateGranted)
            .grantPercent,
        10,
      );
      final plan = RebateService.previewRealization(
        sessionId: a.id,
        personId: _personId,
        currency: AppCurrency.usd,
        cashOutMinor: 50000,
      );
      expect(plan.clawbackMinor, 5000);
      expect(plan.grantPercent, 10);
    });

    test('P: a Session A loss cannot qualify Discount in Session B', () async {
      final a = await _session('fp-a');
      final b = await _session('fp-b');
      await _cashIn(a.id, 1500);
      expect(
        RebateService.suggest(
          sessionId: b.id,
          personId: _personId,
          currency: AppCurrency.usd,
          bustRealized: true,
        ).canGrant,
        isFalse,
      );
      expect(_snap(b.id).playerCashIn, 0);
    });

    test('Cancel is not an override and leaves realization unjournaled',
        () async {
      final s = await _session('cancel');
      await grant1500(s.id);
      // Ensure the cash-out happens after the grant timestamp.
      await Future.delayed(const Duration(milliseconds: 30));
      await _cashOut(s.id, 200);
      final plan = RebateService.previewRealization(
        sessionId: s.id,
        personId: _personId,
        currency: AppCurrency.usd,
        cashOutMinor: 20000,
      );
      expect(plan.clawbackMinor, 2000);
      expect(
        RebateService.shouldPersistRealization(plan, confirmed: false),
        isFalse,
      );
      expect(_snap(s.id).waived, 0);
      expect(_snap(s.id).clawback, 0);
      final pending = RebateService.unjournaledRealization(
        sessionId: s.id,
        personId: _personId,
        currency: AppCurrency.usd,
      );
      expect(pending, isNotNull);
      expect(pending!.clawbackMinor, 2000);
    });
  });

  group('Banker-defined Session/Discount period', () {
    // Deterministic clocks: a period far in the past is always already
    // ended; a period anchored around now with +23h headroom is always
    // still active. Never depend on the exact wall-clock instant.
    final pastStart = DateTime(2020, 1, 1, 12, 0);
    final pastEnd = DateTime(2020, 1, 2, 6, 0); // 18h period, 12:00→06:00

    DateTime activeStart() => DateTime.now().subtract(const Duration(hours: 1));
    DateTime activeEnd() => DateTime.now().add(const Duration(hours: 23));

    test('18h period (12:00 → 06:00 next day): qualifying loss inside '
        'period is granted', () async {
      final s = await _session(
        'p18',
        minLoss: 1000,
        start: activeStart(),
        plannedEnd: activeEnd(),
      );
      await _cashIn(s.id, 2000, at: activeStart().add(const Duration(minutes: 30)));
      final sug = RebateService.suggest(
        sessionId: s.id,
        personId: _personId,
        currency: AppCurrency.usd,
        bustRealized: true,
      );
      expect(sug.canGrant, isTrue);
      expect(sug.grantMinor, 20000);
      expect(sug.periodEnd, s.plannedEndAt);
      expect(sug.periodEnded, isFalse);
      await RebateService.grant(
        sessionId: s.id,
        personId: _personId,
        currency: AppCurrency.usd,
        asChips: false,
        bustRealized: true,
      );
      expect(_snap(s.id).granted, 200);
    });

    test('qualifying event OCCURRED inside the period stays eligible '
        'whenever the Banker records the Discount (12:00 → 06:00, loss '
        'at 05:55, recorded after 06:00)', () async {
      // Session period: 12:00 → 06:00 next day (18h). Player's
      // qualifying loss: 05:55. Banker records the Discount later.
      // occurredAt decides — there is no time limit on the recording.
      final s = await _session('poccurred', start: pastStart, plannedEnd: pastEnd);
      await _cashIn(s.id, 2000,
          at: pastEnd.subtract(const Duration(minutes: 5))); // 05:55
      final sug = RebateService.suggest(
        sessionId: s.id,
        personId: _personId,
        currency: AppCurrency.usd,
        bustRealized: true,
      );
      expect(sug.periodEnded, isTrue, reason: 'the period is over');
      expect(sug.canGrant, isTrue,
          reason: 'the qualifying event occurred inside the period');
      expect(sug.grantMinor, 20000);
      final grant = await RebateService.grant(
        sessionId: s.id,
        personId: _personId,
        currency: AppCurrency.usd,
        asChips: false,
        bustRealized: true,
      );
      expect(grant.baseLossMinor, 200000);
      expect(grant.createdAt.isAfter(pastEnd), isTrue,
          reason: 'recorded after the period end, still valid');
    });

    test('activity AFTER the period end creates no eligibility', () async {
      final s = await _session('pafter', start: pastStart, plannedEnd: pastEnd);
      // Money brought in only after the period ended.
      await _cashIn(s.id, 5000, at: pastEnd.add(const Duration(hours: 3)));
      final sug = RebateService.suggest(
        sessionId: s.id,
        personId: _personId,
        currency: AppCurrency.usd,
        bustRealized: true,
      );
      expect(sug.canGrant, isFalse);
      expect(sug.periodEnded, isTrue);
      expect(sug.blockReason, contains('period has ended'));
      expect(sug.eligibleLossMinor, 0);
    });

    test('old-period loss + new-period loss cannot combine', () async {
      final s = await _session('pnocarry', start: pastStart, plannedEnd: pastEnd);
      // $800 in-period loss: below the $1,000 minimum, never claimed.
      await _cashIn(s.id, 800, at: pastStart.add(const Duration(hours: 2)));
      // After the end: $300 more. Combined it would clear the minimum —
      // the carry is forbidden, the post-period cash-in is invisible.
      await _cashIn(s.id, 300, at: pastEnd.add(const Duration(hours: 1)));
      final sug = RebateService.suggest(
        sessionId: s.id,
        personId: _personId,
        currency: AppCurrency.usd,
        bustRealized: true,
      );
      expect(sug.canGrant, isFalse);
      expect(sug.incrementalLossMinor, 80000,
          reason: 'only the in-period 800 counts, not 800 + 300');
      expect(sug.blockReason, contains('minimum'));
    });

    test('winning cushion does not transfer past the period end', () async {
      final s = await _session('pcushion', start: pastStart, plannedEnd: pastEnd);
      // In-period: Ali-style net-winning position.
      await _cashIn(s.id, 1000, at: pastStart.add(const Duration(minutes: 10)));
      await _cashOut(s.id, 10000, at: pastStart.add(const Duration(hours: 1)));
      // After the end: a fresh loss cannot lean on a new period (there is
      // none), and the expired cushion is not a transferable balance.
      await _cashIn(s.id, 2000, at: pastEnd.add(const Duration(hours: 2)));
      final sug = RebateService.suggest(
        sessionId: s.id,
        personId: _personId,
        currency: AppCurrency.usd,
        bustRealized: true,
      );
      expect(sug.canGrant, isFalse);
      expect(sug.blockReason, contains('period has ended'));
    });

    test('Ali net-winning example: cushion offsets the later loss inside '
        'the period, across tables', () async {
      final s = await _session(
        'pali',
        start: activeStart(),
        plannedEnd: activeEnd(),
      );
      // Seated at two different tables inside ONE session — the Discount
      // position belongs to the person + session, never to a table.
      final t1 = Player(
        id: 'ali-t1',
        sessionId: s.id,
        name: 'Ali',
        seatNumber: 1,
        personId: _personId,
        tableId: 'table-1',
      );
      final t2 = Player(
        id: 'ali-t2',
        sessionId: s.id,
        name: 'Ali',
        seatNumber: 1,
        personId: _personId,
        tableId: 'table-2',
      );
      await HiveService.players.put(t1.id, t1);
      await HiveService.players.put(t2.id, t2);

      final t1200 = activeStart().add(const Duration(minutes: 5));
      final t1300 = activeStart().add(const Duration(hours: 1));
      await _cashIn(s.id, 1000, at: t1200); // table 1
      await _cashOut(s.id, 10000, at: t1300); // wins and cashes out
      // Later, on table 2: brings 2,000 and loses it.
      await _cashIn(s.id, 2000,
          at: activeStart().add(const Duration(hours: 2)));
      final sug = RebateService.suggest(
        sessionId: s.id,
        personId: _personId,
        currency: AppCurrency.usd,
        bustRealized: true,
      );
      expect(sug.canGrant, isFalse,
          reason: 'net position is still +7,000 — no qualifying loss');
      final snap = _snap(s.id);
      expect(snap.playerCashIn, 3000);
      expect(snap.playerCashOut, 10000);
      expect(snap.grossLoss, 0);
      expect(snap.playerEconomicNet, 7000);
      // Moving between tables never split or reset the position:
      expect(sug.cycleIndex, 1);
    });

    test('multiple Discounts in ONE period; consumed loss never rebated',
        () async {
      final s = await _session(
        'pmulti',
        minLoss: 500,
        start: activeStart(),
        plannedEnd: activeEnd(),
      );
      // Cycle 1: lose 2,000 → Discount 200.
      await _cashIn(s.id, 2000);
      await Future.delayed(const Duration(milliseconds: 30));
      await RebateService.grant(
        sessionId: s.id,
        personId: _personId,
        currency: AppCurrency.usd,
        asChips: false,
        bustRealized: true,
      );
      // Close cycle 1 with a dust cash-out (grant lost in play).
      await _cashOut(s.id, 0.01);
      await Future.delayed(const Duration(milliseconds: 30));
      await RebateService.realizeCashOut(
        sessionId: s.id,
        personId: _personId,
        currency: AppCurrency.usd,
        cashOutMinor: 1,
      );
      // The consumed $2,000 must not be suggested again.
      final again = RebateService.suggest(
        sessionId: s.id,
        personId: _personId,
        currency: AppCurrency.usd,
        bustRealized: true,
      );
      expect(again.canGrant, isFalse);

      // Cycle 2: another 1,000 lost → Discount 100.
      await _cashIn(s.id, 1000);
      await Future.delayed(const Duration(milliseconds: 30));
      final sug2 = RebateService.suggest(
        sessionId: s.id,
        personId: _personId,
        currency: AppCurrency.usd,
        bustRealized: true,
      );
      expect(sug2.canGrant, isTrue);
      expect(sug2.cycleIndex, 2);
      // The dust cash-out closed cycle 1 as lost-in-play; the new cycle's
      // base is the full fresh 1,000.
      expect(sug2.eligibleLossMinor, 100000);
      await RebateService.grant(
        sessionId: s.id,
        personId: _personId,
        currency: AppCurrency.usd,
        asChips: false,
        bustRealized: true,
      );
      await _cashOut(s.id, 0.01);
      await Future.delayed(const Duration(milliseconds: 30));
      await RebateService.realizeCashOut(
        sessionId: s.id,
        personId: _personId,
        currency: AppCurrency.usd,
        cashOutMinor: 1,
      );

      // Cycle 3: another 5,000 lost → Discount 500.
      await _cashIn(s.id, 5000);
      await Future.delayed(const Duration(milliseconds: 30));
      final sug3 = RebateService.suggest(
        sessionId: s.id,
        personId: _personId,
        currency: AppCurrency.usd,
        bustRealized: true,
      );
      expect(sug3.canGrant, isTrue);
      expect(sug3.cycleIndex, 3);
      await RebateService.grant(
        sessionId: s.id,
        personId: _personId,
        currency: AppCurrency.usd,
        asChips: false,
        bustRealized: true,
      );
      expect(_snap(s.id).granted, 800); // 200 + 100 + 500, same period
      expect(_snap(s.id).periodEnd, s.plannedEndAt);
    });

    test('settlement / leave / return never resets the period', () async {
      final s = await _session(
        'psettle',
        minLoss: 500,
        start: activeStart(),
        plannedEnd: activeEnd(),
      );
      // Full first cycle, then a settlement-like full cash-out.
      await _cashIn(s.id, 1500);
      await RebateService.grant(
        sessionId: s.id,
        personId: _personId,
        currency: AppCurrency.usd,
        asChips: false,
        bustRealized: true,
      );
      await _cashOut(s.id, 0.01);
      await RebateService.realizeCashOut(
        sessionId: s.id,
        personId: _personId,
        currency: AppCurrency.usd,
        cashOutMinor: 1,
      );
      // Player leaves, returns later in the SAME session with new money.
      final p = await _seat(s.id);
      p.isActive = false;
      await HiveService.players.put(p.id, p);
      await _cashIn(s.id, 900);
      final sug = RebateService.suggest(
        sessionId: s.id,
        personId: _personId,
        currency: AppCurrency.usd,
        bustRealized: true,
      );
      expect(sug.canGrant, isTrue);
      expect(sug.cycleIndex, 2);
      expect(sug.periodEnd, s.plannedEndAt,
          reason: 'same Banker-defined period, no reset');
      expect(sug.periodEnded, isFalse);
    });

    test('grant/cycle reconciliation works across the period boundary',
        () async {
      final s = await _session('pcross', start: pastStart, plannedEnd: pastEnd);
      // Qualifying loss inside the period.
      await _cashIn(s.id, 1500, at: pastStart.add(const Duration(hours: 1)));
      // Grant recorded after the period end — valid, because occurredAt
      // of the qualifying event decides.
      await RebateService.grant(
        sessionId: s.id,
        personId: _personId,
        currency: AppCurrency.usd,
        asChips: true,
        bustRealized: true,
      );
      // Cash-out happens AFTER the period end; the cycle lifecycle must
      // not be corrupted by the boundary.
      await _cashOut(s.id, 80, at: pastEnd.add(const Duration(hours: 2)));
      await RebateService.realizeCashOut(
        sessionId: s.id,
        personId: _personId,
        currency: AppCurrency.usd,
        cashOutMinor: 8000,
        linkedTransactionId: 'tx-cross',
      );
      final snap = _snap(s.id);
      expect(snap.granted, 150);
      expect(snap.returned, 70); // 150 − 80 lost in play
      expect(snap.cycleOpen, isFalse);
    });

    test('expiration is never deletion: history stays intact', () async {
      final s = await _session('phistory', start: pastStart, plannedEnd: pastEnd);
      await _cashIn(s.id, 1500, at: pastStart.add(const Duration(hours: 1)));
      await _cashOut(s.id, 200, at: pastStart.add(const Duration(hours: 2)));
      // Period long expired. Nothing is deleted; every figure survives.
      final events = FinancialLedgerService.eventsForSession(s.id);
      expect(events.length, 2);
      final snap = _snap(s.id);
      expect(snap.playerCashIn, 1500);
      expect(snap.playerCashOut, 200);
      expect(snap.grossLoss, 1300);
      expect(snap.granted, 0);
      expect(snap.periodEnded, isTrue);
      // The in-period loss stays claimable because it OCCURRED inside
      // the period — occurredAt decides, with no time limit on the
      // recording. Post-period activity, by contrast, could never add
      // to it (covered by the no-combine / cushion tests).
      final sug = RebateService.suggest(
        sessionId: s.id,
        personId: _personId,
        currency: AppCurrency.usd,
        bustRealized: true,
      );
      expect(sug.canGrant, isTrue);
      expect(sug.grantMinor, 13000);
    });

    test('null plannedEndAt: no time-based expiry while the session is '
        'open (legacy behavior preserved)', () async {
      final s = await _session('pnullend', start: pastStart);
      await _cashIn(s.id, 1500, at: pastStart.add(const Duration(hours: 1)));
      final sug = RebateService.suggest(
        sessionId: s.id,
        personId: _personId,
        currency: AppCurrency.usd,
        bustRealized: true,
      );
      expect(sug.canGrant, isTrue);
      expect(sug.periodEnd, isNull);
      expect(sug.periodEnded, isFalse);
    });

    test('closing the session never rewrites the Banker-defined period',
        () async {
      // plannedEnd is tomorrow; the session is closed today. endedAt is
      // the actual close fact — it must NOT become a second Discount
      // deadline. occurredAt versus plannedEndAt still decides.
      final start = DateTime.now().subtract(const Duration(hours: 2));
      final plannedEnd = DateTime.now().add(const Duration(hours: 22));
      final s = await _session('pmin', start: start, plannedEnd: plannedEnd);
      s.status = SessionStatus.ended;
      s.endedAt = DateTime.now().subtract(const Duration(minutes: 30));
      await HiveService.sessions.put(s.id, s);
      // Occurred AFTER the close but INSIDE the Banker-defined period.
      await _cashIn(s.id, 2000,
          at: DateTime.now().subtract(const Duration(minutes: 10)));
      final sug = RebateService.suggest(
        sessionId: s.id,
        personId: _personId,
        currency: AppCurrency.usd,
        bustRealized: true,
      );
      expect(sug.canGrant, isTrue,
          reason: 'the event occurred inside plannedEndAt');
      expect(sug.eligibleLossMinor, 200000);
      expect(sug.periodEnd, plannedEnd,
          reason: 'the period stays the Banker plan, not endedAt');
      // endedAt keeps its meaning untouched.
      final reloaded = HiveService.sessions.get('pmin')!;
      expect(reloaded.endedAt, isNotNull);
      expect(reloaded.status, SessionStatus.ended);
    });

    test('backdated in-period event counts by occurredAt', () async {
      final s = await _session('pback', start: pastStart, plannedEnd: pastEnd);
      // Recorded NOW (long after the period) but it happened inside it.
      final ev = await FinancialLedgerService.record(
        personId: _personId,
        currency: AppCurrency.usd,
        type: FinancialEventType.cashInForChips,
        amount: 1200,
        sessionId: s.id,
        occurredAt: pastStart.add(const Duration(hours: 4)),
      );
      expect(ev.isBackdated, isTrue);
      final sug = RebateService.suggest(
        sessionId: s.id,
        personId: _personId,
        currency: AppCurrency.usd,
        bustRealized: true,
      );
      expect(sug.canGrant, isTrue);
      expect(sug.eligibleLossMinor, 120000);
    });

    test('plannedEndAt survives JSON round-trip; old payloads load null',
        () async {
      final end = DateTime(2026, 8, 18, 6, 0);
      final s = await _session('pjson', start: pastStart, plannedEnd: end);
      final json = s.toJson();
      expect(PokerSession.fromJson(json).plannedEndAt, end);
      json.remove('plannedEndAt');
      expect(PokerSession.fromJson(json).plannedEndAt, isNull);
    });

    test('plannedEndAt and rebate settings survive the Hive binary '
        'adapter round-trip', () async {
      final end = DateTime(2026, 8, 18, 6, 0);
      final s = await _session('pbin', start: pastStart, plannedEnd: end);
      await HiveService.sessions.put(s.id, s);
      await HiveService.sessions.close();
      final box =
          await Hive.openBox<PokerSession>(HiveService.sessionsBox);
      final loaded = box.get('pbin');
      expect(loaded, isNotNull);
      expect(loaded!.plannedEndAt, end);
      expect(loaded.rebateEnabled, isTrue);
      expect(loaded.rebateMinLoss, 1000);
      expect(loaded.rebatePercent, 10);
    });
  });
}
