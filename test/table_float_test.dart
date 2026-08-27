// Phase 2b — table float lifecycle + direction-correct composition.
//
// Float rules under test (Phase 0 / E4 — no new policy invented):
//   * seed / replenish: bank → table, bank cover required;
//   * return / close count-back: table → bank, the COUNTED fact wins
//     and the variance is noted, never auto-corrected;
//   * rake / tips debit the table and credit the bank;
//   * a negative float on a float-less table is "pot consumption" — a
//     reported state, not an error;
//   * conservation: float operations move chips between locations and
//     never create or destroy them.
//
// Direction-correct composition under test:
//   * suggestions and cover checks follow the movement's source
//     location — bank for outflows, the person's (person-scoped)
//     holding for returns — never the bank for a player's return.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:poker_ledger/models/chip_movement.dart';
import 'package:poker_ledger/models/chip_type.dart';
import 'package:poker_ledger/models/player.dart';
import 'package:poker_ledger/models/session.dart';
import 'package:poker_ledger/services/chip_bank_service.dart';
import 'package:poker_ledger/services/chip_tracking_service.dart';
import 'package:poker_ledger/services/hive_service.dart';

import 'test_helper.dart';

late Directory _tmp;

Future<void> _open() async {
  _tmp = await Directory.systemTemp.createTemp('pl_preset_fl_');
  Hive.init(_tmp.path);
  registerTestAdapters();
  await Hive.openBox<PokerSession>(HiveService.sessionsBox);
  await Hive.openBox<Player>(HiveService.playersBox);
  await Hive.openBox(HiveService.transactionsBox);
  await Hive.openBox(HiveService.settingsBox);
  await Hive.openBox<ChipType>(HiveService.chipsBox);
  await Hive.openBox<ChipMovement>(HiveService.chipMovementsBox);
}

Future<void> _close() async {
  await Hive.deleteFromDisk();
  if (await _tmp.exists()) await _tmp.delete(recursive: true);
}

Future<String> _chip(double value, int quantity) async {
  final c = await ChipBankService.addChip(value: value, quantity: quantity);
  return c.id;
}

/// Baseline chips owned (the inventory record).
int _totalOwned() {
  var t = 0;
  for (final c in ChipBankService.allChips()) {
    t += c.quantity;
  }
  return t;
}

/// Total chips across ALL derived locations (bank + tables + players +
/// removed). Conservation = this stays equal to [_totalOwned] no
/// matter how the chips are moved.
int _totalInAllLocations() {
  var t = 0;
  for (final c in ChipBankService.allChips()) {
    t += ChipTrackingService.quantityAt(ChipLocation.bank, c.id);
  }
  for (final h in ChipTrackingService.allTableHoldings().values) {
    t += h.totalChips;
  }
  for (final h in ChipTrackingService.allPlayerHoldings().values) {
    t += h.totalChips;
  }
  t += ChipTrackingService.removedHolding().totalChips;
  return t;
}

int _at(ChipLocation loc, String chipId) =>
    ChipTrackingService.quantityAt(loc, chipId);

void main() {
  setUp(_open);
  tearDown(_close);

  group('table float lifecycle', () {
    test('seed: bank → table, bank cover required, conservation holds',
        () async {
      final c100 = await _chip(100, 100);
      expect(_at(ChipLocation.bank, c100), 100);

      await ChipTrackingService.seedTableFloat('t1', {c100: 20});
      expect(_at(ChipLocation.bank, c100), 80);
      expect(_at(ChipLocation.table('t1'), c100), 20);
      expect(ChipTrackingService.tableFloatValue('t1'), 2000);

      // The bank cannot fund what it does not hold.
      await expectLater(
        () => ChipTrackingService.seedTableFloat('t1', {c100: 999}),
        throwsArgumentError,
      );

      // Conservation: the float moved chips, it did not create them.
      expect(_totalInAllLocations(), _totalOwned());
    });

    test('replenish and plain return: tray → bank, tray zeroed', () async {
      final c100 = await _chip(100, 100);
      await ChipTrackingService.seedTableFloat('t1', {c100: 20});
      await ChipTrackingService.replenishTableFloat('t1', {c100: 5});
      expect(_at(ChipLocation.table('t1'), c100), 25);
      expect(_at(ChipLocation.bank, c100), 75);

      await ChipTrackingService.returnTableFloat('t1');
      expect(_at(ChipLocation.table('t1'), c100), 0);
      expect(_at(ChipLocation.bank, c100), 100);
    });

    test('rake and tips debit the table, credit the bank', () async {
      final c100 = await _chip(100, 100);
      await ChipTrackingService.seedTableFloat('t1', {c100: 20});

      await ChipTrackingService.recordDistribution(
        distribution: {c100: 5},
        from: ChipLocation.table('t1'),
        to: ChipLocation.bank,
        reason: ChipMovementReason.rake,
      );
      expect(_at(ChipLocation.table('t1'), c100), 15);
      expect(_at(ChipLocation.bank, c100), 85);

      await ChipTrackingService.recordDistribution(
        distribution: {c100: 2},
        from: ChipLocation.table('t1'),
        to: ChipLocation.bank,
        reason: ChipMovementReason.dealerTips,
      );
      expect(_at(ChipLocation.table('t1'), c100), 13);
      expect(_at(ChipLocation.bank, c100), 87);
      expect(ChipTrackingService.tableFloatValue('t1'), 1300);
    });

    test('negative float (pot consumption) is a reported state, not an error',
        () async {
      final c100 = await _chip(100, 100);
      // Float-less (home) table: rake taken with no float seeded.
      await ChipTrackingService.recordDistribution(
        distribution: {c100: 3},
        from: ChipLocation.table('t1'),
        to: ChipLocation.bank,
        reason: ChipMovementReason.rake,
      );

      // The table position goes negative — "pot consumption". No
      // exception, and the reconciliation still accounts for every
      // chip (the 3 are in the bank).
      expect(ChipTrackingService.tableFloatValue('t1'), -300);
      expect(_at(ChipLocation.bank, c100), 103);
      final rec = ChipTrackingService.reconcile();
      expect(rec.totalAccountedFor, 100 * 100);
    });

    test('close count-back: the counted fact wins, variance is noted, '
        'never auto-corrected', () async {
      final c100 = await _chip(100, 100);
      await ChipTrackingService.seedTableFloat('t1', {c100: 20});

      // The tray was counted at 18 — two chips unaccounted (variance).
      final made = await ChipTrackingService.returnTableFloat(
        't1',
        counted: {c100: 18},
      );
      expect(made, isNotEmpty);
      expect(_at(ChipLocation.bank, c100), 98);
      // The variance (2) stays in the tray's derived position for the
      // report — NOT silently corrected.
      expect(_at(ChipLocation.table('t1'), c100), 2);
      expect(made.first.note, contains('variance'));

      // Count MORE than the derived tray (ledger says 2, the physical
      // count says 5): the physical fact wins, the tray goes negative
      // (unrecorded inflow) — reported, never corrected.
      await ChipTrackingService.returnTableFloat('t1', counted: {c100: 5});
      expect(_at(ChipLocation.bank, c100), 103);
      expect(_at(ChipLocation.table('t1'), c100), -3);
      // And every chip is still accounted for.
      expect(_totalInAllLocations(), _totalOwned());
    });
  });

  group('direction-correct composition', () {
    test('suggestFrom follows the source location', () async {
      final c100 = await _chip(100, 100);
      final c500 = await _chip(500, 10);
      // The holder has 2 x $500 (the bank keeps the rest).
      await ChipTrackingService.recordDistribution(
        distribution: {c500: 2},
        from: ChipLocation.bank,
        to: ChipLocation.player('person-1'),
        reason: ChipMovementReason.buyIn,
      );

      // A RETURN from this holder suggests from the HOLDER's holding.
      expect(ChipTrackingService.suggestFrom(ChipLocation.player('person-1'), 1000),
          {c500: 2});
      // An OUTFLOW from the bank suggests from the bank.
      expect(
        ChipTrackingService.suggestFrom(ChipLocation.bank, 1000).isNotEmpty,
        isTrue,
      );
      // The historical API is bank-anchored and unchanged.
      expect(
        ChipTrackingService.suggestDistribution(1000),
        ChipTrackingService.suggestFrom(null, 1000),
      );
    });

    test('a player return is validated against the holding, never the bank',
        () async {
      final c100 = await _chip(100, 100);
      final c500 = await _chip(500, 10);
      await ChipTrackingService.recordDistribution(
        distribution: {c500: 2},
        from: ChipLocation.bank,
        to: ChipLocation.player('person-1'),
        reason: ChipMovementReason.buyIn,
      );

      final holder = ChipLocation.player('person-1');
      // The holder holds 2 x $500 → covered.
      expect(ChipTrackingService.locationCanCover(holder, {c500: 2}), isTrue);
      // Three would exceed the holding → refused.
      expect(ChipTrackingService.locationCanCover(holder, {c500: 3}), isFalse);
      // The BANK holds 98 x $100, but the holder holds none. A return
      // of $100 chips must be refused — never validated against bank
      // inventory.
      expect(ChipTrackingService.locationCanCover(holder, {c100: 1}), isFalse);
      expect(_at(ChipLocation.bank, c100), 100);
    });

    test('person-scoped holding drives the source (seat → person)',
        () async {
      final c100 = await _chip(100, 50);
      final seat = Player(
        id: 'seat-1',
        sessionId: 's1',
        name: 'Ali',
        seatNumber: 1,
        personId: 'person-ali',
      );
      await HiveService.players.put(seat.id, seat);

      await ChipTrackingService.recordDistribution(
        distribution: {c100: 7},
        from: ChipLocation.bank,
        to: ChipLocation.player('person-ali'),
        reason: ChipMovementReason.buyIn,
      );

      // The holder reference for this seat is the PERSON.
      final ref = ChipTrackingService.holderRef(
          playerId: seat.id, personId: seat.personId);
      expect(ref, 'person-ali');
      expect(
        ChipTrackingService.quantityAt(ChipLocation.player(ref), c100),
        7,
      );
      // A legacy unlinked seat keeps its own ref.
      final unlinked = ChipTrackingService.holderRef(
          playerId: 'seat-2', personId: null);
      expect(unlinked, 'seat-2');
    });
  });

  group('conservation invariants', () {
    test('seed → rake → count-back leaves total owned unchanged', () async {
      final c100 = await _chip(100, 100);
      expect(_totalOwned(), 100);

      await ChipTrackingService.seedTableFloat('t1', {c100: 30});
      await ChipTrackingService.recordDistribution(
        distribution: {c100: 8},
        from: ChipLocation.table('t1'),
        to: ChipLocation.bank,
        reason: ChipMovementReason.rake,
      );
      await ChipTrackingService.returnTableFloat('t1', counted: {c100: 20});

      // 30 seeded - 8 raked = 22 in the tray; 20 counted back, 2
      // variance stays in the tray. Everything is still owned.
      expect(_totalOwned(), 100);
      expect(_at(ChipLocation.table('t1'), c100), 2);
      expect(_at(ChipLocation.bank, c100), 100 - 30 + 8 + 20);
    });
  });
}
