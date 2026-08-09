// Issue #9 UI phases — the decision logic behind the four new surfaces.
//
// WHAT THIS FILE DOES AND DOES NOT COVER
// These are unit tests of the rules the new sheets enforce, exercised
// against the real services with real Hive boxes. They do NOT pump
// widgets: the value of the Edit / Exchange / Transfer / Reconciliation
// screens is entirely in the gates they apply and the movements they
// produce, and that is what is asserted here.
//
// The gate predicates mirror the `_canConfirm` getters in
// chip_exchange_sheet.dart and chip_transfer_sheet.dart. Where a sheet
// refuses an action, the corresponding service call is also asserted to
// throw, so the rule holds even if a future UI change lets one slip past.
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

import 'test_helper.dart';

late Directory _tmp;

Future<void> _open() async {
  _tmp = await Directory.systemTemp.createTemp('pl_chipui_');
  Hive.init(_tmp.path);
  registerTestAdapters();
  await Hive.openBox<PokerSession>(HiveService.sessionsBox);
  await Hive.openBox<Player>(HiveService.playersBox);
  await Hive.openBox<LedgerTransaction>(HiveService.transactionsBox);
  await Hive.openBox(HiveService.settingsBox);
  await Hive.openBox<ChipType>(HiveService.chipsBox);
  await Hive.openBox<ChipMovement>(HiveService.chipMovementsBox);
  ChipTrackingService.installBankResolver();
}

Future<void> _close() async {
  ChipBankService.liveQuantityResolver = null;
  await Hive.deleteFromDisk();
  if (await _tmp.exists()) await _tmp.delete(recursive: true);
}

/// $25 x 400 + $100 x 100 = exactly $20,000.
Future<Map<String, ChipType>> _stock() async {
  final c25 = await ChipBankService.addChip(value: 25, quantity: 400);
  final c100 = await ChipBankService.addChip(value: 100, quantity: 100);
  return {'25': c25, '100': c100};
}

int _atBank(String id) =>
    ChipTrackingService.quantityAt(ChipLocation.bank, id);
int _atPlayer(String p, String id) =>
    ChipTrackingService.quantityAt(ChipLocation.player(p), id);

// ---------------------------------------------------------------------
// Gate predicates, mirroring the sheets' `_canConfirm`.
// ---------------------------------------------------------------------

bool exchangeAllowed({
  required String playerId,
  required Map<String, int> given,
  required Map<String, int> received,
}) {
  final gv = ChipTrackingService.valueOf(given);
  final rv = ChipTrackingService.valueOf(received);
  if (gv <= 0) return false;
  if ((gv - rv).abs() >= 0.005) return false;
  for (final e in given.entries) {
    if (e.value > _atPlayer(playerId, e.key)) return false;
  }
  for (final e in received.entries) {
    if (e.value > _atBank(e.key)) return false;
  }
  return true;
}

bool transferAllowed({
  required String from,
  required String to,
  required Map<String, int> distribution,
}) {
  if (from == to) return false;
  if (distribution.values.fold(0, (a, b) => a + b) <= 0) return false;
  for (final e in distribution.entries) {
    if (e.value > _atPlayer(from, e.key)) return false;
  }
  return true;
}

void main() {
  setUp(_open);
  tearDown(_close);

  // -------------------------------------------------------------------
  group('Edit chip composition', () {
    test('replaces the breakdown and leaves the end state identical to a '
        'correct original entry', () async {
      final c = await _stock();
      // Banker records 10 x $100, but actually handed over 40 x $25.
      await ChipTrackingService.recordDistribution(
        distribution: {c['100']!.id: 10},
        from: ChipLocation.bank,
        to: ChipLocation.player('p1'),
        reason: ChipMovementReason.buyIn,
        transactionId: 'tx1',
      );
      expect(_atPlayer('p1', c['100']!.id), 10);

      await ChipTrackingService.editDistribution(
        transactionId: 'tx1',
        distribution: {c['25']!.id: 40},
        from: ChipLocation.bank,
        to: ChipLocation.player('p1'),
        reason: ChipMovementReason.buyIn,
      );

      // The $100s went back; the $25s came out. Same value either way.
      expect(_atPlayer('p1', c['100']!.id), 0);
      expect(_atPlayer('p1', c['25']!.id), 40);
      expect(ChipTrackingService.playerHolding('p1').totalValue, 1000);
      expect(_atBank(c['100']!.id), 100);
      expect(_atBank(c['25']!.id), 360);
    });

    test('never destroys history — original, reversal and correction all '
        'remain on file', () async {
      final c = await _stock();
      await ChipTrackingService.recordDistribution(
        distribution: {c['100']!.id: 10},
        from: ChipLocation.bank,
        to: ChipLocation.player('p1'),
        reason: ChipMovementReason.buyIn,
        transactionId: 'tx1',
      );
      await ChipTrackingService.editDistribution(
        transactionId: 'tx1',
        distribution: {c['25']!.id: 40},
        from: ChipLocation.bank,
        to: ChipLocation.player('p1'),
        reason: ChipMovementReason.buyIn,
      );

      final all = ChipTrackingService.allMovements()
          .where((m) => m.transactionId == 'tx1')
          .toList();
      expect(all.length, 3, reason: 'original + reversal + correction');
      expect(
        all.where((m) => m.reasonEnum == ChipMovementReason.reversal).length,
        1,
      );
      // Only the corrected leg is still in force.
      final active =
          ChipTrackingService.activeMovementsForTransaction('tx1');
      expect(active.length, 1);
      expect(active.single.chipTypeId, c['25']!.id);
    });

    test('the editor reads back exactly what is in force, not the '
        'superseded original', () async {
      final c = await _stock();
      await ChipTrackingService.recordDistribution(
        distribution: {c['100']!.id: 10},
        from: ChipLocation.bank,
        to: ChipLocation.player('p1'),
        reason: ChipMovementReason.buyIn,
        transactionId: 'tx1',
      );
      await ChipTrackingService.editDistribution(
        transactionId: 'tx1',
        distribution: {c['25']!.id: 40},
        from: ChipLocation.bank,
        to: ChipLocation.player('p1'),
        reason: ChipMovementReason.buyIn,
      );

      // This is the map _ChipCompositionEditorState.initState builds.
      final shown = <String, int>{};
      for (final m
          in ChipTrackingService.activeMovementsForTransaction('tx1')) {
        shown[m.chipTypeId] = (shown[m.chipTypeId] ?? 0) + m.quantity;
      }
      expect(shown, {c['25']!.id: 40});
    });

    test('editing a cash-out moves chips the other way and keeps the '
        'physical total constant', () async {
      final c = await _stock();
      await ChipTrackingService.recordDistribution(
        distribution: {c['25']!.id: 40},
        from: ChipLocation.bank,
        to: ChipLocation.player('p1'),
        reason: ChipMovementReason.buyIn,
        transactionId: 'buy',
      );
      await ChipTrackingService.recordDistribution(
        distribution: {c['25']!.id: 20},
        from: ChipLocation.player('p1'),
        to: ChipLocation.bank,
        reason: ChipMovementReason.cashOut,
        transactionId: 'out',
      );
      final before = ChipTrackingService.reconcile().totalAccountedFor;

      await ChipTrackingService.editDistribution(
        transactionId: 'out',
        distribution: {c['25']!.id: 30},
        from: ChipLocation.player('p1'),
        to: ChipLocation.bank,
        reason: ChipMovementReason.cashOut,
      );

      expect(_atPlayer('p1', c['25']!.id), 10);
      expect(ChipTrackingService.reconcile().totalAccountedFor, before);
      expect(before, 20000);
    });
  });

  // -------------------------------------------------------------------
  group('Exchange', () {
    test('equal-value swap is allowed and changes nobody\'s total', () async {
      final c = await _stock();
      await ChipTrackingService.recordDistribution(
        distribution: {c['100']!.id: 10},
        from: ChipLocation.bank,
        to: ChipLocation.player('p1'),
        reason: ChipMovementReason.buyIn,
      );
      final bankBefore = ChipTrackingService.currentBankValue();

      expect(
        exchangeAllowed(
          playerId: 'p1',
          given: {c['100']!.id: 4},
          received: {c['25']!.id: 16},
        ),
        isTrue,
      );

      await ChipTrackingService.recordExchange(
        counterparty: ChipLocation.player('p1'),
        chipsIn: {c['100']!.id: 4},
        chipsOut: {c['25']!.id: 16},
      );

      expect(ChipTrackingService.playerHolding('p1').totalValue, 1000);
      expect(ChipTrackingService.currentBankValue(), bankBefore);
      expect(_atPlayer('p1', c['100']!.id), 6);
      expect(_atPlayer('p1', c['25']!.id), 16);
    });

    test('both legs share one exchange identifier', () async {
      final c = await _stock();
      await ChipTrackingService.recordDistribution(
        distribution: {c['100']!.id: 10},
        from: ChipLocation.bank,
        to: ChipLocation.player('p1'),
        reason: ChipMovementReason.buyIn,
      );
      final made = await ChipTrackingService.recordExchange(
        counterparty: ChipLocation.player('p1'),
        chipsIn: {c['100']!.id: 4},
        chipsOut: {c['25']!.id: 16},
      );
      expect(made.length, 2);
      expect(made.first.note, startsWith('exchange:'));
      expect(made.first.note, made.last.note);
      expect(
        made.every((m) => m.reasonEnum == ChipMovementReason.exchange),
        isTrue,
      );
    });

    test('unequal value is refused by the gate AND throws in the service',
        () async {
      final c = await _stock();
      await ChipTrackingService.recordDistribution(
        distribution: {c['100']!.id: 10},
        from: ChipLocation.bank,
        to: ChipLocation.player('p1'),
        reason: ChipMovementReason.buyIn,
      );

      expect(
        exchangeAllowed(
          playerId: 'p1',
          given: {c['100']!.id: 1},
          received: {c['25']!.id: 3}, // $100 vs $75
        ),
        isFalse,
      );
      await expectLater(
        ChipTrackingService.recordExchange(
          counterparty: ChipLocation.player('p1'),
          chipsIn: {c['100']!.id: 1},
          chipsOut: {c['25']!.id: 3},
        ),
        throwsArgumentError,
      );
    });

    test('a player cannot hand over chips they do not hold', () async {
      final c = await _stock();
      await ChipTrackingService.recordDistribution(
        distribution: {c['100']!.id: 2},
        from: ChipLocation.bank,
        to: ChipLocation.player('p1'),
        reason: ChipMovementReason.buyIn,
      );
      expect(
        exchangeAllowed(
          playerId: 'p1',
          given: {c['100']!.id: 5},
          received: {c['25']!.id: 20},
        ),
        isFalse,
      );
    });

    test('the bank cannot hand back chips it does not hold', () async {
      final c = await _stock();
      await ChipTrackingService.recordDistribution(
        distribution: {c['25']!.id: 400},
        from: ChipLocation.bank,
        to: ChipLocation.player('p1'),
        reason: ChipMovementReason.buyIn,
      );
      expect(_atBank(c['25']!.id), 0);
      expect(
        exchangeAllowed(
          playerId: 'p1',
          given: {c['100']!.id: 0},
          received: {c['25']!.id: 1},
        ),
        isFalse,
      );
    });

    test('an empty exchange is refused', () async {
      await _stock();
      expect(
        exchangeAllowed(playerId: 'p1', given: {}, received: {}),
        isFalse,
      );
    });

    test('creates no money transaction', () async {
      final c = await _stock();
      await ChipTrackingService.recordDistribution(
        distribution: {c['100']!.id: 10},
        from: ChipLocation.bank,
        to: ChipLocation.player('p1'),
        reason: ChipMovementReason.buyIn,
      );
      final txCount = HiveService.transactions.length;
      await ChipTrackingService.recordExchange(
        counterparty: ChipLocation.player('p1'),
        chipsIn: {c['100']!.id: 4},
        chipsOut: {c['25']!.id: 16},
      );
      expect(HiveService.transactions.length, txCount);
    });
  });

  // -------------------------------------------------------------------
  group('Player-to-player transfer', () {
    test('moves chips between players without touching the Bank', () async {
      final c = await _stock();
      await ChipTrackingService.recordDistribution(
        distribution: {c['100']!.id: 10},
        from: ChipLocation.bank,
        to: ChipLocation.player('a'),
        reason: ChipMovementReason.buyIn,
      );
      final bankBefore = ChipTrackingService.currentBankValue();

      expect(
        transferAllowed(
            from: 'a', to: 'b', distribution: {c['100']!.id: 3}),
        isTrue,
      );
      await ChipTrackingService.recordPlayerTransfer(
        fromPlayerId: 'a',
        toPlayerId: 'b',
        distribution: {c['100']!.id: 3},
      );

      expect(ChipTrackingService.currentBankValue(), bankBefore);
      expect(ChipTrackingService.playerHolding('a').totalValue, 700);
      expect(ChipTrackingService.playerHolding('b').totalValue, 300);
      // Combined holding is conserved.
      expect(
        ChipTrackingService.playerHolding('a').totalValue +
            ChipTrackingService.playerHolding('b').totalValue,
        1000,
      );
    });

    test('refuses a transfer to the same player, in gate and service',
        () async {
      final c = await _stock();
      await ChipTrackingService.recordDistribution(
        distribution: {c['100']!.id: 5},
        from: ChipLocation.bank,
        to: ChipLocation.player('a'),
        reason: ChipMovementReason.buyIn,
      );
      expect(
        transferAllowed(
            from: 'a', to: 'a', distribution: {c['100']!.id: 1}),
        isFalse,
      );
      await expectLater(
        ChipTrackingService.recordPlayerTransfer(
          fromPlayerId: 'a',
          toPlayerId: 'a',
          distribution: {c['100']!.id: 1},
        ),
        throwsArgumentError,
      );
    });

    test('refuses to move more than the source holds', () async {
      final c = await _stock();
      await ChipTrackingService.recordDistribution(
        distribution: {c['100']!.id: 2},
        from: ChipLocation.bank,
        to: ChipLocation.player('a'),
        reason: ChipMovementReason.buyIn,
      );
      expect(
        transferAllowed(
            from: 'a', to: 'b', distribution: {c['100']!.id: 3}),
        isFalse,
      );
    });

    test('refuses an empty selection', () async {
      await _stock();
      expect(
        transferAllowed(from: 'a', to: 'b', distribution: {}),
        isFalse,
      );
    });

    test('creates no money transaction and leaves the physical total '
        'unchanged', () async {
      final c = await _stock();
      await ChipTrackingService.recordDistribution(
        distribution: {c['100']!.id: 10},
        from: ChipLocation.bank,
        to: ChipLocation.player('a'),
        reason: ChipMovementReason.buyIn,
      );
      final txCount = HiveService.transactions.length;
      final total = ChipTrackingService.reconcile().totalAccountedFor;

      await ChipTrackingService.recordPlayerTransfer(
        fromPlayerId: 'a',
        toPlayerId: 'b',
        distribution: {c['100']!.id: 3},
      );

      expect(HiveService.transactions.length, txCount);
      expect(ChipTrackingService.reconcile().totalAccountedFor, total);
      expect(total, 20000);
    });
  });

  // -------------------------------------------------------------------
  group('Low inventory thresholds', () {
    test('remaining fraction tracks the bank as chips leave', () async {
      final c = await _stock();
      expect(ChipTrackingService.bankRemainingFraction(), 1.0);

      // Issue exactly half the value: $10,000.
      await ChipTrackingService.recordDistribution(
        distribution: {c['100']!.id: 100},
        from: ChipLocation.bank,
        to: ChipLocation.player('p1'),
        reason: ChipMovementReason.buyIn,
      );
      expect(ChipTrackingService.bankRemainingFraction(), closeTo(0.5, 1e-9));

      // Down to $6,000 => 30%.
      await ChipTrackingService.recordDistribution(
        distribution: {c['25']!.id: 160},
        from: ChipLocation.bank,
        to: ChipLocation.player('p1'),
        reason: ChipMovementReason.buyIn,
      );
      expect(ChipTrackingService.bankRemainingFraction(), closeTo(0.3, 1e-9));
    });

    test('recovers when chips come back, so a later crossing can re-arm',
        () async {
      final c = await _stock();
      await ChipTrackingService.recordDistribution(
        distribution: {c['100']!.id: 100},
        from: ChipLocation.bank,
        to: ChipLocation.player('p1'),
        reason: ChipMovementReason.buyIn,
      );
      expect(ChipTrackingService.bankRemainingFraction(), closeTo(0.5, 1e-9));

      await ChipTrackingService.recordDistribution(
        distribution: {c['100']!.id: 100},
        from: ChipLocation.player('p1'),
        to: ChipLocation.bank,
        reason: ChipMovementReason.cashOut,
      );
      expect(ChipTrackingService.bankRemainingFraction(), closeTo(1.0, 1e-9));
    });

    test('is null when no inventory is configured, so "nothing set up" is '
        'distinguishable from "everything gone"', () async {
      expect(ChipTrackingService.bankRemainingFraction(), isNull);
    });
  });

  // -------------------------------------------------------------------
  group('Session reconciliation', () {
    /// The scenario from the spec, built out of real movements.
    Future<Map<String, ChipType>> runAcceptance() async {
      final c = await _stock();
      final k25 = c['25']!.id;
      final k100 = c['100']!.id;

      // $10,000 out in buy-ins and rebuys across three players.
      await ChipTrackingService.recordDistribution(
        distribution: {k100: 40},
        from: ChipLocation.bank,
        to: ChipLocation.player('p1'),
        reason: ChipMovementReason.buyIn,
      );
      await ChipTrackingService.recordDistribution(
        distribution: {k25: 80, k100: 20},
        from: ChipLocation.bank,
        to: ChipLocation.player('p2'),
        reason: ChipMovementReason.buyIn,
      );
      await ChipTrackingService.recordDistribution(
        distribution: {k25: 80},
        from: ChipLocation.bank,
        to: ChipLocation.player('p3'),
        reason: ChipMovementReason.rebuy,
      );

      // $8,500 back in cash-outs.
      await ChipTrackingService.recordDistribution(
        distribution: {k100: 40},
        from: ChipLocation.player('p1'),
        to: ChipLocation.bank,
        reason: ChipMovementReason.cashOut,
      );
      await ChipTrackingService.recordDistribution(
        distribution: {k25: 60, k100: 20},
        from: ChipLocation.player('p2'),
        to: ChipLocation.bank,
        reason: ChipMovementReason.cashOut,
      );
      await ChipTrackingService.recordDistribution(
        distribution: {k25: 40},
        from: ChipLocation.player('p3'),
        to: ChipLocation.bank,
        reason: ChipMovementReason.cashOut,
      );

      // $500 rake — physically INTO the bank, never `removed`.
      await ChipTrackingService.recordDistribution(
        distribution: {k25: 20},
        from: ChipLocation.player('p3'),
        to: ChipLocation.bank,
        reason: ChipMovementReason.rake,
      );
      return c;
    }

    test('the acceptance scenario reports the agreed figures', () async {
      await runAcceptance();
      final r = ChipTrackingService.reconcile();

      expect(r.startingBankValue, 20000);
      expect(r.currentBankValue, 19000);
      expect(r.withPlayers, 1000);
      expect(r.onTables, 0);
      expect(r.removed, 0, reason: 'rake goes to the Bank, not removed');
      expect(r.rakeReturnedToBank, 500);
      expect(r.totalAccountedFor, 20000);
    });

    test('with no physical count it reports unverified and claims no '
        'discrepancy', () async {
      await runAcceptance();
      final r = ChipTrackingService.reconcile();
      expect(r.wasVerified, isFalse);
      expect(r.discrepancy, 0);
      expect(r.balances, isTrue);
    });

    test('an exact physical count balances', () async {
      final c = await runAcceptance();
      final count = {
        c['25']!.id: _atBank(c['25']!.id),
        c['100']!.id: _atBank(c['100']!.id),
      };
      final r = ChipTrackingService.reconcile(physicalCount: count);
      expect(r.wasVerified, isTrue);
      expect(r.discrepancy, 0);
      expect(r.balances, isTrue);
    });

    test('a real shortfall is reported, never absorbed', () async {
      final c = await runAcceptance();
      final count = {
        c['25']!.id: _atBank(c['25']!.id),
        c['100']!.id: _atBank(c['100']!.id) - 2, // $200 missing
      };
      final r = ChipTrackingService.reconcile(physicalCount: count);
      expect(r.wasVerified, isTrue);
      expect(r.discrepancy, 200);
      expect(r.balances, isFalse);
      // And the derived figures are untouched by the bad count.
      expect(r.currentBankValue, 19000);
    });

    test('a surplus is reported with the opposite sign', () async {
      final c = await runAcceptance();
      final count = {
        c['25']!.id: _atBank(c['25']!.id) + 4, // $100 too many
        c['100']!.id: _atBank(c['100']!.id),
      };
      final r = ChipTrackingService.reconcile(physicalCount: count);
      expect(r.discrepancy, -100);
      expect(r.balances, isFalse);
    });

    test('a partial count only judges the denominations actually counted',
        () async {
      final c = await runAcceptance();
      // Only the $100s were counted, and they are correct.
      final r = ChipTrackingService.reconcile(
        physicalCount: {c['100']!.id: _atBank(c['100']!.id)},
      );
      expect(r.wasVerified, isTrue);
      expect(r.discrepancy, 0);
    });

    test('reconciling never writes a movement', () async {
      await runAcceptance();
      final before = ChipTrackingService.allMovements().length;
      for (var i = 0; i < 5; i++) {
        ChipTrackingService.reconcile();
        ChipTrackingService.reconcile(physicalCount: {});
      }
      expect(ChipTrackingService.allMovements().length, before);
      expect(ChipTrackingService.reconcile().totalAccountedFor, 20000);
    });

    test('the identity holds after an edit, a void and an exchange',
        () async {
      final c = await runAcceptance();

      await ChipTrackingService.recordDistribution(
        distribution: {c['100']!.id: 5},
        from: ChipLocation.bank,
        to: ChipLocation.player('p4'),
        reason: ChipMovementReason.buyIn,
        transactionId: 'late',
      );
      await ChipTrackingService.editDistribution(
        transactionId: 'late',
        distribution: {c['25']!.id: 20},
        from: ChipLocation.bank,
        to: ChipLocation.player('p4'),
        reason: ChipMovementReason.buyIn,
      );
      await ChipTrackingService.recordExchange(
        counterparty: ChipLocation.player('p4'),
        chipsIn: {c['25']!.id: 4},
        chipsOut: {c['100']!.id: 1},
      );
      await ChipTrackingService.reverseForTransaction('late', note: 'void');

      final r = ChipTrackingService.reconcile();
      expect(r.totalAccountedFor, 20000);
      expect(
        r.currentBankValue + r.withPlayers + r.onTables + r.removed,
        r.startingBankValue,
      );
    });

    test('chips on a table are counted as in play, not lost', () async {
      final c = await _stock();
      await ChipTrackingService.recordDistribution(
        distribution: {c['100']!.id: 10},
        from: ChipLocation.bank,
        to: ChipLocation.table('t1'),
        reason: ChipMovementReason.tableFloat,
      );
      final r = ChipTrackingService.reconcile();
      expect(r.onTables, 1000);
      expect(r.currentBankValue, 19000);
      expect(r.totalAccountedFor, 20000);
    });

    test('deliberately removed chips stay in the accounting', () async {
      final c = await _stock();
      await ChipTrackingService.recordDistribution(
        distribution: {c['25']!.id: 4}, // $100 damaged
        from: ChipLocation.bank,
        to: ChipLocation.removed,
        reason: ChipMovementReason.adjustment,
      );
      final r = ChipTrackingService.reconcile();
      expect(r.removed, 100);
      expect(r.currentBankValue, 19900);
      // Removed is not missing: the total still explains every chip.
      expect(r.totalAccountedFor, 20000);
    });
  });
}
