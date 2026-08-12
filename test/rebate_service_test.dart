// Step 6 — Loss rebate / Discount.
//
// Own-cash only. Types 8/9 contribute 0 to Outstanding Balance.
// SessionService formulas are never read or written.
import 'dart:io';

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
}) async {
  final s = PokerSession(
    id: id,
    name: 'Night',
    location: 'Home',
    dateTime: DateTime.now(),
    smallBlind: 1,
    bigBlind: 2,
    tableNumber: '1',
    mode: mode,
    rebateEnabled: rebate,
    rebateMinLoss: minLoss,
    rebatePercent: percent,
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
}) {
  return FinancialLedgerService.record(
    personId: personId ?? _personId,
    currency: AppCurrency.usd,
    type: FinancialEventType.cashInForChips,
    amount: amount,
    sessionId: sessionId,
  );
}

Future<FinancialEvent> _cashOut(
  String sessionId,
  double amount, {
  String? personId,
  String? linked,
}) {
  return FinancialLedgerService.record(
    personId: personId ?? _personId,
    currency: AppCurrency.usd,
    type: FinancialEventType.cashOutForChips,
    amount: amount,
    sessionId: sessionId,
    linkedTransactionId: linked,
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

    test('3. paid cash-in is eligible', () async {
      final s = await _session('s3');
      await _cashIn(s.id, 1500);
      final sug = RebateService.suggest(
        sessionId: s.id,
        personId: _personId,
        currency: AppCurrency.usd,
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
    test('canonical $1500 / $150 / $80 / $70 / house $1420', () async {
      final s = await _session('econ');
      await _cashIn(s.id, 1500);
      await RebateService.grant(
        sessionId: s.id,
        personId: _personId,
        currency: AppCurrency.usd,
        asChips: true,
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
    });

    test('11. $150 grant + $80 cash-out recovers $70, player receives $80',
        () async {
      final s = await _session('s11', minLoss: 100);
      await _cashIn(s.id, 1500);
      await RebateService.grant(
        sessionId: s.id,
        personId: _personId,
        currency: AppCurrency.usd,
        asChips: true,
      );
      await _cashOut(s.id, 80);
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

    test('12. cash-out above remaining grant claws back only the grant',
        () async {
      final s = await _session('s12');
      await _cashIn(s.id, 1500);
      await RebateService.grant(
        sessionId: s.id,
        personId: _personId,
        currency: AppCurrency.usd,
        asChips: true,
      );
      final plan = RebateService.previewRealization(
        sessionId: s.id,
        personId: _personId,
        currency: AppCurrency.usd,
        cashOutMinor: 250000,
      );
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

    test('13. multiple cash-outs do not invent a second $150', () async {
      final s = await _session('s13');
      await _cashIn(s.id, 1500);
      await RebateService.grant(
        sessionId: s.id,
        personId: _personId,
        currency: AppCurrency.usd,
        asChips: true,
      );
      await _cashOut(s.id, 80);
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

    test('14/15. later own cash is new contribution; old grant is not cash-in',
        () async {
      final s = await _session('s14');
      await _cashIn(s.id, 1500);
      await RebateService.grant(
        sessionId: s.id,
        personId: _personId,
        currency: AppCurrency.usd,
        asChips: true,
      );
      await _cashOut(s.id, 80);
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
      );
      // GrossLoss = 2000 - 80 = 1920; consumed base 1500; incremental 420
      expect(sug.alreadyQualified, isTrue);
      expect(sug.incrementalLossMinor, 42000);
      expect(sug.grantMinor, 4200);
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
      );
      // GrossLoss ≈ 2000 - 0.01; consumed 1500; incremental ≈ 500
      expect(sug.grantMinor, 5000);
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
      );
      expect(sug.canGrant, isTrue);
      expect(_snap(s.id).granted, 0);
      await RebateService.grant(
        sessionId: s.id,
        personId: _personId,
        currency: AppCurrency.usd,
        asChips: false,
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

  group('localization', () {
    test('24. EN/FA rebate keys exist and differ', () {
      const keys = [
        'rebate_title',
        'rebate_granted',
        'rebate_returned',
        'rebate_paid_out',
        'rebate_house_retained',
        'fin_rebate_granted',
        'fin_rebate_recovered',
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
  });
}
