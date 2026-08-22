// Phase 8 — Hand History & Last Hand Summary.
//
// Hands are an operational pot record. They must NOT replace session
// P/L, Discount, redemption, or introduce a cashier P2P transfer.
//
// Canonical poker pot:
//   A chipChange = -4000
//   B chipChange = +3500
//   rake = 500
//   houseWin = 0
//   pot = 4000
//   A's loss = 4000, NOT 3500.
//
// Canonical house-game follow-on:
//   A chipChange = -6000
//   houseWin = 6000
//   rake = 0
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
import 'package:poker_ledger/services/financial_capture.dart';
import 'package:poker_ledger/services/chip_tracking_service.dart';
import 'package:poker_ledger/services/financial_ledger_service.dart';
import 'package:poker_ledger/services/hand_service.dart';
import 'package:poker_ledger/services/hive_service.dart';
import 'package:poker_ledger/services/player_identity_service.dart';
import 'package:poker_ledger/services/rebate_service.dart';
import 'package:poker_ledger/services/redemption_service.dart';
import 'package:poker_ledger/services/session_service.dart';
import 'package:poker_ledger/services/table_service.dart';

import 'test_helper.dart';

late Directory _tmp;

Future<void> _open() async {
  _tmp = await Directory.systemTemp.createTemp('pl_p8hh_');
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

  group('canonical poker pot', () {
    test('A loses 4000, not 3500; B +3500; rake 500; houseWin 0', () async {
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

      expect(hand.potAmount, 4000);
      expect(hand.rakeAmount, 500);
      expect(hand.houseWinAmount, 0);
      expect(hand.resultFor(a.id)!.chipChange, -4000);
      expect(hand.resultFor(a.id)!.isLoser, isTrue);
      expect(hand.resultFor(a.id)!.isWinner, isFalse);
      expect(hand.resultFor(b.id)!.chipChange, 3500);
      expect(hand.resultFor(b.id)!.isWinner, isTrue);
      expect(hand.resultFor(a.id)!.chipChange, isNot(-3500));

      expect(SessionService.totalRake(s.id), 500);
      expect(SessionService.totalHouseWin(s.id), 0);
      expect(SessionService.hostProfit(s.id), 500);
      expect(HandService.lastForTable(s.id, tableId)!.id, hand.id);
    });

    test('storing A as -3500 because of rake is refused', () async {
      final s = await _session('s1');
      final a = await _seat(s, 'Ali', 1);
      final b = await _seat(s, 'Baba', 2);
      final tableId = TableService.tablesFor(s).first.id;
      await expectLater(
        HandService.record(
          sessionId: s.id,
          tableId: tableId,
          kind: HandKind.poker,
          drafts: [
            HandResultDraft(seatPlayerId: a.id, chipChange: -3500),
            HandResultDraft(seatPlayerId: b.id, chipChange: 3500),
          ],
          rakeAmount: 500,
        ),
        throwsA(isA<HandException>()),
      );
    });
  });

  group('canonical house-game follow-on', () {
    test('A -6000, houseWin 6000, rake stays 500', () async {
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

      final house = await HandService.record(
        sessionId: s.id,
        tableId: tables[1].id,
        kind: HandKind.houseGame,
        drafts: [
          HandResultDraft(seatPlayerId: a.id, chipChange: -6000),
        ],
        potAmount: 6000,
        houseWinAmount: 6000,
        hostSignatureBase64: 'sig',
      );

      expect(house.rakeAmount, 0);
      expect(house.houseWinAmount, 6000);
      expect(house.resultFor(a.id)!.chipChange, -6000);
      expect(SessionService.totalRake(s.id), 500);
      expect(SessionService.totalHouseWin(s.id), 6000);
      expect(SessionService.totalBuyIn(s.id), 20000);
      expect(
        SessionService.transactionsFor(s.id)
            .where((t) => t.type == TransactionType.buyIn),
        hasLength(2),
      );

      await RedemptionService.tableCashOut(
        sessionId: s.id,
        seatPlayerId: a.id,
        amount: 0,
        hostSignatureBase64: 'sig',
      );
      await RedemptionService.tableCashOut(
        sessionId: s.id,
        seatPlayerId: b.id,
        amount: 13500,
        hostSignatureBase64: 'sig',
      );
      expect(SessionService.playerProfitLoss(s.id, a.id), -10000);
      expect(SessionService.playerProfitLoss(s.id, b.id), 3500);
    });
  });

  group('kind guards and conservation', () {
    test('poker + houseWin is refused', () async {
      final s = await _session('s1');
      final a = await _seat(s, 'Ali', 1);
      await expectLater(
        HandService.record(
          sessionId: s.id,
          tableId: TableService.tablesFor(s).first.id,
          kind: HandKind.poker,
          drafts: [HandResultDraft(seatPlayerId: a.id, chipChange: -100)],
          houseWinAmount: 100,
        ),
        throwsA(isA<HandException>()),
      );
    });

    test('house game + rake is refused', () async {
      final s = await _session('s1');
      final a = await _seat(s, 'Ali', 1);
      await expectLater(
        HandService.record(
          sessionId: s.id,
          tableId: TableService.tablesFor(s).first.id,
          kind: HandKind.houseGame,
          drafts: [HandResultDraft(seatPlayerId: a.id, chipChange: -100)],
          rakeAmount: 100,
          hostSignatureBase64: 'sig',
        ),
        throwsA(isA<HandException>()),
      );
    });

    test('unseated / held chips cannot be on a hand', () async {
      final s = await _session('s1');
      final a = await _seat(s, 'Ali', 1);
      a.seated = false;
      a.tableId = null;
      await a.save();
      await expectLater(
        HandService.record(
          sessionId: s.id,
          tableId: TableService.tablesFor(s).first.id,
          kind: HandKind.poker,
          drafts: [HandResultDraft(seatPlayerId: a.id, chipChange: -100)],
        ),
        throwsA(isA<HandException>()),
      );
    });
  });

  group('last hand and void', () {
    test('last hand is per-table; voiding reveals the previous', () async {
      final s = await _session('s1', tables: 2);
      final a = await _seat(s, 'Ali', 1);
      final b = await _seat(s, 'Baba', 2, table: 2);
      final tables = TableService.tablesFor(s);

      final first = await HandService.record(
        sessionId: s.id,
        tableId: tables[0].id,
        kind: HandKind.poker,
        drafts: [HandResultDraft(seatPlayerId: a.id, chipChange: -100)],
        rakeAmount: 100,
      );
      final second = await HandService.record(
        sessionId: s.id,
        tableId: tables[0].id,
        kind: HandKind.poker,
        drafts: [HandResultDraft(seatPlayerId: a.id, chipChange: -50)],
        rakeAmount: 50,
      );
      await HandService.record(
        sessionId: s.id,
        tableId: tables[1].id,
        kind: HandKind.houseGame,
        drafts: [HandResultDraft(seatPlayerId: b.id, chipChange: -20)],
        houseWinAmount: 20,
        hostSignatureBase64: 'sig',
      );

      expect(HandService.lastForTable(s.id, tables[0].id)!.id, second.id);
      expect(HandService.lastForTable(s.id, tables[1].id)!.handNumber, 1);
      expect(second.handNumber, 2);

      await HandService.voidHand(second.id);
      expect(HandService.lastForTable(s.id, tables[0].id)!.id, first.id);
      expect(HiveService.hands.get(second.id)!.isVoided, isTrue);
      expect(HiveService.hands.get(second.id)!.handNumber, 2);
      expect(SessionService.totalRake(s.id), 100);

      final third = await HandService.record(
        sessionId: s.id,
        tableId: tables[0].id,
        kind: HandKind.poker,
        drafts: [HandResultDraft(seatPlayerId: a.id, chipChange: -10)],
        rakeAmount: 10,
      );
      expect(third.handNumber, 3);
    });

    test('split pot may have multiple winners', () async {
      final s = await _session('s1');
      final a = await _seat(s, 'Ali', 1);
      final b = await _seat(s, 'Baba', 2);
      final c = await _seat(s, 'Cara', 3);
      final hand = await HandService.record(
        sessionId: s.id,
        tableId: TableService.tablesFor(s).first.id,
        kind: HandKind.poker,
        drafts: [
          HandResultDraft(seatPlayerId: a.id, chipChange: -200),
          HandResultDraft(seatPlayerId: b.id, chipChange: 100),
          HandResultDraft(seatPlayerId: c.id, chipChange: 100),
        ],
      );
      expect(hand.results.where((r) => r.isWinner).length, 2);
      expect(hand.potAmount, 200);
    });
  });

  group('Phase 7 ownership stays intact', () {
    test('no cashier P2P transfer is created', () async {
      final s = await _session('s1');
      final a = await _seat(s, 'Ali', 1);
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
        SessionService.transactionsFor(s.id)
            .any((t) => t.type == TransactionType.transferIn ||
                t.type == TransactionType.transferOut),
        isFalse,
      );
      expect(
        ChipTrackingService.allMovements(sessionId: s.id)
            .any((m) => m.reasonEnum == ChipMovementReason.transfer),
        isFalse,
      );
    });

    test('table cash-out is not a hand and moves no chips', () async {
      await HiveService.chips.put(
          'k1000', ChipType(id: 'k1000', value: 1000, quantity: 20));
      final s = await _session('s1');
      final pid = await _person('Ali');
      final a = await _seat(s, 'Ali', 1, personId: pid);
      await SessionService.recordTransaction(
        sessionId: s.id,
        playerId: a.id,
        type: TransactionType.buyIn,
        amount: 10000,
        hostSignatureBase64: 'sig',
      );
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
      expect(HandService.forSession(s.id), isEmpty);
      expect(ChipTrackingService.allMovements().length, moves);
      expect(ChipTrackingService.holdingAt(ChipLocation.player(pid)).totalValue,
          10000);
    });

    test('re-entry after a hand does not create another buy-in', () async {
      final s = await _session('s1', tables: 2);
      final pid = await _person('Ali');
      final a = await _seat(s, 'Ali', 1, personId: pid);
      await _buyIn(s.id, a, 10000);
      final tables = TableService.tablesFor(s);
      await HandService.record(
        sessionId: s.id,
        tableId: tables[0].id,
        kind: HandKind.poker,
        drafts: [HandResultDraft(seatPlayerId: a.id, chipChange: -4000)],
        rakeAmount: 4000,
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
      expect(SessionService.totalBuyIn(s.id), 10000);
      expect(SessionService.totalReentry(s.id), 6000);
    });

    test('redemption remains the only person → bank cashOut movement',
        () async {
      await HiveService.chips.put(
          'k1000', ChipType(id: 'k1000', value: 1000, quantity: 20));
      final s = await _session('s1');
      final pid = await _person('Ali');
      final a = await _seat(s, 'Ali', 1, personId: pid);
      await ChipTrackingService.recordDistribution(
        distribution: {'k1000': 6},
        from: ChipLocation.bank,
        to: ChipLocation.player(pid),
        reason: ChipMovementReason.buyIn,
        sessionId: s.id,
      );
      await RedemptionService.tableCashOut(
        sessionId: s.id,
        seatPlayerId: a.id,
        amount: 6000,
        hostSignatureBase64: 'sig',
      );
      expect(
        ChipTrackingService.allMovements()
            .where((m) => m.reasonEnum == ChipMovementReason.cashOut),
        isEmpty,
      );
      await RedemptionService.redeem(
        personId: pid,
        currency: AppCurrency.usd,
        amount: 6000,
        funding: ChipCashOutFunding.paidCash,
        composition: {'k1000': 6},
        sessionId: s.id,
        hostSignatureBase64: 'sig',
      );
      expect(
        ChipTrackingService.allMovements()
            .where((m) =>
                m.reasonEnum == ChipMovementReason.cashOut &&
                m.from.isPlayer &&
                m.to.isBank),
        isNotEmpty,
      );
      expect(HandService.forSession(s.id), isEmpty);
    });
  });

  group('Discount is not rewritten', () {
    test('qualifying loss stays own-cash 10000 after both activities',
        () async {
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
      await HandService.record(
        sessionId: s.id,
        tableId: tables[0].id,
        kind: HandKind.poker,
        drafts: [HandResultDraft(seatPlayerId: a.id, chipChange: -4000)],
        rakeAmount: 4000,
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

      expect(
        FinancialLedgerService.eventsFor(pid)
            .where((e) =>
                e.type == FinancialEventType.rebateGranted ||
                e.type == FinancialEventType.rebateRecovered),
        isEmpty,
      );
      final sug = RebateService.suggest(
        sessionId: s.id,
        personId: pid,
        currency: AppCurrency.usd,
        bustRealized: true,
      );
      expect(sug.canGrant, isTrue);
      expect(sug.eligibleLossMinor, 1000000);
      expect(sug.grantMinor, 100000);
      final snap = RebateService.snapshot(
        sessionId: s.id,
        personId: pid,
        currency: AppCurrency.usd,
      );
      expect(snap.playerCashIn, 10000);
      expect(snap.grossLoss, 10000);
    });
  });

  group('backup v8', () {
    test('export includes hands; v7 import leaves hands intact', () async {
      final s = await _session('s1');
      final a = await _seat(s, 'Ali', 1);
      final hand = await HandService.record(
        sessionId: s.id,
        tableId: TableService.tablesFor(s).first.id,
        kind: HandKind.poker,
        drafts: [HandResultDraft(seatPlayerId: a.id, chipChange: -40)],
        rakeAmount: 40,
      );
      final payload = BackupService.exportPayload();
      expect(payload['formatVersion'], 8);
      expect(BackupService.formatVersion, 8);
      expect((payload['hands'] as List), hasLength(1));

      await HiveService.hands.clear();
      expect(HandService.forSession(s.id), isEmpty);
      final result = await BackupService.importPayload(payload);
      expect(result.handsImported, 1);
      expect(HiveService.hands.get(hand.id)!.rakeAmount, 40);

      final older = Map<String, dynamic>.from(payload)..remove('hands');
      older['formatVersion'] = 7;
      await HiveService.hands.clear();
      await HiveService.hands.put(hand.id, hand);
      final oldResult = await BackupService.importPayload(older);
      expect(oldResult.handsImported, 0);
      expect(HiveService.hands.get(hand.id), isNotNull);
    });
  });

  group('localization', () {
    test('new hand keys exist in EN and FA', () {
      const keys = [
        'last_hand',
        'hand_history',
        'record_hand',
        'hand_number',
        'hand_kind_poker',
        'hand_kind_house',
        'hand_pot',
        'hand_rake',
        'hand_house_win',
        'hand_winner',
        'hand_loser',
        'hand_chip_change',
        'no_hands_yet',
        'void_hand',
        'hand_conservation_error',
        'hand_rake_not_on_house',
        'hand_house_win_not_on_poker',
        'last_hand_empty',
      ];
      for (final key in keys) {
        final en = AppLocalizations.lookup('en', key);
        final fa = AppLocalizations.lookup('fa', key);
        expect(en, isNot(key), reason: key);
        expect(fa, isNot(key), reason: key);
        expect(en, isNot(fa), reason: key);
      }
      expect(
        AppLocalizations.keysOf('en').toSet(),
        AppLocalizations.keysOf('fa').toSet(),
      );
    });
  });
}
