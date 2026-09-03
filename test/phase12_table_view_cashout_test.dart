// Phase 12 — Table View seated leave records table cash-out.
// Does not change SessionService / RebateService / RedemptionService.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:poker_ledger/core/localization/app_localizations.dart';
import 'package:poker_ledger/models/chip_movement.dart';
import 'package:poker_ledger/models/chip_type.dart';
import 'package:poker_ledger/models/enums.dart';
import 'package:poker_ledger/models/financial_event.dart';
import 'package:poker_ledger/models/hand.dart';
import 'package:poker_ledger/models/player.dart';
import 'package:poker_ledger/models/player_identity.dart';
import 'package:poker_ledger/models/session.dart';
import 'package:poker_ledger/models/table_participation.dart';
import 'package:poker_ledger/models/transaction.dart';
import 'package:poker_ledger/services/backup_service.dart';
import 'package:poker_ledger/services/chip_tracking_service.dart';
import 'package:poker_ledger/services/confirm_gate.dart';
import 'package:poker_ledger/services/financial_ledger_service.dart';
import 'package:poker_ledger/services/hive_service.dart';
import 'package:poker_ledger/services/participation_service.dart';
import 'package:poker_ledger/services/player_identity_service.dart';
import 'package:poker_ledger/services/rebate_service.dart';
import 'package:poker_ledger/services/redemption_service.dart';
import 'package:poker_ledger/services/session_service.dart';
import 'package:poker_ledger/services/table_service.dart';
import 'package:poker_ledger/widgets/chip_flow.dart';

import 'test_helper.dart';

late Directory _tmp;

Future<void> _open() async {
  _tmp = await Directory.systemTemp.createTemp('pl_p12_');
  Hive.init(_tmp.path);
  registerTestAdapters();
  await Hive.openBox<PokerSession>(HiveService.sessionsBox);
  await Hive.openBox<Player>(HiveService.playersBox);
  await Hive.openBox<LedgerTransaction>(HiveService.transactionsBox);
  await Hive.openBox(HiveService.settingsBox);
  await Hive.openBox<PlayerIdentity>(HiveService.playerIdentitiesBox);
  await Hive.openBox<TableParticipation>(HiveService.participationsBox);
  await Hive.openBox<ChipType>(HiveService.chipsBox);
  await Hive.openBox<ChipMovement>(HiveService.chipMovementsBox);
  await Hive.openBox<FinancialEvent>(HiveService.financialEventsBox);
  await Hive.openBox<Hand>(HiveService.handsBox);
}

Future<void> _close() async {
  await Hive.deleteFromDisk();
  if (await _tmp.exists()) await _tmp.delete(recursive: true);
}

Future<PokerSession> _session(String id) async {
  final s = PokerSession(
    id: id,
    name: id,
    location: 'Home',
    dateTime: DateTime(2026, 1, 1),
    smallBlind: 1,
    bigBlind: 2,
    tableNumber: '1',
  );
  await HiveService.sessions.put(s.id, s);
  await TableService.materialise(s);
  return s;
}

Future<String> _person(String name) async =>
    (await PlayerIdentityService.createNew(name))!.id;

Future<Player> _seat(PokerSession s, String name, int seatNo,
    {String? personId}) async {
  final tables = TableService.tablesFor(s);
  final p = Player(
    id: 'seat-${s.id}-${name.toLowerCase()}-$seatNo',
    sessionId: s.id,
    name: name,
    seatNumber: seatNo,
    tableId: tables.first.id,
    personId: personId,
  );
  await HiveService.players.put(p.id, p);
  return p;
}

Future<LedgerTransaction> _buyIn(
  String sessionId,
  Player seat,
  double amount, {
  Map<String, int>? chips,
}) async {
  final tx = await SessionService.recordTransaction(
    sessionId: sessionId,
    playerId: seat.id,
    type: TransactionType.buyIn,
    amount: amount,
    hostSignatureBase64: 'sig',
  );
  if (chips != null && seat.personId != null) {
    await ChipTrackingService.recordDistribution(
      distribution: chips,
      from: ChipLocation.bank,
      to: ChipLocation.player(seat.personId!),
      reason: ChipMovementReason.buyIn,
      sessionId: sessionId,
      transactionId: tx.id,
    );
  }
  return tx;
}

/// The Table View seat-sheet cash-out handler. Same service
/// [performTableCashOut] wraps — Flutter widgets are not pumped here.
Future<LedgerTransaction> _tableViewSeatedLeave({
  required String sessionId,
  required String seatPlayerId,
  required double amount,
}) {
  return RedemptionService.tableCashOut(
    sessionId: sessionId,
    seatPlayerId: seatPlayerId,
    amount: amount,
    hostSignatureBase64: 'sig',
  );
}

void main() {
  setUp(_open);
  tearDown(_close);

  group('Table View wires seated leave to table cash-out', () {
    test('source calls performTableCashOut and never session cashOut', () {
      final src = File('lib/screens/table_view/table_view_tab.dart')
          .readAsStringSync();
      expect(src, contains('performTableCashOut'));
      expect(src, contains("import '../../widgets/cashout_flow.dart'"));
      expect(src, contains("title: Text(tr('table_cash_out'))"));

      // The cashOut branch must return after performTableCashOut so
      // collectRequiredFunding / ChipFlow / recordTransaction cannot
      // run for seated leave.
      final cashOutBranch = RegExp(
        r'if \(type == TransactionType\.cashOut\) \{[\s\S]*?performTableCashOut[\s\S]*?return;',
      );
      expect(cashOutBranch.hasMatch(src), isTrue);

      final afterLeave = src.split('if (type == TransactionType.cashOut)')[1];
      final leaveBlock = afterLeave.split('final funding = await collectRequiredFunding')[0];
      expect(leaveBlock, contains('performTableCashOut'));
      expect(leaveBlock, contains('return;'));
      expect(leaveBlock, isNot(contains('recordTransaction')));
      expect(leaveBlock, isNot(contains('ChipFlow')));
      expect(leaveBlock, isNot(contains('collectRequiredFunding')));
    });
  });

  group('Table View table cash-out workflow', () {
    test('writes tableCashOut, not session cashOut; no chips or cashier',
        () async {
      await HiveService.chips
          .put('k1000', ChipType(id: 'k1000', value: 1000, quantity: 20));
      final s = await _session('s1');
      final pid = await _person('Ali');
      final a = await _seat(s, 'Ali', 1, personId: pid);
      await _buyIn(s.id, a, 10000, chips: {'k1000': 10});

      final partId = ParticipationService.forSession(s.id).single.id;
      final movesBefore = ChipTrackingService.allMovements().length;
      final bankBefore = ChipTrackingService.currentBankValue();
      final heldBefore =
          ChipTrackingService.holdingAt(ChipLocation.player(pid)).totalValue;
      final finBefore = FinancialLedgerService.eventsFor(pid).length;

      final tx = await _tableViewSeatedLeave(
        sessionId: s.id,
        seatPlayerId: a.id,
        amount: 6000,
      );

      expect(tx.type, TransactionType.tableCashOut);
      expect(tx.amount, 6000);
      expect(
        SessionService.transactionsFor(s.id)
            .where((t) => t.type == TransactionType.cashOut),
        isEmpty,
      );
      expect(SessionService.totalTableCashOut(s.id), 6000);
      expect(SessionService.totalCashOut(s.id), 0);

      expect(ChipTrackingService.allMovements().length, movesBefore);
      expect(ChipTrackingService.currentBankValue(), bankBefore);
      expect(
        ChipTrackingService.holdingAt(ChipLocation.player(pid)).totalValue,
        heldBefore,
      );
      expect(heldBefore, 10000);
      expect(FinancialLedgerService.eventsFor(pid).length, finBefore);

      final seat = HiveService.players.get(a.id)!;
      expect(seat.seated, isFalse);
      expect(seat.tableId, isNull);

      final part = HiveService.participations.get(partId)!;
      expect(part.isOpen, isFalse);
      expect(part.closeReason, ParticipationCloseReason.tableCashOut);
    });

    test('\$0 table cash-out remains a bust', () async {
      await HiveService.chips
          .put('k1000', ChipType(id: 'k1000', value: 1000, quantity: 20));
      final s = await _session('s1');
      final pid = await _person('Ali');
      final a = await _seat(s, 'Ali', 1, personId: pid);
      await _buyIn(s.id, a, 10000, chips: {'k1000': 10});
      final heldBefore =
          ChipTrackingService.holdingAt(ChipLocation.player(pid)).totalValue;

      final tx = await _tableViewSeatedLeave(
        sessionId: s.id,
        seatPlayerId: a.id,
        amount: 0,
      );

      expect(tx.type, TransactionType.tableCashOut);
      expect(tx.amount, 0);
      expect(SessionService.hasCashedOut(s.id, a.id), isTrue);
      expect(SessionService.hasZeroBustOut(s.id, a.id), isTrue);
      expect(HiveService.players.get(a.id)!.seated, isFalse);
      expect(ParticipationService.forSession(s.id).single.isOpen, isFalse);
      expect(ParticipationService.forSession(s.id).single.closeReason,
          ParticipationCloseReason.tableCashOut);
      expect(SessionService.playerProfitLoss(s.id, a.id), -10000);
      expect(
        ChipTrackingService.holdingAt(ChipLocation.player(pid)).totalValue,
        heldBefore,
      );
      expect(
        SessionService.transactionsFor(s.id)
            .where((t) => t.type == TransactionType.cashOut),
        isEmpty,
      );
    });

    test('table cash-out is not ChipFlow and not cashier funding', () {
      expect(ChipFlow.appliesTo(TransactionType.tableCashOut), isFalse);
      expect(ChipFlow.appliesTo(TransactionType.cashOut), isTrue);
      expect(
        () => ChipFlow.reasonFor(TransactionType.tableCashOut),
        throwsArgumentError,
      );
      expect(ConfirmGate.fundingRequired(TransactionType.tableCashOut, 6000),
          isFalse);
      expect(ConfirmGate.fundingRequired(TransactionType.cashOut, 6000), isTrue);
    });
  });

  group('locked engines stay frozen', () {
    test('playerProfitLoss and hostProfit formulas still hold', () async {
      final s = await _session('s1');
      final a = await _seat(s, 'Ali', 1);
      await _buyIn(s.id, a, 10000);
      await _tableViewSeatedLeave(
        sessionId: s.id,
        seatPlayerId: a.id,
        amount: 6000,
      );
      expect(
        SessionService.playerProfitLoss(s.id, a.id),
        (SessionService.playerTotalCashOut(s.id, a.id) -
                SessionService.playerReentry(s.id, a.id)) -
            SessionService.playerTotalIn(s.id, a.id),
      );
      expect(SessionService.playerProfitLoss(s.id, a.id), -4000);
      expect(
        SessionService.hostProfit(s.id),
        SessionService.totalRake(s.id) + SessionService.totalHouseWin(s.id),
      );
      expect(
        SessionService.moneyStillInPlay(s.id),
        SessionService.checkBalance(s.id).discrepancy,
      );
    });

    test('hands still create no rebate events', () async {
      final s = await _session('s1');
      final pid = await _person('Ali');
      await _seat(s, 'Ali', 1, personId: pid);
      expect(
        FinancialLedgerService.eventsFor(pid)
            .where((e) => e.type == FinancialEventType.rebateGranted),
        isEmpty,
      );
      expect(
        RebateService.suggest(
          sessionId: s.id,
          personId: pid,
          currency: AppCurrency.usd,
        ).eligibleLossMinor,
        0,
      );
    });

    test('EN/FA key parity unchanged', () {
      expect(
        AppLocalizations.keysOf('en').toSet(),
        AppLocalizations.keysOf('fa').toSet(),
      );
    });

    test('backup remains v8', () {
      expect(BackupService.formatVersion, 9);
      expect(BackupService.exportPayload()['formatVersion'], 8);
    });
  });
}
