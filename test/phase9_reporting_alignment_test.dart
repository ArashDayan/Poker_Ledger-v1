// Phase 9 — reporting alignment and Phase 8 close-out.
// Does not change SessionService / RebateService formulas.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:poker_ledger/core/localization/app_localizations.dart';
import 'package:poker_ledger/core/localization/enum_labels.dart';
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
import 'package:poker_ledger/services/discount_workflow.dart';
import 'package:poker_ledger/services/financial_ledger_service.dart';
import 'package:poker_ledger/services/hand_service.dart';
import 'package:poker_ledger/services/hive_service.dart';
import 'package:poker_ledger/services/player_history_service.dart';
import 'package:poker_ledger/services/player_identity_service.dart';
import 'package:poker_ledger/services/rebate_service.dart';
import 'package:poker_ledger/services/redemption_service.dart';
import 'package:poker_ledger/services/report_service.dart';
import 'package:poker_ledger/services/session_service.dart';
import 'package:poker_ledger/services/table_service.dart';
import 'package:poker_ledger/widgets/chip_flow.dart';

import 'test_helper.dart';

late Directory _tmp;

Future<void> _open() async {
  _tmp = await Directory.systemTemp.createTemp('pl_p9_');
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

Future<PokerSession> _session(String id, {int tables = 1}) async {
  final s = PokerSession(
    id: id,
    name: id,
    location: 'Home',
    dateTime: DateTime(2026, 1, 1),
    smallBlind: 1,
    bigBlind: 2,
    tableNumber: '1',
    rebateEnabled: true,
    rebateMinLoss: 1000,
    rebatePercent: 10,
  );
  await HiveService.sessions.put(s.id, s);
  await TableService.materialise(s);
  for (var i = 2; i <= tables; i++) {
    await TableService.addTable(s, name: 'Table $i');
  }
  return s;
}

Future<String> _person(String name) async =>
    (await PlayerIdentityService.createNew(name))!.id;

Future<Player> _seat(PokerSession s, String name, int seatNo,
    {String? personId, int table = 1}) async {
  final tables = TableService.tablesFor(s);
  final p = Player(
    id: 'seat-${name.toLowerCase()}-$seatNo',
    sessionId: s.id,
    name: name,
    seatNumber: seatNo,
    tableId: tables[table - 1].id,
    personId: personId,
  );
  await HiveService.players.put(p.id, p);
  return p;
}

Future<void> _buyIn(String sessionId, Player seat, double amount) {
  return SessionService.recordTransaction(
    sessionId: sessionId,
    playerId: seat.id,
    type: TransactionType.buyIn,
    amount: amount,
    hostSignatureBase64: 'sig',
  );
}

void main() {
  setUp(_open);
  tearDown(_close);

  test('Hive adapters 20–22 are registered for tests', () {
    expect(Hive.isAdapterRegistered(20), isTrue);
    expect(Hive.isAdapterRegistered(21), isTrue);
    expect(Hive.isAdapterRegistered(22), isTrue);
  });

  test('HandKind / HandStatus labels exist in EN and FA', () {
    expect(HandKind.poker.localizedLabel, isNot('hand_kind_poker'));
    expect(HandKind.houseGame.localizedLabel, isNot('hand_kind_house'));
    expect(HandStatus.completed.localizedLabel, isNot('hand_status_completed'));
    expect(HandStatus.voided.localizedLabel, isNot('hand_voided'));
    expect(AppLocalizations.lookup('en', 'hand_kind_poker'), isNot('hand_kind_poker'));
    expect(AppLocalizations.lookup('fa', 'hand_kind_poker'), isNot('hand_kind_poker'));
    expect(AppLocalizations.lookup('en', 'hand_kind_poker'),
        isNot(AppLocalizations.lookup('fa', 'hand_kind_poker')));
    expect(
      AppLocalizations.keysOf('en').toSet(),
      AppLocalizations.keysOf('fa').toSet(),
    );
  });

  group('canonical pots and host profit', () {
    test('poker A=-4000 B=+3500 rake=500 houseWin=0', () async {
      final s = await _session('s1');
      final a = await _seat(s, 'Ali', 1);
      final b = await _seat(s, 'Baba', 2);
      await _buyIn(s.id, a, 10000);
      await _buyIn(s.id, b, 10000);
      final tableId = TableService.tablesFor(s).first.id;
      final hand = await HandService.record(
        sessionId: s.id,
        tableId: tableId,
        kind: HandKind.poker,
        drafts: [
          HandResultDraft(seatPlayerId: a.id, chipChange: -4000),
          HandResultDraft(seatPlayerId: b.id, chipChange: 3500),
        ],
        potAmount: 4000,
        rakeAmount: 500,
      );
      expect(hand.resultFor(a.id)!.chipChange, -4000);
      expect(hand.resultFor(b.id)!.chipChange, 3500);
      expect(hand.rakeAmount, 500);
      expect(hand.houseWinAmount, 0);
      expect(hand.potAmount, 4000);
      expect(SessionService.totalRake(s.id), 500);
      expect(SessionService.totalHouseWin(s.id), 0);
      expect(SessionService.hostProfit(s.id), 500);
    });

    test('house A=-6000 houseWin=6000 rake stays 500; hostProfit 6500',
        () async {
      final s = await _session('s1', tables: 2);
      final pidA = await _person('Ali');
      final pidB = await _person('Baba');
      final a = await _seat(s, 'Ali', 1, personId: pidA);
      final b = await _seat(s, 'Baba', 2, personId: pidB);
      await _buyIn(s.id, a, 10000);
      await _buyIn(s.id, b, 10000);
      final tables = TableService.tablesFor(s);
      await HandService.record(
        sessionId: s.id,
        tableId: tables[0].id,
        kind: HandKind.poker,
        drafts: [
          HandResultDraft(seatPlayerId: a.id, chipChange: -4000),
          HandResultDraft(seatPlayerId: b.id, chipChange: 3500),
        ],
        potAmount: 4000,
        rakeAmount: 500,
      );
      await RedemptionService.tableCashOut(
        sessionId: s.id,
        seatPlayerId: a.id,
        amount: 6000,
        hostSignatureBase64: 'sig',
      );
      await TableService.reenterWithHeldChips(
        s,
        HiveService.players.get(a.id)!,
        tables[1].id,
        amount: 6000,
        hostSignatureBase64: 'sig',
      );
      await HandService.record(
        sessionId: s.id,
        tableId: tables[1].id,
        kind: HandKind.houseGame,
        drafts: [HandResultDraft(seatPlayerId: a.id, chipChange: -6000)],
        potAmount: 6000,
        houseWinAmount: 6000,
        hostSignatureBase64: 'sig',
      );
      expect(SessionService.totalRake(s.id), 500);
      expect(SessionService.totalHouseWin(s.id), 6000);
      expect(SessionService.hostProfit(s.id), 6500);
      await RedemptionService.tableCashOut(
        sessionId: s.id,
        seatPlayerId: a.id,
        amount: 0,
        hostSignatureBase64: 'sig',
      );
      expect(SessionService.playerProfitLoss(s.id, a.id), -10000);
    });
  });

  group('re-entry reporting P/L', () {
    test('career and report net are -10000 not -4000', () async {
      final s = await _session('s1', tables: 2);
      final pid = await _person('Ali');
      final a = await _seat(s, 'Ali', 1, personId: pid);
      await _buyIn(s.id, a, 10000);
      final tables = TableService.tablesFor(s);
      await RedemptionService.tableCashOut(
        sessionId: s.id,
        seatPlayerId: a.id,
        amount: 6000,
        hostSignatureBase64: 'sig',
      );
      await TableService.reenterWithHeldChips(
        s,
        HiveService.players.get(a.id)!,
        tables[1].id,
        amount: 6000,
        hostSignatureBase64: 'sig',
      );
      await RedemptionService.tableCashOut(
        sessionId: s.id,
        seatPlayerId: a.id,
        amount: 0,
        hostSignatureBase64: 'sig',
      );
      expect(SessionService.playerProfitLoss(s.id, a.id), -10000);
      final career =
          PlayerHistoryService.careerFor(HiveService.players.get(a.id)!);
      expect(career.netResult, -10000);
      expect(career.netResult, isNot(-4000));
      final rows = ReportService.playerPerformance(AppCurrency.usd);
      final row = rows.singleWhere((r) => r.name == 'Ali');
      expect(row.net, -10000);
    });
  });

  group('Discount inspect bust', () {
    test('\$0 table cash-out after a 6000 table cash-out is a bust', () async {
      final s = await _session('s1', tables: 2);
      final pid = await _person('Ali');
      final a = await _seat(s, 'Ali', 1, personId: pid);
      await FinancialLedgerService.record(
        personId: pid,
        currency: AppCurrency.usd,
        type: FinancialEventType.cashInForChips,
        amount: 10000,
        sessionId: s.id,
      );
      await _buyIn(s.id, a, 10000);
      final tables = TableService.tablesFor(s);
      await RedemptionService.tableCashOut(
        sessionId: s.id,
        seatPlayerId: a.id,
        amount: 6000,
        hostSignatureBase64: 'sig',
      );
      expect(SessionService.hasZeroBustOut(s.id, a.id), isFalse);
      var view = DiscountWorkflowView.inspect(
        sessionId: s.id,
        currency: AppCurrency.usd,
        personId: pid,
        playerId: a.id,
      );
      expect(view.kind, isNot(DiscountWorkflowKind.eligible));

      await TableService.reenterWithHeldChips(
        s,
        HiveService.players.get(a.id)!,
        tables[1].id,
        amount: 6000,
        hostSignatureBase64: 'sig',
      );
      await RedemptionService.tableCashOut(
        sessionId: s.id,
        seatPlayerId: a.id,
        amount: 0,
        hostSignatureBase64: 'sig',
      );
      expect(SessionService.hasZeroBustOut(s.id, a.id), isTrue);
      expect(SessionService.playerTotalCashOut(s.id, a.id), 6000);
      view = DiscountWorkflowView.inspect(
        sessionId: s.id,
        currency: AppCurrency.usd,
        personId: pid,
        playerId: a.id,
      );
      expect(view.kind, DiscountWorkflowKind.eligible);
      expect(view.canGrant, isTrue);
      expect(view.suggestion.eligibleLossMinor, 1000000);
      expect(
        FinancialLedgerService.eventsFor(pid)
            .where((e) => e.type == FinancialEventType.rebateGranted),
        isEmpty,
      );
    });
  });

  group('PeriodStats revenue split', () {
    test('rake, houseWin and bankerProfit stay separate', () async {
      final s = await _session('s1');
      final a = await _seat(s, 'Ali', 1);
      await _buyIn(s.id, a, 10000);
      final tableId = TableService.tablesFor(s).first.id;
      await HandService.record(
        sessionId: s.id,
        tableId: tableId,
        kind: HandKind.poker,
        drafts: [HandResultDraft(seatPlayerId: a.id, chipChange: -500)],
        rakeAmount: 500,
      );
      await HandService.record(
        sessionId: s.id,
        tableId: tableId,
        kind: HandKind.houseGame,
        drafts: [HandResultDraft(seatPlayerId: a.id, chipChange: -6000)],
        houseWinAmount: 6000,
        hostSignatureBase64: 'sig',
      );
      final stats = ReportService.lifetime(AppCurrency.usd);
      expect(stats.rake, 500);
      expect(stats.houseWin, 6000);
      expect(stats.bankerProfit, 6500);
      expect(stats.rake + stats.houseWin, stats.bankerProfit);
    });
  });

  group('hands stay operational', () {
    test('hands do not create rebate or cashier P2P', () async {
      final s = await _session('s1');
      final pid = await _person('Ali');
      final a = await _seat(s, 'Ali', 1, personId: pid);
      final b = await _seat(s, 'Baba', 2);
      await HandService.record(
        sessionId: s.id,
        tableId: TableService.tablesFor(s).first.id,
        kind: HandKind.poker,
        drafts: [
          HandResultDraft(seatPlayerId: a.id, chipChange: -4000),
          HandResultDraft(seatPlayerId: b.id, chipChange: 3500),
        ],
        rakeAmount: 500,
      );
      expect(
        FinancialLedgerService.eventsFor(pid)
            .where((e) =>
                e.type == FinancialEventType.rebateGranted ||
                e.type == FinancialEventType.rebateRecovered),
        isEmpty,
      );
      expect(
        SessionService.transactionsFor(s.id).any((t) =>
            t.type == TransactionType.transferIn ||
            t.type == TransactionType.transferOut),
        isFalse,
      );
    });

    test('void does not renumber; last hand skips voided', () async {
      final s = await _session('s1');
      final a = await _seat(s, 'Ali', 1);
      final tableId = TableService.tablesFor(s).first.id;
      final first = await HandService.record(
        sessionId: s.id,
        tableId: tableId,
        kind: HandKind.poker,
        drafts: [HandResultDraft(seatPlayerId: a.id, chipChange: -100)],
        rakeAmount: 100,
      );
      final second = await HandService.record(
        sessionId: s.id,
        tableId: tableId,
        kind: HandKind.poker,
        drafts: [HandResultDraft(seatPlayerId: a.id, chipChange: -50)],
        rakeAmount: 50,
      );
      await HandService.voidHand(second.id);
      expect(HiveService.hands.get(second.id)!.handNumber, 2);
      expect(HandService.lastForTable(s.id, tableId)!.id, first.id);
    });

    test('backup remains v8', () {
      expect(BackupService.formatVersion, 9);
      expect(BackupService.exportPayload()['formatVersion'], 8);
    });
  });

  group('ChipFlow locked types', () {
    test('does not apply to tableCashOut or reentry', () {
      expect(ChipFlow.appliesTo(TransactionType.tableCashOut), isFalse);
      expect(ChipFlow.appliesTo(TransactionType.reentry), isFalse);
      expect(
        () => ChipFlow.reasonFor(TransactionType.tableCashOut),
        throwsArgumentError,
      );
      expect(
        () => ChipFlow.reasonFor(TransactionType.reentry),
        throwsArgumentError,
      );
    });

    test('houseWin reason is houseWin, never buyIn', () {
      expect(ChipFlow.reasonFor(TransactionType.houseWin),
          ChipMovementReason.houseWin);
    });
  });

  group('table cash-out / re-entry chip rules', () {
    test('table cash-out moves no chips; re-entry is not a buy-in', () async {
      await HiveService.chips
          .put('k1000', ChipType(id: 'k1000', value: 1000, quantity: 20));
      final s = await _session('s1', tables: 2);
      final pid = await _person('Ali');
      final a = await _seat(s, 'Ali', 1, personId: pid);
      await _buyIn(s.id, a, 10000);
      await ChipTrackingService.recordDistribution(
        distribution: {'k1000': 10},
        from: ChipLocation.bank,
        to: ChipLocation.player(pid),
        reason: ChipMovementReason.buyIn,
        sessionId: s.id,
      );
      final moves = ChipTrackingService.allMovements().length;
      await RedemptionService.tableCashOut(
        sessionId: s.id,
        seatPlayerId: a.id,
        amount: 6000,
        hostSignatureBase64: 'sig',
      );
      expect(ChipTrackingService.allMovements().length, moves);
      final tables = TableService.tablesFor(s);
      await TableService.reenterWithHeldChips(
        s,
        HiveService.players.get(a.id)!,
        tables[1].id,
        amount: 6000,
        hostSignatureBase64: 'sig',
      );
      expect(SessionService.totalBuyIn(s.id), 10000);
      expect(SessionService.totalReentry(s.id), 6000);
      expect(
        SessionService.transactionsFor(s.id)
            .where((t) => t.type == TransactionType.buyIn),
        hasLength(1),
      );
    });
  });

  group('void reverses post-hand count adjustments', () {
    test('stack count is restored after void', () async {
      await HiveService.chips
          .put('k1000', ChipType(id: 'k1000', value: 1000, quantity: 20));
      final s = await _session('s1');
      final pid = await _person('Ali');
      final a = await _seat(s, 'Ali', 1, personId: pid);
      await ChipTrackingService.recordDistribution(
        distribution: {'k1000': 10},
        from: ChipLocation.bank,
        to: ChipLocation.player(pid),
        reason: ChipMovementReason.buyIn,
        sessionId: s.id,
      );
      expect(
          ChipTrackingService.quantityAt(ChipLocation.player(pid), 'k1000'),
          10);
      final hand = await HandService.record(
        sessionId: s.id,
        tableId: TableService.tablesFor(s).first.id,
        kind: HandKind.poker,
        drafts: [HandResultDraft(seatPlayerId: a.id, chipChange: -4000)],
        rakeAmount: 4000,
        postHandCounts: {
          a.id: {'k1000': 6},
        },
      );
      expect(
          ChipTrackingService.quantityAt(ChipLocation.player(pid), 'k1000'), 6);
      await HandService.voidHand(hand.id);
      expect(
          ChipTrackingService.quantityAt(ChipLocation.player(pid), 'k1000'),
          10);
    });
  });
}
