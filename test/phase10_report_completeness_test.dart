// Phase 10 — cross-layer report completeness.
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
import 'package:poker_ledger/services/export_service.dart';
import 'package:poker_ledger/services/financial_capture.dart';
import 'package:poker_ledger/services/financial_ledger_service.dart';
import 'package:poker_ledger/services/hand_service.dart';
import 'package:poker_ledger/services/hive_service.dart';
import 'package:poker_ledger/services/player_history_service.dart';
import 'package:poker_ledger/services/player_identity_service.dart';
import 'package:poker_ledger/services/rebate_service.dart';
import 'package:poker_ledger/services/redemption_service.dart';
import 'package:poker_ledger/services/report_service.dart';
import 'package:poker_ledger/services/session_service.dart';
import 'package:poker_ledger/services/session_settlement_view.dart';
import 'package:poker_ledger/services/table_service.dart';
import 'package:poker_ledger/widgets/chip_flow.dart';

import 'test_helper.dart';

late Directory _tmp;

Future<void> _open() async {
  _tmp = await Directory.systemTemp.createTemp('pl_p10_');
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

Future<Player> _seat(
  PokerSession s,
  String name,
  int seatNo, {
  String? personId,
  String? id,
  int table = 1,
}) async {
  final tables = TableService.tablesFor(s);
  final p = Player(
    id: id ?? 'seat-${s.id}-${name.toLowerCase()}-$seatNo',
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

  group('Phase 7 settlement split on reports', () {
    test('table cash-out, \$0 bust and cage cash stay distinct', () async {
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
      await RedemptionService.redeem(
        personId: pid,
        currency: AppCurrency.usd,
        amount: 2500,
        funding: ChipCashOutFunding.paidCash,
        sessionId: s.id,
      );

      expect(SessionService.totalCashOut(s.id), 0);
      expect(SessionService.totalTableCashOut(s.id), 6000);
      expect(SessionService.playerProfitLoss(s.id, a.id), -10000);

      final stats = ReportService.lifetime(AppCurrency.usd);
      expect(stats.purchases, 10000);
      expect(stats.reentry, 6000);
      expect(stats.sessionCashOut, 0);
      expect(stats.cashedOut, 0);
      expect(stats.tableCashOut, 6000);
      expect(stats.cageCashOut, 2500);
      expect(stats.moneyIn, 10000);
      expect(stats.moneyIn, isNot(stats.purchases + stats.reentry));

      final row = SessionSettlementView.load(s.id, AppCurrency.usd)
          .players
          .singleWhere((p) => p.player.id == a.id);
      expect(row.tableCashOut, 6000);
      expect(row.sessionCashOut, 0);
      expect(row.cageCashOut, 2500);
      expect(row.reentry, 6000);
      expect(row.chipProfitLoss, -10000);
    });
  });

  group('player net and identity grouping', () {
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
      final row = rows.singleWhere((r) => r.personId == pid);
      expect(row.net, -10000);
      expect(row.purchases, 10000);
      expect(row.tableCashOut, 6000);
      expect(row.reentry, 6000);
    });

    test('two people named Ali stay separate; one person groups', () async {
      final s1 = await _session('night1');
      final s2 = await _session('night2');
      final aliA = await _person('Ali');
      final aliB = await _person('Ali');
      final sam = await _person('Sam');
      final a1 = await _seat(s1, 'Ali', 1, personId: aliA);
      final b1 = await _seat(s1, 'Ali', 2, personId: aliB);
      final sam1 = await _seat(s1, 'Sam', 3, personId: sam);
      await _buyIn(s1.id, a1, 1000);
      await _buyIn(s1.id, b1, 2000);
      await _buyIn(s1.id, sam1, 3000);
      final sam2 = await _seat(s2, 'Sam', 1, personId: sam);
      await _buyIn(s2.id, sam2, 4000);

      final rows = ReportService.playerPerformance(AppCurrency.usd);
      final namedAli = rows.where((r) => r.name == 'Ali').toList();
      expect(namedAli, hasLength(2));
      expect(namedAli.map((r) => r.personId).toSet(), {aliA, aliB});
      expect(namedAli.every((r) => r.isLegacyNameGroup == false), isTrue);

      final samRow = rows.singleWhere((r) => r.personId == sam);
      expect(samRow.sessions, 2);
      expect(samRow.purchases, 7000);
    });
  });

  group('banker CSV and session books', () {
    test('CSV keeps rake, houseWin and profit separate', () async {
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
      expect(stats.rake, isNot(stats.houseWin));
      expect(stats.rake, isNot(stats.bankerProfit));

      final csv = ExportService.bankerCsvRows(AppCurrency.usd);
      expect(csv.first, contains('House Win'));
      expect(csv.first, contains('Rake'));
      expect(csv.first, contains('Banker Profit'));
      expect(csv.first, isNot(contains('Cashed Out')));
      final lifetime = csv[1];
      final headers = csv.first.cast<String>();
      expect(lifetime[headers.indexOf('Rake')], 500);
      expect(lifetime[headers.indexOf('House Win')], 6000);
      expect(lifetime[headers.indexOf('Banker Profit')], 6500);
    });

    test('session export lists table cash-out, re-entry, rake, house win',
        () async {
      final s = await _session('s1', tables: 2);
      final pid = await _person('Ali');
      final a = await _seat(s, 'Ali', 1, personId: pid);
      await _buyIn(s.id, a, 10000);
      final tables = TableService.tablesFor(s);
      await HandService.record(
        sessionId: s.id,
        tableId: tables[0].id,
        kind: HandKind.poker,
        drafts: [HandResultDraft(seatPlayerId: a.id, chipChange: -500)],
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
        drafts: [HandResultDraft(seatPlayerId: a.id, chipChange: -1000)],
        houseWinAmount: 1000,
        hostSignatureBase64: 'sig',
      );

      final rows = ExportService.sessionBooksRows(s);
      final labels = rows.map((r) => r.first).join('\n');
      expect(labels, contains('Table cash-outs'));
      expect(labels, contains('Re-entry'));
      expect(labels, contains('Rake Collected'));
      expect(labels, contains('House Wins'));
      expect(labels, isNot(contains('Cashed out to players')));
      String amount(String needle) =>
          rows.firstWhere((r) => r.first.contains(needle)).last;
      expect(amount('Table cash-outs'), contains('6,000'));
      expect(amount('Re-entry'), contains('6,000'));
      expect(amount('Rake Collected'), contains('500'));
      expect(amount('House Wins'), contains('1,000'));
    });
  });

  group('locked engines unchanged', () {
    test('playerProfitLoss and hostProfit formulas still hold', () async {
      final s = await _session('s1', tables: 2);
      final pid = await _person('Ali');
      final a = await _seat(s, 'Ali', 1, personId: pid);
      await _buyIn(s.id, a, 10000);
      final tables = TableService.tablesFor(s);
      await HandService.record(
        sessionId: s.id,
        tableId: tables[0].id,
        kind: HandKind.poker,
        drafts: [HandResultDraft(seatPlayerId: a.id, chipChange: -500)],
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
        houseWinAmount: 6000,
        hostSignatureBase64: 'sig',
      );
      expect(SessionService.playerProfitLoss(s.id, a.id), -10000);
      expect(SessionService.hostProfit(s.id), 6500);
      expect(
        SessionService.playerProfitLoss(s.id, a.id),
        (SessionService.playerTotalCashOut(s.id, a.id) -
                SessionService.playerReentry(s.id, a.id)) -
            SessionService.playerTotalIn(s.id, a.id),
      );
      expect(
        SessionService.hostProfit(s.id),
        SessionService.totalRake(s.id) + SessionService.totalHouseWin(s.id),
      );
    });

    test('hands create no rebate and no cashier transfer', () async {
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
        FinancialLedgerService.eventsFor(pid).where((e) =>
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
      expect(RebateService.suggest(
        sessionId: s.id,
        personId: pid,
        currency: AppCurrency.usd,
      ).eligibleLossMinor, 0);
    });
  });

  group('backup / l10n / ChipFlow', () {
    test('backup remains v8 and surfaces malformed hands', () async {
      expect(BackupService.formatVersion, 9);
      expect(BackupService.exportPayload()['formatVersion'], 8);
      final result = await BackupService.importPayload({
        'formatVersion': 9,
        'sessions': const [],
        'players': const [],
        'transactions': const [],
        'hands': [
          {'not': 'a hand'},
          'bad',
        ],
      });
      expect(result.formatVersion, 9);
      expect(result.handsImported, 0);
      expect(result.handsSkipped, 2);
    });

    test('EN/FA key parity', () {
      expect(
        AppLocalizations.keysOf('en').toSet(),
        AppLocalizations.keysOf('fa').toSet(),
      );
      expect(AppLocalizations.lookup('en', 'report_cage_cash'),
          isNot('report_cage_cash'));
      expect(AppLocalizations.lookup('fa', 'report_cage_cash'),
          isNot(AppLocalizations.lookup('en', 'report_cage_cash')));
    });

    test('ChipFlow still excludes tableCashOut and reentry', () {
      expect(ChipFlow.appliesTo(TransactionType.tableCashOut), isFalse);
      expect(ChipFlow.appliesTo(TransactionType.reentry), isFalse);
    });
  });
}
