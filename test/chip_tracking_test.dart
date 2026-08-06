// Physical chip tracking and reconciliation.
//
// The central claim being tested is the accounting identity:
//   total owned = bank + tables + players + removed
// and that it survives everything a real game throws at it — including
// players winning chips from each other, which must NEVER read as a
// discrepancy.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:poker_ledger/models/chip_movement.dart';
import 'package:poker_ledger/models/chip_type.dart';
import 'package:poker_ledger/models/player.dart';
import 'package:poker_ledger/models/session.dart';
import 'package:poker_ledger/models/transaction.dart';
import 'package:poker_ledger/services/chip_bank_service.dart';
import 'package:poker_ledger/services/chip_tracking_service.dart';
import 'package:poker_ledger/services/hive_service.dart';
import 'package:poker_ledger/services/session_service.dart';
import 'test_helper.dart';

late Directory _tmp;

Future<void> _open() async {
  _tmp = await Directory.systemTemp.createTemp('pl_chiptrack_');
  Hive.init(_tmp.path);
  registerTestAdapters();
  await Hive.openBox<PokerSession>(HiveService.sessionsBox);
  await Hive.openBox<Player>(HiveService.playersBox);
  await Hive.openBox<LedgerTransaction>(HiveService.transactionsBox);
  await Hive.openBox(HiveService.settingsBox);
  await Hive.openBox<ChipType>(HiveService.chipsBox);
  await Hive.openBox<ChipMovement>(HiveService.chipMovementsBox);
}

Future<void> _close() async {
  await Hive.deleteFromDisk();
  if (await _tmp.exists()) await _tmp.delete(recursive: true);
}

void main() {
  setUp(_open);
  tearDown(_close);

  group('locations', () {
    test('encode and decode round-trip', () {
      expect(ChipLocation.decode(ChipLocation.bank.encoded),
          ChipLocation.bank);
      expect(ChipLocation.decode(ChipLocation.removed.encoded),
          ChipLocation.removed);
      expect(ChipLocation.decode(ChipLocation.table('t1').encoded),
          ChipLocation.table('t1'));
      expect(ChipLocation.decode(ChipLocation.player('p1').encoded),
          ChipLocation.player('p1'));
    });

    test('locations compare structurally so they can key a map', () {
      expect(ChipLocation.player('a') == ChipLocation.player('a'), isTrue);
      expect(ChipLocation.player('a') == ChipLocation.player('b'), isFalse);
      expect(ChipLocation.player('a') == ChipLocation.table('a'), isFalse);
      final set = {ChipLocation.player('a'), ChipLocation.player('a')};
      expect(set.length, 1);
    });

    test('an id containing a colon still decodes correctly', () {
      final loc = ChipLocation.player('weird:id:here');
      expect(ChipLocation.decode(loc.encoded).refId, 'weird:id:here');
    });
  });

  group('movement recording', () {
    test('a movement decreases the source and increases the target',
        () async {
      final chip = await ChipBankService.addChip(value: 100, quantity: 500);

      await ChipTrackingService.record(
        chipTypeId: chip.id,
        quantity: 10,
        from: ChipLocation.bank,
        to: ChipLocation.player('ali'),
        reason: ChipMovementReason.buyIn,
      );

      expect(
          ChipTrackingService.quantityAt(ChipLocation.bank, chip.id), 490);
      expect(
          ChipTrackingService.quantityAt(
              ChipLocation.player('ali'), chip.id),
          10);
    });

    test('a zero or negative quantity is refused', () async {
      final chip = await ChipBankService.addChip(value: 100, quantity: 10);
      expect(
        () => ChipTrackingService.record(
          chipTypeId: chip.id,
          quantity: 0,
          from: ChipLocation.bank,
          to: ChipLocation.player('a'),
          reason: ChipMovementReason.buyIn,
        ),
        throwsArgumentError,
      );
    });

    test('moving to the same place is refused', () async {
      final chip = await ChipBankService.addChip(value: 100, quantity: 10);
      expect(
        () => ChipTrackingService.record(
          chipTypeId: chip.id,
          quantity: 1,
          from: ChipLocation.bank,
          to: ChipLocation.bank,
          reason: ChipMovementReason.transfer,
        ),
        throwsArgumentError,
      );
    });

    test('the recorded value is frozen at the time of the movement',
        () async {
      final chip = await ChipBankService.addChip(value: 100, quantity: 50);
      final m = await ChipTrackingService.record(
        chipTypeId: chip.id,
        quantity: 5,
        from: ChipLocation.bank,
        to: ChipLocation.player('ali'),
        reason: ChipMovementReason.buyIn,
      );
      expect(m.chipValue, 100);
      expect(m.totalValue, 500);

      // Correcting the denomination later must not rewrite history.
      await ChipBankService.updateChip(chip.id, value: 250);
      final reread = HiveService.chipMovements.get(m.id)!;
      expect(reread.chipValue, 100);
      expect(reread.totalValue, 500);
    });

    test('a multi-denomination distribution shares one transaction id',
        () async {
      final c100 = await ChipBankService.addChip(value: 100, quantity: 500);
      final c500 = await ChipBankService.addChip(value: 500, quantity: 200);

      final made = await ChipTrackingService.recordDistribution(
        distribution: {c100.id: 5, c500.id: 1},
        from: ChipLocation.bank,
        to: ChipLocation.player('ali'),
        reason: ChipMovementReason.buyIn,
        transactionId: 'tx-1',
      );

      expect(made.length, 2);
      expect(made.every((m) => m.transactionId == 'tx-1'), isTrue);
      expect(
          ChipTrackingService.playerHolding('ali').totalValue, 1000);
    });

    test('zero-quantity entries are skipped in a distribution', () async {
      final c = await ChipBankService.addChip(value: 100, quantity: 50);
      final made = await ChipTrackingService.recordDistribution(
        distribution: {c.id: 0},
        from: ChipLocation.bank,
        to: ChipLocation.player('ali'),
        reason: ChipMovementReason.buyIn,
      );
      expect(made, isEmpty);
    });

    test('movements for a voided transaction can be reversed out',
        () async {
      final c = await ChipBankService.addChip(value: 100, quantity: 500);
      await ChipTrackingService.recordDistribution(
        distribution: {c.id: 10},
        from: ChipLocation.bank,
        to: ChipLocation.player('ali'),
        reason: ChipMovementReason.buyIn,
        transactionId: 'tx-9',
      );
      expect(ChipTrackingService.quantityAt(ChipLocation.bank, c.id), 490);

      final removed =
          await ChipTrackingService.deleteForTransaction('tx-9');
      expect(removed, 1);
      expect(ChipTrackingService.quantityAt(ChipLocation.bank, c.id), 500);
      expect(
          ChipTrackingService.playerHolding('ali').isEmpty, isTrue);
    });
  });

  group('the spec scenario reconciles', () {
    late ChipType c100;

    setUp(() async {
      // Banker owns 1000 x $100 chips.
      c100 = await ChipBankService.addChip(value: 100, quantity: 1000);

      await ChipTrackingService.record(
        chipTypeId: c100.id,
        quantity: 400,
        from: ChipLocation.bank,
        to: ChipLocation.table('t1'),
        reason: ChipMovementReason.tableFloat,
      );
      await ChipTrackingService.record(
        chipTypeId: c100.id,
        quantity: 150,
        from: ChipLocation.bank,
        to: ChipLocation.player('ali'),
        reason: ChipMovementReason.buyIn,
      );
      await ChipTrackingService.record(
        chipTypeId: c100.id,
        quantity: 130,
        from: ChipLocation.bank,
        to: ChipLocation.player('sara'),
        reason: ChipMovementReason.buyIn,
      );
      await ChipTrackingService.record(
        chipTypeId: c100.id,
        quantity: 20,
        from: ChipLocation.table('t1'),
        to: ChipLocation.removed,
        reason: ChipMovementReason.rake,
      );
    });

    test('bank + tables + players + removed equals the total owned', () {
      final report = ChipTrackingService.audit();
      final line = report.lines.single;

      expect(line.expectedInBank, 320);
      expect(line.onTables, 380);
      expect(line.withPlayers, 280);
      expect(line.removed, 20);
      expect(line.totalInventory, 1000);
      expect(line.accountedFor, 1000);
    });

    test('a matching physical count reconciles', () {
      final report =
          ChipTrackingService.audit(physicalCount: {c100.id: 320});
      expect(report.wasVerified, isTrue);
      expect(report.balances, isTrue);
      expect(report.chipDiscrepancy, 0);
      expect(report.valueDiscrepancy, 0);
    });

    test('a short physical count is reported with its value', () {
      final report =
          ChipTrackingService.audit(physicalCount: {c100.id: 315});
      expect(report.balances, isFalse);
      expect(report.chipDiscrepancy, 5);
      expect(report.valueDiscrepancy, 500);
      expect(report.problemLines.length, 1);
    });

    test('finding MORE chips than expected is reported as negative', () {
      final report =
          ChipTrackingService.audit(physicalCount: {c100.id: 325});
      expect(report.chipDiscrepancy, -5);
      expect(report.valueDiscrepancy, -500);
    });

    test('without a physical count nothing is claimed to be wrong', () {
      final report = ChipTrackingService.audit();
      expect(report.wasVerified, isFalse);
      expect(report.balances, isTrue);
      expect(report.chipDiscrepancy, 0);
    });
  });

  group('players holding chips is normal, not a discrepancy', () {
    test('a player-to-player transfer keeps the total unchanged', () async {
      final c = await ChipBankService.addChip(value: 100, quantity: 1000);
      await ChipTrackingService.record(
        chipTypeId: c.id,
        quantity: 150,
        from: ChipLocation.bank,
        to: ChipLocation.player('ali'),
        reason: ChipMovementReason.buyIn,
      );
      await ChipTrackingService.record(
        chipTypeId: c.id,
        quantity: 130,
        from: ChipLocation.bank,
        to: ChipLocation.player('sara'),
        reason: ChipMovementReason.buyIn,
      );

      final before = ChipTrackingService.audit().lines.single;

      // Ali loses 50 chips to Sara — completely normal poker.
      await ChipTrackingService.record(
        chipTypeId: c.id,
        quantity: 50,
        from: ChipLocation.player('ali'),
        to: ChipLocation.player('sara'),
        reason: ChipMovementReason.transfer,
      );

      final after = ChipTrackingService.audit().lines.single;
      expect(after.totalInventory, before.totalInventory);
      expect(after.withPlayers, before.withPlayers);
      expect(after.expectedInBank, before.expectedInBank);

      expect(ChipTrackingService.playerHolding('ali').totalChips, 100);
      expect(ChipTrackingService.playerHolding('sara').totalChips, 180);

      // And with a correct count it still reconciles perfectly.
      final verified =
          ChipTrackingService.audit(physicalCount: {c.id: 720});
      expect(verified.balances, isTrue);
    });

    test('removed chips are accounted for, never missing', () async {
      final c = await ChipBankService.addChip(value: 100, quantity: 100);
      await ChipTrackingService.record(
        chipTypeId: c.id,
        quantity: 8,
        from: ChipLocation.bank,
        to: ChipLocation.removed,
        reason: ChipMovementReason.rake,
      );
      await ChipTrackingService.record(
        chipTypeId: c.id,
        quantity: 2,
        from: ChipLocation.bank,
        to: ChipLocation.removed,
        reason: ChipMovementReason.adjustment,
        note: 'damaged',
      );

      final report = ChipTrackingService.audit(physicalCount: {c.id: 90});
      final line = report.lines.single;
      expect(line.removed, 10);
      expect(line.totalInventory, 100);
      expect(report.balances, isTrue);
    });
  });

  group('multi-table', () {
    test('each table tracks its own chips independently', () async {
      final c100 = await ChipBankService.addChip(value: 100, quantity: 500);
      final c500 = await ChipBankService.addChip(value: 500, quantity: 200);
      final c1000 =
          await ChipBankService.addChip(value: 1000, quantity: 100);

      await ChipTrackingService.recordDistribution(
        distribution: {c100.id: 200, c500.id: 50},
        from: ChipLocation.bank,
        to: ChipLocation.table('t1'),
        reason: ChipMovementReason.tableFloat,
      );
      await ChipTrackingService.recordDistribution(
        distribution: {c100.id: 100, c1000.id: 20},
        from: ChipLocation.bank,
        to: ChipLocation.table('t2'),
        reason: ChipMovementReason.tableFloat,
      );

      final t1 = ChipTrackingService.tableHolding('t1');
      final t2 = ChipTrackingService.tableHolding('t2');

      expect(t1.totalChips, 250);
      expect(t1.totalValue, 200 * 100 + 50 * 500); // 45,000
      expect(t2.totalChips, 120);
      expect(t2.totalValue, 100 * 100 + 20 * 1000); // 30,000

      final all = ChipTrackingService.allTableHoldings();
      expect(all.keys.toSet(), {'t1', 't2'});
      expect(ChipTrackingService.totalInPlayValue(), 75000);
    });

    test('chips can move directly between tables', () async {
      final c = await ChipBankService.addChip(value: 100, quantity: 500);
      await ChipTrackingService.record(
        chipTypeId: c.id,
        quantity: 100,
        from: ChipLocation.bank,
        to: ChipLocation.table('t1'),
        reason: ChipMovementReason.tableFloat,
      );
      await ChipTrackingService.record(
        chipTypeId: c.id,
        quantity: 40,
        from: ChipLocation.table('t1'),
        to: ChipLocation.table('t2'),
        reason: ChipMovementReason.transfer,
      );

      expect(ChipTrackingService.tableHolding('t1').totalChips, 60);
      expect(ChipTrackingService.tableHolding('t2').totalChips, 40);
      expect(ChipTrackingService.audit().lines.single.totalInventory, 500);
    });

    test('movements are scoped correctly by session', () async {
      final c = await ChipBankService.addChip(value: 100, quantity: 500);
      await ChipTrackingService.record(
        chipTypeId: c.id,
        quantity: 10,
        from: ChipLocation.bank,
        to: ChipLocation.player('ali'),
        reason: ChipMovementReason.buyIn,
        sessionId: 's1',
      );
      await ChipTrackingService.record(
        chipTypeId: c.id,
        quantity: 20,
        from: ChipLocation.bank,
        to: ChipLocation.player('ali'),
        reason: ChipMovementReason.buyIn,
        sessionId: 's2',
      );

      expect(
          ChipTrackingService.playerHolding('ali', sessionId: 's1')
              .totalChips,
          10);
      expect(
          ChipTrackingService.playerHolding('ali', sessionId: 's2')
              .totalChips,
          20);
      expect(ChipTrackingService.playerHolding('ali').totalChips, 30);
      expect(ChipTrackingService.allMovements(sessionId: 's1').length, 1);
    });
  });

  group('chips returned to the bank', () {
    test('a cash-out puts chips back and restores the bank', () async {
      final c = await ChipBankService.addChip(value: 100, quantity: 500);
      await ChipTrackingService.record(
        chipTypeId: c.id,
        quantity: 30,
        from: ChipLocation.bank,
        to: ChipLocation.player('ali'),
        reason: ChipMovementReason.buyIn,
      );
      expect(ChipTrackingService.quantityAt(ChipLocation.bank, c.id), 470);

      await ChipTrackingService.record(
        chipTypeId: c.id,
        quantity: 30,
        from: ChipLocation.player('ali'),
        to: ChipLocation.bank,
        reason: ChipMovementReason.cashOut,
      );
      expect(ChipTrackingService.quantityAt(ChipLocation.bank, c.id), 500);
      expect(ChipTrackingService.playerHolding('ali').isEmpty, isTrue);
    });
  });

  group('distribution helper', () {
    test('suggests largest denominations first', () async {
      await ChipBankService.addChip(value: 100, quantity: 500);
      await ChipBankService.addChip(value: 500, quantity: 200);
      await ChipBankService.addChip(value: 1000, quantity: 100);

      final s = ChipTrackingService.suggestDistribution(2700);
      expect(ChipTrackingService.valueOf(s), 2700);
    });

    test('never suggests more than the bank holds', () async {
      final c100 = await ChipBankService.addChip(value: 100, quantity: 3);
      final s = ChipTrackingService.suggestDistribution(1000);
      expect(s[c100.id] ?? 0, lessThanOrEqualTo(3));
      expect(ChipTrackingService.valueOf(s), lessThanOrEqualTo(1000));
    });

    test('bankCanCover rejects an impossible distribution', () async {
      final c = await ChipBankService.addChip(value: 100, quantity: 5);
      expect(ChipTrackingService.bankCanCover({c.id: 5}), isTrue);
      expect(ChipTrackingService.bankCanCover({c.id: 6}), isFalse);
    });

    test('an amount the chip set cannot make returns a partial set',
        () async {
      await ChipBankService.addChip(value: 100, quantity: 10);
      final s = ChipTrackingService.suggestDistribution(250);
      // 2 x 100 = 200; the remaining 50 cannot be made.
      expect(ChipTrackingService.valueOf(s), 200);
    });
  });

  group('the financial system is never touched', () {
    test('chip movements change no transaction, balance or settlement',
        () async {
      final session = PokerSession(
        id: 's1',
        name: 'Game',
        location: 'Home',
        dateTime: DateTime.now(),
        smallBlind: 1,
        bigBlind: 2,
        tableNumber: '1',
      );
      await HiveService.sessions.put(session.id, session);
      await HiveService.players.put(
        'ali',
        Player(id: 'ali', sessionId: 's1', name: 'Ali', seatNumber: 1),
      );
      await HiveService.transactions.put(
        't1',
        LedgerTransaction(
          id: 't1',
          sessionId: 's1',
          playerId: 'ali',
          type: TransactionType.buyIn,
          amount: 1000,
        ),
      );

      final balanceBefore = SessionService.checkBalance('s1');
      final inBefore = SessionService.playerTotalIn('s1', 'ali');
      final plBefore = SessionService.playerProfitLoss('s1', 'ali');
      final txCountBefore = HiveService.transactions.length;

      // A deliberately MISMATCHED distribution: 500 in chips against a
      // 1000 buy-in. The money must be entirely unaffected.
      final c = await ChipBankService.addChip(value: 100, quantity: 500);
      await ChipTrackingService.recordDistribution(
        distribution: {c.id: 5},
        from: ChipLocation.bank,
        to: ChipLocation.player('ali'),
        reason: ChipMovementReason.buyIn,
        sessionId: 's1',
        transactionId: 't1',
      );

      expect(SessionService.checkBalance('s1').moneyIn, balanceBefore.moneyIn);
      expect(
          SessionService.checkBalance('s1').moneyOut, balanceBefore.moneyOut);
      expect(SessionService.playerTotalIn('s1', 'ali'), inBefore);
      expect(SessionService.playerProfitLoss('s1', 'ali'), plBefore);
      expect(HiveService.transactions.length, txCountBefore);
      expect(HiveService.transactions.get('t1')!.amount, 1000);

      // The chip side did record, independently.
      expect(ChipTrackingService.playerHolding('ali').totalValue, 500);
    });

    test('rake chips removed do not alter the rake figure', () async {
      await HiveService.sessions.put(
        's1',
        PokerSession(
          id: 's1',
          name: 'G',
          location: 'H',
          dateTime: DateTime.now(),
          smallBlind: 1,
          bigBlind: 2,
          tableNumber: '1',
        ),
      );
      await HiveService.transactions.put(
        'r1',
        LedgerTransaction(
          id: 'r1',
          sessionId: 's1',
          type: TransactionType.rakeCollection,
          amount: 200,
        ),
      );
      final rakeBefore = SessionService.totalRake('s1');

      final c = await ChipBankService.addChip(value: 100, quantity: 100);
      await ChipTrackingService.record(
        chipTypeId: c.id,
        quantity: 50,
        from: ChipLocation.bank,
        to: ChipLocation.removed,
        reason: ChipMovementReason.rake,
        sessionId: 's1',
      );

      expect(SessionService.totalRake('s1'), rakeBefore);
      expect(SessionService.totalRake('s1'), 200);
      // Chips removed (5,000 worth) deliberately differ from the 200
      // rake — they are separate facts.
      expect(ChipTrackingService.removedHolding().totalValue, 5000);
    });

    test('the movement log lives in its own box', () async {
      final c = await ChipBankService.addChip(value: 100, quantity: 10);
      await ChipTrackingService.record(
        chipTypeId: c.id,
        quantity: 1,
        from: ChipLocation.bank,
        to: ChipLocation.player('p'),
        reason: ChipMovementReason.buyIn,
      );
      expect(HiveService.chipMovements.length, 1);
      expect(HiveService.transactions.length, 0);
      expect(HiveService.players.length, 0);
      expect(HiveService.sessions.length, 0);
    });
  });

  group('persistence', () {
    test('a movement survives a reload through its adapter', () async {
      final c = await ChipBankService.addChip(value: 250, quantity: 40);
      final m = await ChipTrackingService.record(
        chipTypeId: c.id,
        quantity: 7,
        from: ChipLocation.bank,
        to: ChipLocation.table('t9'),
        reason: ChipMovementReason.tableFloat,
        sessionId: 's5',
        transactionId: 'tx5',
        note: 'opening float',
      );

      await Hive.box<ChipMovement>(HiveService.chipMovementsBox).close();
      await Hive.openBox<ChipMovement>(HiveService.chipMovementsBox);

      final loaded = HiveService.chipMovements.get(m.id)!;
      expect(loaded.chipTypeId, c.id);
      expect(loaded.chipValue, 250);
      expect(loaded.quantity, 7);
      expect(loaded.from, ChipLocation.bank);
      expect(loaded.to, ChipLocation.table('t9'));
      expect(loaded.reasonEnum, ChipMovementReason.tableFloat);
      expect(loaded.sessionId, 's5');
      expect(loaded.transactionId, 'tx5');
      expect(loaded.note, 'opening float');
    });

    test('json round-trip preserves every field', () async {
      final c = await ChipBankService.addChip(value: 100, quantity: 10);
      final m = await ChipTrackingService.record(
        chipTypeId: c.id,
        quantity: 3,
        from: ChipLocation.bank,
        to: ChipLocation.player('x'),
        reason: ChipMovementReason.rebuy,
      );
      final copy = ChipMovement.fromJson(m.toJson());
      expect(copy.id, m.id);
      expect(copy.quantity, 3);
      expect(copy.from, ChipLocation.bank);
      expect(copy.to, ChipLocation.player('x'));
      expect(copy.reasonEnum, ChipMovementReason.rebuy);
    });

    test('an unknown reason degrades to transfer rather than throwing', () {
      expect(ChipMovementReason.parse('something_new'),
          ChipMovementReason.transfer);
      expect(ChipLocationKind.parse('nonsense'), ChipLocationKind.bank);
    });
  });
}
