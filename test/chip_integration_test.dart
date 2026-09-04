// Issue #9 — full Chip Bank integration.
//
// Covers the whole physical chip flow: buy-in/rebuy/cash-out composition,
// rake entering the Bank, edit via compensating reversal, void/unvoid,
// exchange, player-to-player transfer, low-inventory alerts, and the
// end-of-session reconciliation.
//
// The headline case is the acceptance scenario at the bottom:
//   Bank $20,000 | in $10,000 | rake $500 | out $8,500
//   => players $1,000, bank $19,000, total $20,000, discrepancy $0
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:poker_ledger/models/chip_movement.dart';
import 'package:poker_ledger/models/chip_type.dart';
import 'package:poker_ledger/models/enums.dart';
import 'package:poker_ledger/models/player.dart';
import 'package:poker_ledger/models/player_identity.dart';
import 'package:poker_ledger/models/session.dart';
import 'package:poker_ledger/models/transaction.dart';
import 'package:poker_ledger/services/chip_bank_service.dart';
import 'package:poker_ledger/services/chip_tracking_service.dart';
import 'package:poker_ledger/services/hive_service.dart';
import 'package:poker_ledger/services/session_service.dart';

import 'test_helper.dart';

late Directory _tmp;

Future<void> _open() async {
  _tmp = await Directory.systemTemp.createTemp('pl_chipint_');
  Hive.init(_tmp.path);
  registerTestAdapters();
  await Hive.openBox<PokerSession>(HiveService.sessionsBox);
  await Hive.openBox<Player>(HiveService.playersBox);
  await Hive.openBox<LedgerTransaction>(HiveService.transactionsBox);
  await Hive.openBox(HiveService.settingsBox);
  await Hive.openBox<ChipType>(HiveService.chipsBox);
  await Hive.openBox<ChipMovement>(HiveService.chipMovementsBox);
  await Hive.openBox<PlayerIdentity>(HiveService.playerIdentitiesBox);
  for (final id in ['A', 'B', 'C']) {
    await HiveService.playerIdentities.put(
        id, PlayerIdentity(id: id, displayName: id));
  }
  // Same wiring HiveService.init() performs in the app.
  ChipTrackingService.installBankResolver();
}

Future<void> _close() async {
  ChipBankService.liveQuantityResolver = null;
  await Hive.deleteFromDisk();
  if (await _tmp.exists()) await _tmp.delete(recursive: true);
}

/// Denominations totalling exactly $20,000.
Future<Map<String, ChipType>> _stockBank() async {
  final c1000 = await ChipBankService.addChip(value: 1000, quantity: 10);
  final c500 = await ChipBankService.addChip(value: 500, quantity: 10);
  final c100 = await ChipBankService.addChip(value: 100, quantity: 30);
  final c25 = await ChipBankService.addChip(value: 25, quantity: 40);
  final c5 = await ChipBankService.addChip(value: 5, quantity: 200);
  return {'1000': c1000, '500': c500, '100': c100, '25': c25, '5': c5};
}

double _bank() => ChipTrackingService.currentBankValue();
double _player(String id) =>
    ChipTrackingService.playerHolding(id).totalValue;

void main() {
  setUp(_open);
  tearDown(_close);

  group('bank inventory is live and derived', () {
    test('starting value is the baseline the banker entered', () async {
      await _stockBank();
      expect(ChipTrackingService.startingBankValue(), 20000);
      expect(_bank(), 20000);
    });

    test('handing chips out lowers the bank immediately', () async {
      final c = await _stockBank();
      await ChipTrackingService.recordDistribution(
        distribution: {c['1000']!.id: 3},
        from: ChipLocation.bank,
        to: ChipLocation.player('p1'),
        reason: ChipMovementReason.buyIn,
      );
      expect(_bank(), 17000);
      expect(_player('p1'), 3000);
    });

    test('ChipBankService.summary reports the LIVE figure', () async {
      final c = await _stockBank();
      expect(ChipBankService.summary().totalValue, 20000);

      await ChipTrackingService.recordDistribution(
        distribution: {c['1000']!.id: 2},
        from: ChipLocation.bank,
        to: ChipLocation.player('p1'),
        reason: ChipMovementReason.buyIn,
      );

      final s = ChipBankService.summary();
      expect(s.totalValue, 18000, reason: 'live value must drop');
      expect(s.startingValue, 20000, reason: 'baseline must not move');
      expect(s.outValue, 2000);
    });

    test('the baseline ChipType.quantity is never mutated', () async {
      final c = await _stockBank();
      await ChipTrackingService.recordDistribution(
        distribution: {c['1000']!.id: 4},
        from: ChipLocation.bank,
        to: ChipLocation.player('p1'),
        reason: ChipMovementReason.buyIn,
      );
      // Mutating it as well would double-count, because quantityAt()
      // already starts from it.
      expect(ChipBankService.byId(c['1000']!.id)!.quantity, 10);
      expect(
          ChipTrackingService.quantityAt(
              ChipLocation.bank, c['1000']!.id),
          6);
    });
  });

  group('rake enters the Bank, not removed', () {
    test('rake chips increase bank inventory', () async {
      final c = await _stockBank();
      await ChipTrackingService.recordDistribution(
        distribution: {c['500']!.id: 1},
        from: ChipLocation.player('p1'),
        to: ChipLocation.bank,
        reason: ChipMovementReason.rake,
      );
      expect(_bank(), 20500);
      expect(ChipTrackingService.removedHolding().totalValue, 0,
          reason: 'removed is reserved for damaged/lost chips');
    });

    test('reconciliation reports rake returned to the bank', () async {
      final c = await _stockBank();
      await ChipTrackingService.recordDistribution(
        distribution: {c['500']!.id: 1},
        from: ChipLocation.player('p1'),
        to: ChipLocation.bank,
        reason: ChipMovementReason.rake,
      );
      expect(ChipTrackingService.reconcile().rakeReturnedToBank, 500);
    });
  });

  group('edit via compensating reversal', () {
    test('corrected composition, same value, audit preserved', () async {
      final c = await _stockBank();
      await ChipTrackingService.recordDistribution(
        distribution: {c['1000']!.id: 2},
        from: ChipLocation.bank,
        to: ChipLocation.player('p1'),
        reason: ChipMovementReason.buyIn,
        transactionId: 'tx1',
      );
      expect(_player('p1'), 2000);

      await ChipTrackingService.editDistribution(
        transactionId: 'tx1',
        distribution: {c['1000']!.id: 1, c['500']!.id: 2},
        from: ChipLocation.bank,
        to: ChipLocation.player('p1'),
        reason: ChipMovementReason.buyIn,
      );

      expect(_player('p1'), 2000, reason: 'value unchanged');
      expect(
          ChipTrackingService.quantityAt(
              ChipLocation.player('p1'), c['1000']!.id),
          1);
      expect(
          ChipTrackingService.quantityAt(
              ChipLocation.player('p1'), c['500']!.id),
          2);
      expect(_bank(), 18000);

      // Original + reversal + corrected all still on file.
      final all = ChipTrackingService.allMovements()
          .where((m) => m.transactionId == 'tx1');
      expect(all.length, 4, reason: 'nothing was destroyed');
      expect(
          all.any((m) => m.reasonEnum == ChipMovementReason.reversal), isTrue);
    });

    test('editing to an empty composition just reverses', () async {
      final c = await _stockBank();
      await ChipTrackingService.recordDistribution(
        distribution: {c['1000']!.id: 1},
        from: ChipLocation.bank,
        to: ChipLocation.player('p1'),
        reason: ChipMovementReason.buyIn,
        transactionId: 'tx1',
      );
      await ChipTrackingService.editDistribution(
        transactionId: 'tx1',
        distribution: const {},
        from: ChipLocation.bank,
        to: ChipLocation.player('p1'),
        reason: ChipMovementReason.buyIn,
      );
      expect(_player('p1'), 0);
      expect(_bank(), 20000);
    });
  });

  group('void / unvoid / redo', () {
    test('reversing a buy-in returns the exact chips', () async {
      final c = await _stockBank();
      await ChipTrackingService.recordDistribution(
        distribution: {c['1000']!.id: 1, c['100']!.id: 5},
        from: ChipLocation.bank,
        to: ChipLocation.player('p1'),
        reason: ChipMovementReason.buyIn,
        transactionId: 'tx1',
      );
      expect(_bank(), 18500);

      await ChipTrackingService.reverseForTransaction('tx1', note: 'void');

      expect(_bank(), 20000);
      expect(_player('p1'), 0);
      expect(ChipTrackingService.hasActiveChips('tx1'), isFalse);
    });

    test('double void is a no-op', () async {
      final c = await _stockBank();
      await ChipTrackingService.recordDistribution(
        distribution: {c['1000']!.id: 1},
        from: ChipLocation.bank,
        to: ChipLocation.player('p1'),
        reason: ChipMovementReason.buyIn,
        transactionId: 'tx1',
      );
      await ChipTrackingService.reverseForTransaction('tx1');
      await ChipTrackingService.reverseForTransaction('tx1');
      expect(_bank(), 20000, reason: 'must not over-credit the bank');
    });

    test('unvoid re-applies the same denominations', () async {
      final c = await _stockBank();
      await ChipTrackingService.recordDistribution(
        distribution: {c['500']!.id: 3},
        from: ChipLocation.bank,
        to: ChipLocation.player('p1'),
        reason: ChipMovementReason.buyIn,
        transactionId: 'tx1',
      );
      await ChipTrackingService.reverseForTransaction('tx1');
      await ChipTrackingService.reapplyForTransaction('tx1');

      expect(_player('p1'), 1500);
      expect(
          ChipTrackingService.quantityAt(
              ChipLocation.player('p1'), c['500']!.id),
          3);
      expect(_bank(), 18500);
    });

    test('reapply does nothing while chips are still active', () async {
      final c = await _stockBank();
      await ChipTrackingService.recordDistribution(
        distribution: {c['500']!.id: 1},
        from: ChipLocation.bank,
        to: ChipLocation.player('p1'),
        reason: ChipMovementReason.buyIn,
        transactionId: 'tx1',
      );
      await ChipTrackingService.reapplyForTransaction('tx1');
      expect(_player('p1'), 500, reason: 'must not duplicate');
    });
  });

  group('exchange', () {
    test('denominations swap at equal value', () async {
      final c = await _stockBank();
      await ChipTrackingService.recordDistribution(
        distribution: {c['25']!.id: 4, c['5']!.id: 4},
        from: ChipLocation.bank,
        to: ChipLocation.player('p1'),
        reason: ChipMovementReason.buyIn,
      );
      final before = _player('p1');
      final bankBefore = _bank();

      await ChipTrackingService.recordExchange(
        counterparty: ChipLocation.player('p1'),
        chipsIn: {c['25']!.id: 4, c['5']!.id: 4}, // $120
        chipsOut: {c['100']!.id: 1, c['25']!.id: 0, c['5']!.id: 4}, // $120
      );

      expect(_player('p1'), before, reason: 'player value unchanged');
      expect(_bank(), bankBefore, reason: 'bank value unchanged');
    });

    test('unequal values are refused', () async {
      final c = await _stockBank();
      expect(
        () => ChipTrackingService.recordExchange(
          counterparty: ChipLocation.player('p1'),
          chipsIn: {c['100']!.id: 1},
          chipsOut: {c['25']!.id: 1},
        ),
        throwsArgumentError,
      );
    });

    test('both legs share one exchange tag and create no transaction',
        () async {
      final c = await _stockBank();
      final made = await ChipTrackingService.recordExchange(
        counterparty: ChipLocation.player('p1'),
        chipsIn: {c['100']!.id: 1},
        chipsOut: {c['25']!.id: 4},
      );
      final tags = made.map((m) => m.note).toSet();
      expect(tags.length, 1);
      expect(tags.single!.startsWith('exchange:'), isTrue);
      expect(made.every((m) => m.transactionId == null), isTrue);
      expect(HiveService.transactions.length, 0);
    });
  });

  // Player-to-player chip transfer is REMOVED (E7): the approved way to
  // capture chips that changed hands at the table is a physical count
  // per player (the re-anchor pair nets to zero for the bank).
  group('physical count (P2P removed)', () {
    test('a count moves holdings without touching the bank', () async {
      final c = await _stockBank();
      await ChipTrackingService.recordDistribution(
        distribution: {c['500']!.id: 4},
        from: ChipLocation.bank,
        to: ChipLocation.player('A'),
        reason: ChipMovementReason.buyIn,
      );
      final bankBefore = _bank();

      // Play happens; the banker counts: A holds 2 x $500, B holds 2.
      await ChipTrackingService.adjustPlayerHoldingToCount(
        playerId: 'A',
        counted: {c['500']!.id: 2},
      );
      await ChipTrackingService.adjustPlayerHoldingToCount(
        playerId: 'B',
        counted: {c['500']!.id: 2},
      );

      expect(_player('A'), 1000);
      expect(_player('B'), 1000);
      expect(_bank(), bankBefore, reason: 'bank must be unaffected');
      expect(HiveService.transactions.length, 0);
    });

    test('an empty or negative count is refused', () async {
      final c = await _stockBank();
      expect(
        () => ChipTrackingService.adjustPlayerHoldingToCount(
          playerId: 'A',
          counted: {},
        ),
        throwsArgumentError,
      );
      expect(
        () => ChipTrackingService.adjustPlayerHoldingToCount(
          playerId: 'A',
          counted: {c['500']!.id: -1},
        ),
        throwsArgumentError,
      );
    });
  });

  group('low-inventory thresholds', () {
    test('fractions track value, not chip count', () async {
      final c = await _stockBank();
      expect(ChipTrackingService.bankRemainingFraction(), 1.0);

      // Hand out exactly half the VALUE ($10,000).
      await ChipTrackingService.recordDistribution(
        distribution: {c['1000']!.id: 10},
        from: ChipLocation.bank,
        to: ChipLocation.player('p1'),
        reason: ChipMovementReason.buyIn,
      );
      expect(ChipTrackingService.bankRemainingFraction(), 0.5);
      expect(_bank(), 10000);
    });

    test('30% threshold is reached by value', () async {
      final c = await _stockBank();
      await ChipTrackingService.recordDistribution(
        distribution: {c['1000']!.id: 10, c['500']!.id: 8},
        from: ChipLocation.bank,
        to: ChipLocation.player('p1'),
        reason: ChipMovementReason.buyIn,
      );
      // 20000 - 14000 = 6000 = 30%
      expect(_bank(), 6000);
      expect(ChipTrackingService.bankRemainingFraction(), 0.3);
    });

    test('no inventory configured yields a null fraction', () {
      expect(ChipTrackingService.bankRemainingFraction(), isNull);
    });
  });

  group('reconciliation', () {
    test('without a physical count it claims no discrepancy', () async {
      final c = await _stockBank();
      await ChipTrackingService.recordDistribution(
        distribution: {c['1000']!.id: 3},
        from: ChipLocation.bank,
        to: ChipLocation.player('p1'),
        reason: ChipMovementReason.buyIn,
      );
      final r = ChipTrackingService.reconcile();
      expect(r.wasVerified, isFalse);
      expect(r.discrepancy, 0);
      expect(r.balances, isTrue);
    });

    test('a physical count reveals genuinely missing chips', () async {
      final c = await _stockBank();
      await ChipTrackingService.recordDistribution(
        distribution: {c['1000']!.id: 3},
        from: ChipLocation.bank,
        to: ChipLocation.player('p1'),
        reason: ChipMovementReason.buyIn,
      );
      // Log expects 7 x $1000 in the case; only 5 are there.
      final r = ChipTrackingService.reconcile(
        physicalCount: {c['1000']!.id: 5},
      );
      expect(r.wasVerified, isTrue);
      expect(r.discrepancy, 2000);
      expect(r.balances, isFalse);
    });

    test('a matching count reconciles', () async {
      final c = await _stockBank();
      await ChipTrackingService.recordDistribution(
        distribution: {c['1000']!.id: 3},
        from: ChipLocation.bank,
        to: ChipLocation.player('p1'),
        reason: ChipMovementReason.buyIn,
      );
      final r = ChipTrackingService.reconcile(
        physicalCount: {c['1000']!.id: 7},
      );
      expect(r.balances, isTrue);
      expect(r.discrepancy, 0);
    });
  });

  group('ACCEPTANCE: \$20,000 bank, \$10,000 in, \$500 rake, \$8,500 out', () {
    test('every chip is accounted for and nothing is invented', () async {
      final c = await _stockBank();
      final k1000 = c['1000']!.id;
      final k500 = c['500']!.id;
      final k100 = c['100']!.id;

      expect(ChipTrackingService.startingBankValue(), 20000);

      // Buy-ins: 3 players across 2 tables = $10,000
      await ChipTrackingService.recordDistribution(
        distribution: {k1000: 3, k500: 2, k100: 10},
        from: ChipLocation.bank,
        to: ChipLocation.player('A'),
        reason: ChipMovementReason.buyIn,
        transactionId: 'b1',
      ); // 5000
      await ChipTrackingService.recordDistribution(
        distribution: {k1000: 2, k500: 4},
        from: ChipLocation.bank,
        to: ChipLocation.player('B'),
        reason: ChipMovementReason.buyIn,
        transactionId: 'b2',
      ); // 4000
      await ChipTrackingService.recordDistribution(
        distribution: {k500: 1, k100: 5},
        from: ChipLocation.bank,
        to: ChipLocation.player('C'),
        reason: ChipMovementReason.rebuy,
        transactionId: 'b3',
      ); // 1000

      expect(_bank(), 10000);

      // Denomination exchange and a physical count (a pot moved A→B)
      // — neither may change any total.
      final playersBefore = ChipTrackingService.reconcile().withPlayers;
      await ChipTrackingService.recordExchange(
        counterparty: ChipLocation.player('A'),
        chipsIn: {k100: 5},
        chipsOut: {k500: 1},
      );
      // A: 3x1000+2x500+10x100 - 5x100 + 1x500, then count 1x1000 less.
      // B: 2x1000+4x500, then count 1x1000 more.
      await ChipTrackingService.adjustPlayerHoldingToCount(
        playerId: 'A',
        counted: {k1000: 2, k500: 3, k100: 5},
      );
      await ChipTrackingService.adjustPlayerHoldingToCount(
        playerId: 'B',
        counted: {k1000: 3, k500: 4},
      );
      expect(ChipTrackingService.reconcile().withPlayers, playersBefore);

      // Rake $500 in physical chips -> Bank
      await ChipTrackingService.recordDistribution(
        distribution: {k500: 1},
        from: ChipLocation.player('A'),
        to: ChipLocation.bank,
        reason: ChipMovementReason.rake,
        transactionId: 'r1',
      );
      expect(_bank(), 10500);

      // Cash-outs = $8,500
      await ChipTrackingService.recordDistribution(
        distribution: {k1000: 2, k500: 3},
        from: ChipLocation.player('A'),
        to: ChipLocation.bank,
        reason: ChipMovementReason.cashOut,
        transactionId: 'co1',
      ); // 3500
      await ChipTrackingService.recordDistribution(
        distribution: {k1000: 3},
        from: ChipLocation.player('B'),
        to: ChipLocation.bank,
        reason: ChipMovementReason.cashOut,
        transactionId: 'co2',
      ); // 3000
      await ChipTrackingService.recordDistribution(
        distribution: {k500: 4},
        from: ChipLocation.player('C'),
        to: ChipLocation.bank,
        reason: ChipMovementReason.cashOut,
        transactionId: 'co3',
      ); // 2000

      final r = ChipTrackingService.reconcile();
      expect(r.currentBankValue, 19000, reason: 'ending bank');
      expect(r.withPlayers, 1000, reason: 'players still hold \$1,000');
      expect(r.rakeReturnedToBank, 500);
      expect(r.removed, 0, reason: 'no chips invented or destroyed');
      expect(r.totalAccountedFor, 20000);
      expect(r.startingBankValue, 20000);

      // And a physical count of the case confirms it.
      final counted = <String, int>{
        for (final chip in ChipBankService.allChips())
          chip.id: ChipTrackingService.quantityAt(ChipLocation.bank, chip.id)
      };
      final verified = ChipTrackingService.reconcile(physicalCount: counted);
      expect(verified.wasVerified, isTrue);
      expect(verified.discrepancy, 0);
      expect(verified.balances, isTrue);
    });
  });

  group('money ledger stays separate', () {
    test('chip operations never create or alter transactions', () async {
      final session = PokerSession(
        id: 's1',
        name: 'G',
        location: 'H',
        dateTime: DateTime.now(),
        smallBlind: 1,
        bigBlind: 2,
        tableNumber: '1',
      );
      await HiveService.sessions.put(session.id, session);
      await HiveService.transactions.put(
        't1',
        LedgerTransaction(
          id: 't1',
          sessionId: 's1',
          playerId: 'A',
          type: TransactionType.buyIn,
          amount: 1000,
        ),
      );
      final before = SessionService.checkBalance('s1');

      final c = await _stockBank();
      await ChipTrackingService.recordDistribution(
        distribution: {c['1000']!.id: 1},
        from: ChipLocation.bank,
        to: ChipLocation.player('A'),
        reason: ChipMovementReason.buyIn,
        transactionId: 't1',
      );
      await ChipTrackingService.recordExchange(
        counterparty: ChipLocation.player('A'),
        chipsIn: {c['1000']!.id: 1},
        chipsOut: {c['500']!.id: 2},
      );
      // Play: count A down 1 x $500 and B up 1 x $500 (P2P removed).
      await ChipTrackingService.adjustPlayerHoldingToCount(
        playerId: 'A',
        counted: {c['500']!.id: 1},
      );
      await ChipTrackingService.adjustPlayerHoldingToCount(
        playerId: 'B',
        counted: {c['500']!.id: 1},
      );

      final after = SessionService.checkBalance('s1');
      expect(after.moneyIn, before.moneyIn);
      expect(after.moneyOut, before.moneyOut);
      expect(HiveService.transactions.length, 1);
      expect(SessionService.totalBuyIn('s1'), 1000);
    });
  });
}
