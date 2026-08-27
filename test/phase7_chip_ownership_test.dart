// Phase 7 — FINAL CHIP OWNERSHIP, TABLE CASH-OUT, AND RE-ENTRY MODEL.
//
// These tests lock the approved business rule:
//   * A chip is not casino-owned merely because it is at a table.
//   * Player-to-player poker losses are NOT casino revenue; rake IS.
//   * A table cash-out closes the participation and frees the seat, but
//     the chips stay the person's physical holding — no chip movement,
//     no bank leg, no cashier cash-out, no redemption.
//   * Re-entry commits the player's EXISTING person-scoped holding to a
//     new table: no second buy-in, no second bank -> player issuance,
//     no duplicated financial transaction, a new TableParticipation.
//   * House-banked games CAN make chips casino-owned, and house-game
//     revenue stays distinguishable from poker rake.
//   * Final redemption is the ONLY operation that moves the person's
//     chips back to the bank (with the marker gate enforced).
//
// Canonical example (spec §2): A starts 10,000, B starts 10,000, A loses
// 4,000 to B, rake 500 from the pool -> A = 6,000, B = 13,500, rake =
// 500, total 20,000 conserved.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:poker_ledger/models/chip_movement.dart';
import 'package:poker_ledger/models/chip_type.dart';
import 'package:poker_ledger/models/enums.dart';
import 'package:poker_ledger/models/financial_event.dart';
import 'package:poker_ledger/models/player.dart';
import 'package:poker_ledger/models/player_identity.dart';
import 'package:poker_ledger/models/session.dart';
import 'package:poker_ledger/models/table_participation.dart';
import 'package:poker_ledger/models/transaction.dart';
import 'package:poker_ledger/services/chip_tracking_service.dart';
import 'package:poker_ledger/services/financial_capture.dart';
import 'package:poker_ledger/services/financial_ledger_service.dart';
import 'package:poker_ledger/services/hive_service.dart';
import 'package:poker_ledger/services/participation_service.dart';
import 'package:poker_ledger/services/player_identity_service.dart';
import 'package:poker_ledger/services/redemption_service.dart';
import 'package:poker_ledger/services/session_service.dart';
import 'package:poker_ledger/services/table_service.dart';
import 'package:poker_ledger/services/wallet_service.dart';

import 'test_helper.dart';

late Directory _tmp;

Future<void> _open() async {
  _tmp = await Directory.systemTemp.createTemp('pl_p7co_');
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

/// Stocks the case with the denominations the canonical example needs:
/// 20 x $1,000 + 10 x $500 = 25,000.
Future<void> _stockBank() async {
  await HiveService.chips.put(
      'k1000', ChipType(id: 'k1000', value: 1000, quantity: 20));
  await HiveService.chips.put(
      'k500', ChipType(id: 'k500', value: 500, quantity: 10));
}

double _bank() => ChipTrackingService.currentBankValue();

double _held(String personId) =>
    ChipTrackingService.holdingAt(ChipLocation.player(personId)).totalValue;

int _movements() => HiveService.chipMovements.length;

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
  if (chips != null) {
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

void main() {
  setUp(_open);
  tearDown(_close);

  group('A. Table cash-out (spec 11.A)', () {
    test('closes participation, frees seat, touches nothing else',
        () async {
      await _stockBank();
      final s = await _session('s1');
      final pidA = await _person('Ali');
      final a = await _seat(s, 'Ali', 1, personId: pidA);
      await _buyIn(s.id, a, 10000, chips: {'k1000': 10});

      final partId =
          ParticipationService.forSession(s.id).single.id;
      final bankBefore = _bank();
      final movesBefore = _movements();
      final finBefore =
          FinancialLedgerService.eventsFor(pidA).length;

      await RedemptionService.tableCashOut(
        sessionId: s.id,
        seatPlayerId: a.id,
        amount: 6000,
        hostSignatureBase64: 'sig',
      );

      // Participation closed with the tableCashOut reason.
      final p = HiveService.participations.get(partId)!;
      expect(p.isOpen, isFalse);
      expect(p.closeReason, ParticipationCloseReason.tableCashOut);

      // Seat released.
      final seat = HiveService.players.get(a.id)!;
      expect(seat.seated, isFalse);
      expect(seat.tableId, isNull);

      // THE PERSON'S CHIP HOLDING IS PRESERVED — no chip movement.
      expect(_held(pidA), 10000);
      expect(_movements(), movesBefore);
      // The bank is untouched — no chips went to the case.
      expect(_bank(), bankBefore);
      // No cashier/cage cash-out was created — no financial events.
      expect(FinancialLedgerService.eventsFor(pidA).length, finBefore);

      // Session book: the carried-out amount is a table-level out, and
      // the table now considers the player settled.
      expect(SessionService.totalTableCashOut(s.id), 6000);
      expect(SessionService.hasCashedOut(s.id, a.id), isTrue);
      expect(SessionService.checkBalance(s.id).moneyOut, 6000);
    });

    test('a \$0 table cash-out is a valid bust', () async {
      await _stockBank();
      final s = await _session('s1');
      final pidA = await _person('Ali');
      final a = await _seat(s, 'Ali', 1, personId: pidA);
      await _buyIn(s.id, a, 10000, chips: {'k1000': 10});

      // A loses everything at the table and busts out for \$0.
      final tx = await RedemptionService.tableCashOut(
        sessionId: s.id,
        seatPlayerId: a.id,
        amount: 0,
        hostSignatureBase64: 'sig',
      );
      expect(tx.type, TransactionType.tableCashOut);
      expect(tx.amount, 0);

      // Settled (the \$0 leg counts as a cash-out record), seat freed,
      // participation closed.
      expect(SessionService.hasCashedOut(s.id, a.id), isTrue);
      expect(HiveService.players.get(a.id)!.seated, isFalse);
      expect(ParticipationService.forSession(s.id).single.isOpen, isFalse);
      // Result: put in 10,000, took out 0 -> down the full buy-in.
      expect(SessionService.playerProfitLoss(s.id, a.id), -10000);
      // The session books: in 10,000, out 0 -> 10,000 in play
      // (with the other players A lost to).
      final bal = SessionService.checkBalance(s.id);
      expect(bal.moneyIn, 10000);
      expect(bal.moneyOut, 0);
    });
  });

  group('B. Re-entry with carried chips (spec 11.B)', () {
    test('no second buy-in, no issuance, new participation', () async {
      await _stockBank();
      final s = await _session('s1', tables: 2);
      final pidA = await _person('Ali');
      final a = await _seat(s, 'Ali', 1, personId: pidA);
      await _buyIn(s.id, a, 10000, chips: {'k1000': 10});
      final tables = TableService.tablesFor(s);

      // A loses 4,000 to someone (physical count) and leaves with 6,000.
      await ChipTrackingService.adjustPlayerHoldingToCount(
        playerId: pidA,
        counted: {'k1000': 6},
        sessionId: s.id,
      );
      await RedemptionService.tableCashOut(
        sessionId: s.id,
        seatPlayerId: a.id,
        amount: 6000,
        hostSignatureBase64: 'sig',
      );
      final movesBefore = _movements();
      final finBefore = FinancialLedgerService.eventsFor(pidA).length;

      // RE-ENTRY at Table 2 with the same 6,000 chips.
      final tx = await TableService.reenterWithHeldChips(
        s,
        HiveService.players.get(a.id)!,
        tables[1].id,
        amount: 6000,
        hostSignatureBase64: 'sig',
      );

      // One re-entry leg — NOT a buy-in.
      expect(tx.type, TransactionType.reentry);
      expect(SessionService.totalBuyIn(s.id), 10000,
          reason: 'the original purchase is never counted again');
      expect(SessionService.totalReentry(s.id), 6000);
      expect(
        SessionService.transactionsFor(s.id)
            .where((t) =>
                t.type == TransactionType.buyIn ||
                t.type == TransactionType.rebuy),
        hasLength(1),
      );

      // Seated at the destination.
      final seat = HiveService.players.get(a.id)!;
      expect(seat.seated, isTrue);
      expect(seat.tableId, tables[1].id);

      // A NEW participation opened at the destination; the old one is
      // closed (by the table cash-out).
      final parts = ParticipationService.forSession(s.id);
      expect(parts, hasLength(2));
      final dest = parts.singleWhere((p) => p.tableId == tables[1].id);
      expect(dest.isOpen, isTrue);
      expect(dest.personId, pidA);
      expect(ParticipationService.legsFor(dest.id).moneyIn, 6000);

      // NO chip movement — the held chips travel with the person.
      expect(_held(pidA), 6000);
      expect(_movements(), movesBefore,
          reason: 'no bank -> player issuance on re-entry');
      // NO duplicated financial transaction.
      expect(FinancialLedgerService.eventsFor(pidA).length, finBefore);

      // Session identity: re-entry is money IN, balancing the carried
      // table cash-out.
      final bal = SessionService.checkBalance(s.id);
      expect(bal.moneyIn, 16000); // 10,000 buy-in + 6,000 re-entry
      expect(bal.moneyOut, 6000); // the carried table cash-out
      expect(bal.discrepancy, 10000); // the commitment, in play
    });

    test('guards: seated player, unlinked person, non-positive amount',
        () async {
      await _stockBank();
      final s = await _session('s1', tables: 2);
      final pidA = await _person('Ali');
      final a = await _seat(s, 'Ali', 1, personId: pidA);
      final unlinked = await _seat(s, 'Guest', 2);
      final tables = TableService.tablesFor(s);

      // Already seated: refuse.
      await expectLater(
        TableService.reenterWithHeldChips(
          s,
          a,
          tables[1].id,
          amount: 1000,
          hostSignatureBase64: 'sig',
        ),
        throwsStateError,
      );

      // Unlinked (no person, no holding to carry): refuse. Unseat it so
      // the person check is what fires, not the already-seated check.
      unlinked.seated = false;
      unlinked.tableId = null;
      await unlinked.save();
      await expectLater(
        TableService.reenterWithHeldChips(
          s,
          unlinked,
          tables[0].id,
          amount: 1000,
          hostSignatureBase64: 'sig',
        ),
        throwsStateError,
      );

      // Non-positive amount: refuse.
      final aUnseated = HiveService.players.get(a.id)!;
      aUnseated.seated = false;
      aUnseated.tableId = null;
      await aUnseated.save();
      await expectLater(
        TableService.reenterWithHeldChips(
          s,
          aUnseated,
          tables[1].id,
          amount: 0,
          hostSignatureBase64: 'sig',
        ),
        throwsArgumentError,
      );
    });
  });

  group('C. Canonical poker ownership example (spec §2 + 11.C)', () {
    test('A 6,000 / B 13,500 / rake 500 — session balances, P/L correct',
        () async {
      await _stockBank();
      final s = await _session('s1', tables: 2);
      final pidA = await _person('Ali');
      final pidB = await _person('Baba');
      final a = await _seat(s, 'Ali', 1, personId: pidA);
      final b = await _seat(s, 'Baba', 2, personId: pidB);
      final tables = TableService.tablesFor(s);

      // Both buy in for 10,000 (chips bank -> person).
      await _buyIn(s.id, a, 10000, chips: {'k1000': 10});
      await _buyIn(s.id, b, 10000, chips: {'k1000': 8, 'k500': 4});

      // Play: A loses 4,000 to B (captured by physical counts; the
      // pair nets to zero for the bank).
      await ChipTrackingService.adjustPlayerHoldingToCount(
        playerId: pidA,
        counted: {'k1000': 6},
        sessionId: s.id,
      );
      await ChipTrackingService.adjustPlayerHoldingToCount(
        playerId: pidB,
        counted: {'k1000': 12, 'k500': 4},
        sessionId: s.id,
      );

      // Rake 500, from the pool, to the casino (chips -> bank).
      await SessionService.recordTransaction(
        sessionId: s.id,
        type: TransactionType.rakeCollection,
        amount: 500,
        tableId: tables[0].id,
      );
      await ChipTrackingService.record(
        chipTypeId: 'k500',
        quantity: 1,
        from: ChipLocation.player(pidB),
        to: ChipLocation.bank,
        reason: ChipMovementReason.rake,
        sessionId: s.id,
      );

      // A leaves Table 1 with 6,000 (TABLE CASH-OUT — not a redemption).
      await RedemptionService.tableCashOut(
        sessionId: s.id,
        seatPlayerId: a.id,
        amount: 6000,
        hostSignatureBase64: 'sig',
      );
      // Mid-game in-play: B's 13,500 at Table 1; A's 6,000 is with A.
      expect(SessionService.moneyStillInPlay(s.id), 13500);

      // A re-enters Table 2 with the SAME 6,000 chips.
      await TableService.reenterWithHeldChips(
        s,
        HiveService.players.get(a.id)!,
        tables[1].id,
        amount: 6000,
        hostSignatureBase64: 'sig',
      );
      // In-play now: 13,500 (Table 1) + 6,000 (Table 2).
      expect(SessionService.moneyStillInPlay(s.id), 19500);

      // B leaves Table 1 with 13,500; A later leaves Table 2 with 6,000.
      await RedemptionService.tableCashOut(
        sessionId: s.id,
        seatPlayerId: b.id,
        amount: 13500,
        hostSignatureBase64: 'sig',
      );
      await RedemptionService.tableCashOut(
        sessionId: s.id,
        seatPlayerId: a.id,
        amount: 6000,
        hostSignatureBase64: 'sig',
      );

      // SESSION BALANCES — every carried chip is accounted for.
      final bal = SessionService.checkBalance(s.id);
      expect(bal.isBalanced, isTrue, reason: bal.possibleCauses.join(', '));
      expect(bal.moneyIn, 26000); // 20,000 buy-ins + 6,000 re-entry
      expect(bal.moneyOut, 26000);

      // THE CANONICAL FIGURES (spec §2).
      expect(_held(pidA), 6000);
      expect(_held(pidB), 13500);
      expect(SessionService.totalRake(s.id), 500);
      // 6,000 + 13,500 + 500 = 20,000 — the 4,000 A lost simply changed
      // player ownership; no 4,000 cash returned to the casino.
      expect(_held(pidA) + _held(pidB) + SessionService.totalRake(s.id),
          20000);

      // P/L: A lost exactly the 4,000 he played away; B won 4,000 and
      // paid the 500 rake. Sum of P/L == -rake.
      expect(SessionService.playerProfitLoss(s.id, a.id), -4000);
      expect(SessionService.playerProfitLoss(s.id, b.id), 3500);
      expect(
        SessionService.playerProfitLoss(s.id, a.id) +
            SessionService.playerProfitLoss(s.id, b.id),
        -SessionService.totalRake(s.id),
      );

      // Casino revenue = rake only. Player-to-player losses are NOT
      // revenue: the house kept 500, not 4,500.
      expect(SessionService.hostProfit(s.id), 500);
      expect(SessionService.hostProfit(s.id),
          SessionService.totalRake(s.id));

      // No double-counting: the 10,000 purchases are counted ONCE.
      expect(SessionService.totalBuyIn(s.id), 20000);

      // Both tables are settled.
      final sums = TableSummary.forSession(s);
      final sumA = sums.singleWhere((x) => x.table.id == tables[0].id);
      final sumB = sums.singleWhere((x) => x.table.id == tables[1].id);
      expect(sumA.currentPot, 0);
      expect(sumA.moneyIn, 20000);
      expect(sumA.moneyOut, 20000);
      expect(sumB.currentPot, 0);
      expect(sumB.moneyIn, 6000); // the re-entry
      expect(sumB.moneyOut, 6000); // A's table cash-out at Table 2
    });

    test('re-entry cycles balance across multiple leaves', () async {
      final s = await _session('s1', tables: 2);
      final pidA = await _person('Ali');
      final a = await _seat(s, 'Ali', 1, personId: pidA);
      await _buyIn(s.id, a, 10000);
      final tables = TableService.tablesFor(s);

      // T1: leave with 6,000 -> T2: leave with 4,000 -> T1: leave with
      // 4,000 (lost 2,000 in play at T2, 4,000 at T1).
      await RedemptionService.tableCashOut(
          sessionId: s.id, seatPlayerId: a.id, amount: 6000,
          hostSignatureBase64: 'sig');
      await TableService.reenterWithHeldChips(
          s, HiveService.players.get(a.id)!, tables[1].id,
          amount: 6000, hostSignatureBase64: 'sig');
      await RedemptionService.tableCashOut(
          sessionId: s.id, seatPlayerId: a.id, amount: 4000,
          hostSignatureBase64: 'sig');
      await TableService.reenterWithHeldChips(
          s, HiveService.players.get(a.id)!, tables[0].id,
          amount: 4000, hostSignatureBase64: 'sig');
      await RedemptionService.tableCashOut(
          sessionId: s.id, seatPlayerId: a.id, amount: 4000,
          hostSignatureBase64: 'sig');

      final bal = SessionService.checkBalance(s.id);
      expect(bal.moneyIn, 20000); // 10,000 + 6,000 + 4,000
      expect(bal.moneyOut, 14000); // 6,000 + 4,000 + 4,000
      // 6,000 still in play: A's 4,000 carried out + the 2,000 A lost at
      // Table 2 (now with another player, still in the session).
      expect(bal.discrepancy, 6000);
      expect(SessionService.moneyStillInPlay(s.id), 6000);

      // A's net: put in 10,000, kept 4,000, lost 6,000 in play.
      expect(SessionService.playerProfitLoss(s.id, a.id), -6000);
    });
  });

  group('D. House-banked games (spec §6/§7 + 11.D)', () {
    test('chips lost to the house become casino-owned, classified',
        () async {
      await _stockBank();
      final s = await _session('s1');
      final pidA = await _person('Ali');
      final a = await _seat(s, 'Ali', 1, personId: pidA);
      await _buyIn(s.id, a, 10000, chips: {'k1000': 10});

      // A takes 6,000 of his chips to roulette and loses them all: the
      // chips become CASINO-OWNED (holder -> bank, reason houseWin).
      final bankBefore = _bank();
      await ChipTrackingService.record(
        chipTypeId: 'k1000',
        quantity: 6,
        from: ChipLocation.player(pidA),
        to: ChipLocation.bank,
        reason: ChipMovementReason.houseWin,
        sessionId: s.id,
      );

      // The chips are the casino's now: player 0-side down, bank up.
      expect(_held(pidA), 4000);
      expect(_bank(), bankBefore + 6000);

      // The reconciliation reports house wins on their OWN figure —
      // never merged with rake.
      final rec = ChipTrackingService.reconcile(sessionId: s.id);
      expect(rec.houseWinToBank, 6000);
      expect(rec.rakeReturnedToBank, 0);

      // Session book: house win is money OUT, revenue is classified.
      await SessionService.recordTransaction(
        sessionId: s.id,
        playerId: a.id,
        type: TransactionType.houseWin,
        amount: 6000,
        hostSignatureBase64: 'sig',
      );
      // A settles the remaining 4,000 at the table.
      await RedemptionService.tableCashOut(
        sessionId: s.id,
        seatPlayerId: a.id,
        amount: 4000,
        hostSignatureBase64: 'sig',
      );

      final bal = SessionService.checkBalance(s.id);
      expect(bal.isBalanced, isTrue, reason: bal.possibleCauses.join(', '));
      expect(SessionService.totalHouseWin(s.id), 6000);
      expect(SessionService.totalRake(s.id), 0,
          reason: 'house revenue is NEVER merged into rake');
      expect(SessionService.hostProfit(s.id), 6000,
          reason: 'host profit = rake + house wins');
      // A lost the 6,000 to the house: it shows through the smaller
      // carried-out amount, and is not double-counted as a player out.
      expect(SessionService.playerProfitLoss(s.id, a.id), -6000);
    });

    test('poker rake and house wins stay separate in the settlement view',
        () async {
      final s = await _session('s1');
      final tables = TableService.tablesFor(s);
      await SessionService.recordTransaction(
        sessionId: s.id,
        type: TransactionType.rakeCollection,
        amount: 500,
        tableId: tables.first.id,
      );
      final pidA = await _person('Ali');
      final a = await _seat(s, 'Ali', 1, personId: pidA);
      await SessionService.recordTransaction(
        sessionId: s.id,
        type: TransactionType.buyIn,
        amount: 10000,
        playerId: a.id,
        hostSignatureBase64: 'sig',
      );
      await SessionService.recordTransaction(
        sessionId: s.id,
        playerId: a.id,
        type: TransactionType.houseWin,
        amount: 2000,
        hostSignatureBase64: 'sig',
      );
      await SessionService.recordTransaction(
        sessionId: s.id,
        playerId: a.id,
        type: TransactionType.tableCashOut,
        amount: 7500,
        hostSignatureBase64: 'sig',
      );

      expect(SessionService.totalRake(s.id), 500);
      expect(SessionService.totalHouseWin(s.id), 2000);
      expect(SessionService.hostProfit(s.id), 2500);
      expect(SessionService.checkBalance(s.id).isBalanced, isTrue);
      // A: 10,000 in, 7,500 carried out, 2,000 to the house, 500 rake.
      expect(SessionService.playerProfitLoss(s.id, a.id), -2500);
    });
  });

  group('E. Final redemption (spec §9 + 11.E)', () {
    test('chips move person -> bank ONLY at the cage redemption',
        () async {
      await _stockBank();
      final s = await _session('s1');
      final pidA = await _person('Ali');
      final a = await _seat(s, 'Ali', 1, personId: pidA);
      await _buyIn(s.id, a, 10000, chips: {'k1000': 10});

      // Leave the table: the chips stay with the person (no movement).
      await RedemptionService.tableCashOut(
        sessionId: s.id,
        seatPlayerId: a.id,
        amount: 6000,
        hostSignatureBase64: 'sig',
      );
      final movesAfterTableOut = _movements();
      expect(_held(pidA), 10000); // holding untouched by the table out

      // Cage redemption: NOW the chips return to the bank, and the
      // person's own cash returns as cash.
      final bankBefore = _bank();
      final result = await RedemptionService.redeem(
        personId: pidA,
        currency: AppCurrency.usd,
        amount: 6000,
        funding: ChipCashOutFunding.paidCash,
        composition: {'k1000': 6},
        sessionId: s.id,
        hostSignatureBase64: 'sig',
      );
      expect(result.cashPaid, 6000);
      expect(result.markerSettled, 0);
      expect(_held(pidA), 4000);
      expect(_bank(), bankBefore + 6000);
      // One movement (6 x k1000) — the ONLY person -> bank leg that
      // this person ever produced.
      expect(_movements(), movesAfterTableOut + 1);

      // The redemption is a PERSON-LEVEL (cage) operation: it wrote no
      // session money leg, and the cashier's cash-out is the financial
      // event.
      expect(
        SessionService.transactionsFor(s.id)
            .any((t) => t.type == TransactionType.cashOut),
        isFalse,
      );
      final fin = FinancialLedgerService.eventsFor(pidA);
      expect(
        fin.any((e) =>
            e.type == FinancialEventType.cashOutForChips &&
            e.amountMajor == 6000),
        isTrue,
      );
    });

    test('marker gate: blocked below the marker, netted at/above it',
        () async {
      await _stockBank();
      final s = await _session('s1');
      final pidB = await _person('Baba');
      final b = await _seat(s, 'Baba', 1, personId: pidB);
      await _buyIn(s.id, b, 10000, chips: {'k1000': 10});

      // A marker (credit) of 2,000 is outstanding.
      await FinancialLedgerService.record(
        personId: pidB,
        currency: AppCurrency.usd,
        type: FinancialEventType.creditIssued,
        amount: 2000,
        sessionId: s.id,
        signatureBase64: 'sig',
      );
      expect(FinancialLedgerService.creditOutstandingMinor(pidB, AppCurrency.usd),
          200000);

      // Redeem 1,000 < 2,000 marker: REFUSED.
      await expectLater(
        RedemptionService.redeem(
          personId: pidB,
          currency: AppCurrency.usd,
          amount: 1000,
          funding: ChipCashOutFunding.paidCash,
          composition: {'k1000': 1},
          sessionId: s.id,
          hostSignatureBase64: 'sig',
        ),
        throwsA(isA<RedemptionException>()),
      );

      // Redeem 3,000 >= 2,000: the marker is settled in the same
      // redemption (creditRepaid 2,000) and the net 1,000 is paid.
      final result = await RedemptionService.redeem(
        personId: pidB,
        currency: AppCurrency.usd,
        amount: 3000,
        funding: ChipCashOutFunding.paidCash,
        composition: {'k1000': 3},
        sessionId: s.id,
        hostSignatureBase64: 'sig',
      );
      expect(result.cashPaid, 1000);
      expect(result.markerSettled, 2000);
      expect(
          FinancialLedgerService.creditOutstandingMinor(pidB, AppCurrency.usd),
          0);
      expect(
        FinancialLedgerService.eventsFor(pidB)
            .any((e) =>
                e.type == FinancialEventType.creditRepaid &&
                e.amountMajor == 2000),
        isTrue,
      );
      expect(_held(pidB), 7000);
    });
  });

  group('F. Accounting invariants (spec §8/§11.F)', () {
    test('the original purchase is never counted twice, end to end',
        () async {
      await _stockBank();
      final s = await _session('s1', tables: 2);
      final pidA = await _person('Ali');
      final a = await _seat(s, 'Ali', 1, personId: pidA);
      final tables = TableService.tablesFor(s);
      await _buyIn(s.id, a, 10000, chips: {'k1000': 10});

      await ChipTrackingService.adjustPlayerHoldingToCount(
        playerId: pidA,
        counted: {'k1000': 6},
        sessionId: s.id,
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
      await RedemptionService.tableCashOut(
        sessionId: s.id,
        seatPlayerId: a.id,
        amount: 6000,
        hostSignatureBase64: 'sig',
      );

      // The 10,000 purchase appears EXACTLY ONCE in the books.
      expect(SessionService.totalBuyIn(s.id), 10000);
      expect(SessionService.playerTotalIn(s.id, a.id), 10000);
      // And the wallet never saw a second cash-in: a table cash-out +
      // re-entry writes no financial event at all.
      expect(FinancialLedgerService.eventsFor(pidA), isEmpty);
    });

    test('chip conservation across the whole lifecycle', () async {
      await _stockBank();
      final s = await _session('s1', tables: 2);
      final pidA = await _person('Ali');
      final pidB = await _person('Baba');
      final a = await _seat(s, 'Ali', 1, personId: pidA);
      final b = await _seat(s, 'Baba', 2, personId: pidB);
      final tables = TableService.tablesFor(s);

      final starting = ChipTrackingService.startingBankValue();
      expect(starting, 25000);

      await _buyIn(s.id, a, 10000, chips: {'k1000': 10});
      await _buyIn(s.id, b, 10000, chips: {'k1000': 8, 'k500': 4});
      // Bank has given out 20,000 of the 25,000.
      expect(_bank(), 5000);

      // Play + rake (the canonical example).
      await ChipTrackingService.adjustPlayerHoldingToCount(
        playerId: pidA,
        counted: {'k1000': 6},
        sessionId: s.id,
      );
      await ChipTrackingService.adjustPlayerHoldingToCount(
        playerId: pidB,
        counted: {'k1000': 12, 'k500': 4},
        sessionId: s.id,
      );
      await ChipTrackingService.record(
        chipTypeId: 'k500',
        quantity: 1,
        from: ChipLocation.player(pidB),
        to: ChipLocation.bank,
        reason: ChipMovementReason.rake,
        sessionId: s.id,
      );
      expect(_held(pidA), 6000);
      expect(_held(pidB), 13500);
      // Conservation holds at every step: 25,000 = 5,500 bank +
      // 6,000 A + 13,500 B.
      expect(_bank() + _held(pidA) + _held(pidB), starting);

      // Table cash-outs and re-entry move NO chips — conservation holds
      // through them by construction.
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
      expect(_bank() + _held(pidA) + _held(pidB), starting);

      // Cage redemptions: every chip returns to the case.
      await RedemptionService.redeem(
        personId: pidA,
        currency: AppCurrency.usd,
        amount: 6000,
        funding: ChipCashOutFunding.paidCash,
        composition: {'k1000': 6},
        sessionId: s.id,
        hostSignatureBase64: 'sig',
      );
      await RedemptionService.redeem(
        personId: pidB,
        currency: AppCurrency.usd,
        amount: 13500,
        funding: ChipCashOutFunding.paidCash,
        composition: {'k1000': 12, 'k500': 3},
        sessionId: s.id,
        hostSignatureBase64: 'sig',
      );
      expect(_held(pidA), 0);
      expect(_held(pidB), 0);
      expect(_bank(), starting);

      // The whole-session reconciliation is clean.
      final rec = ChipTrackingService.reconcile(sessionId: s.id);
      expect(rec.startingBankValue, 25000);
      expect(rec.currentBankValue, 25000);
      expect(rec.withPlayers, 0);
      expect(rec.onTables, 0);
      expect(rec.removed, 0);
    });

    test('first sit-down with cashier-issued chips: re-entry, no buy-in',
        () async {
      await _stockBank();
      final s = await _session('s1');
      final pidA = await _person('Ali');

      // Cashier: the person deposits 10,000 and is issued chips
      // (person-level wallet + chip issuance — NOT a session buy-in).
      await FinancialLedgerService.record(
        personId: pidA,
        currency: AppCurrency.usd,
        type: FinancialEventType.frontMoneyIn,
        amount: 10000,
        sessionId: s.id,
        signatureBase64: 'sig',
      );
      await ChipTrackingService.recordDistribution(
        distribution: {'k1000': 10},
        from: ChipLocation.bank,
        to: ChipLocation.player(pidA),
        reason: ChipMovementReason.depositIssuance,
        sessionId: s.id,
      );
      expect(_held(pidA), 10000);

      // Registered (not yet seated) for the session.
      final a = await _seat(s, 'Ali', 1, personId: pidA);
      a.seated = false;
      a.tableId = null;
      a.seatNumber = 0;
      await a.save();

      // The player sits with the SAME chips — no buy-in is created.
      final tables = TableService.tablesFor(s);
      await TableService.reenterWithHeldChips(
        s,
        a,
        tables.first.id,
        amount: 10000,
        hostSignatureBase64: 'sig',
      );

      expect(SessionService.totalBuyIn(s.id), 0,
          reason: 'no purchase was duplicated');
      expect(SessionService.totalReentry(s.id), 10000);
      expect(ParticipationService.forSession(s.id), hasLength(1));
      expect(ParticipationService.forSession(s.id).single.isOpen, isTrue);
      // The wallet holding is untouched by seating.
      expect(_held(pidA), 10000);
      expect(WalletService.walletFor(pidA).chipsInHand, 10000);

      // Break even: carry the 10,000 out and redeem them at the cage.
      await RedemptionService.tableCashOut(
        sessionId: s.id,
        seatPlayerId: a.id,
        amount: 10000,
        hostSignatureBase64: 'sig',
      );
      expect(SessionService.checkBalance(s.id).isBalanced, isTrue);
      expect(SessionService.playerProfitLoss(s.id, a.id), 0);
      await RedemptionService.redeem(
        personId: pidA,
        currency: AppCurrency.usd,
        amount: 10000,
        funding: ChipCashOutFunding.paidCash,
        composition: {'k1000': 10},
        sessionId: s.id,
        hostSignatureBase64: 'sig',
      );
      expect(_bank(), ChipTrackingService.startingBankValue());
    });
  });
}
