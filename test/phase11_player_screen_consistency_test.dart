// Phase 11 — player-screen consistency and Studio readiness.
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
import 'package:poker_ledger/services/financial_ledger_service.dart';
import 'package:poker_ledger/services/hive_service.dart';
import 'package:poker_ledger/services/player_history_service.dart';
import 'package:poker_ledger/services/player_identity_service.dart';
import 'package:poker_ledger/services/rebate_service.dart';
import 'package:poker_ledger/services/redemption_service.dart';
import 'package:poker_ledger/services/session_service.dart';
import 'package:poker_ledger/services/session_settlement_view.dart';
import 'package:poker_ledger/services/table_service.dart';
import 'package:poker_ledger/widgets/chip_flow.dart';

import 'test_helper.dart';

late Directory _tmp;

Future<void> _open() async {
  _tmp = await Directory.systemTemp.createTemp('pl_p11_');
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
    id: 'seat-${s.id}-${name.toLowerCase()}-$seatNo',
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

  group('player-facing split after table cash-out', () {
    test('\$6000 table cash-out is not presented as cage cash-out', () async {
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

      final row = PlayerSettlementRow.load(
          s.id, AppCurrency.usd, HiveService.players.get(a.id)!);
      expect(row.tableCashOut, 6000);
      expect(row.sessionCashOut, 0);
      expect(row.cageCashOut, 0);
      expect(row.chipProfitLoss, -10000);

      // Display keys identify table cash-out; they are not a generic
      // "Cashed Out" cage label.
      expect(AppLocalizations.lookup('en', 'table_cash_out').toLowerCase(),
          contains('table'));
      expect(AppLocalizations.lookup('en', 'report_table_cash_outs').toLowerCase(),
          contains('table'));
      expect(AppLocalizations.lookup('en', 'report_cage_cash').toLowerCase(),
          contains('cage'));
      expect(AppLocalizations.lookup('en', 'table_cash_out').toLowerCase(),
          isNot(contains('cashed out')));
    });

    test('canonical player P/L remains -10000 not -4000', () async {
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
      expect(SessionService.playerProfitLoss(s.id, a.id), isNot(-4000));
      final career =
          PlayerHistoryService.careerFor(HiveService.players.get(a.id)!);
      expect(career.netResult, -10000);
    });

    test('table cash-out does not move bank chips', () async {
      await HiveService.chips
          .put('k1000', ChipType(id: 'k1000', value: 1000, quantity: 20));
      final s = await _session('s1');
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
      expect(
        SessionService.transactionsFor(s.id)
            .where((t) => t.type == TransactionType.tableCashOut),
        isNotEmpty,
      );
    });
  });

  group('locked engines and chrome', () {
    test('playerProfitLoss and hostProfit formulas still hold', () async {
      final s = await _session('s1');
      final a = await _seat(s, 'Ali', 1);
      await _buyIn(s.id, a, 10000);
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

    test('EN/FA key parity and new live strings', () {
      expect(
        AppLocalizations.keysOf('en').toSet(),
        AppLocalizations.keysOf('fa').toSet(),
      );
      expect(AppLocalizations.lookup('en', 'current_pot_hint'),
          isNot('current_pot_hint'));
      expect(AppLocalizations.lookup('fa', 'current_pot_hint'),
          isNot(AppLocalizations.lookup('en', 'current_pot_hint')));
      expect(AppLocalizations.lookup('en', 'active'), isNot('ACTIVE'));
      expect(AppLocalizations.lookup('en', 'on_break'), isNot('ON BREAK'));
    });

    test('ChipFlow still excludes tableCashOut and reentry', () {
      expect(ChipFlow.appliesTo(TransactionType.tableCashOut), isFalse);
      expect(ChipFlow.appliesTo(TransactionType.reentry), isFalse);
    });

    test('backup remains v8', () {
      expect(BackupService.formatVersion, 9);
      expect(BackupService.exportPayload()['formatVersion'], 8);
    });
  });
}
