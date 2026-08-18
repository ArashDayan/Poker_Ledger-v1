// Chip holding adjustment — regression suite.
//
// WHAT THIS LOCKS IN
// Chip Change / Chip Transfer validate against the player's ACTUAL
// derived chip holding (the append-only ChipMovement fold), NEVER
// against Buy-in/Rebuy/Money In or any financial figure. Wins recorded
// as chip movements raise the holding accordingly, and a banker's
// physical count can reconcile the holding via append-only
// ChipMovementReason.adjustment movements — without creating money,
// transactions, financial events, or any Discount effect.
//
// Gates mirror chip_exchange_sheet.dart `_playerCanCover` /
// `_bankCanCover` / `_balanced` exactly.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:poker_ledger/models/chip_movement.dart';
import 'package:poker_ledger/models/chip_type.dart';
import 'package:poker_ledger/models/financial_event.dart';
import 'package:poker_ledger/models/player.dart';
import 'package:poker_ledger/models/player_identity.dart';
import 'package:poker_ledger/models/session.dart';
import 'package:poker_ledger/models/transaction.dart';
import 'package:poker_ledger/services/chip_bank_service.dart';
import 'package:poker_ledger/services/chip_tracking_service.dart';
import 'package:poker_ledger/services/hive_service.dart';

import 'test_helper.dart';

late Directory _tmp;

Future<void> _open() async {
  _tmp = await Directory.systemTemp.createTemp('pl_chipadj_');
  Hive.init(_tmp.path);
  registerTestAdapters();
  await Hive.openBox<PokerSession>(HiveService.sessionsBox);
  await Hive.openBox<Player>(HiveService.playersBox);
  await Hive.openBox<LedgerTransaction>(HiveService.transactionsBox);
  await Hive.openBox(HiveService.settingsBox);
  await Hive.openBox<PlayerIdentity>(HiveService.playerIdentitiesBox);
  await Hive.openBox<FinancialEvent>(HiveService.financialEventsBox);
  await Hive.openBox<ChipType>(HiveService.chipsBox);
  await Hive.openBox<ChipMovement>(HiveService.chipMovementsBox);
  ChipTrackingService.installBankResolver();
}

Future<void> _close() async {
  ChipBankService.liveQuantityResolver = null;
  await Hive.deleteFromDisk();
  if (await _tmp.exists()) await _tmp.delete(recursive: true);
}

/// Denominations: 1,000,000 and 5,000,000 — enough stock for every
/// scenario below.
Future<Map<String, ChipType>> _stock() async {
  final c1 = await ChipBankService.addChip(value: 1000000, quantity: 20);
  final c5 = await ChipBankService.addChip(value: 5000000, quantity: 10);
  return {'1m': c1, '5m': c5};
}

int _atPlayer(String p, String id) =>
    ChipTrackingService.quantityAt(ChipLocation.player(p), id);
int _atBank(String id) =>
    ChipTrackingService.quantityAt(ChipLocation.bank, id);

/// Mirror of the exchange sheet's gates.
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

void main() {
  setUp(_open);
  tearDown(_close);

  group('Chip holding is the actual derived holding, never the buy-in', () {
    test('buy-in 2M + recorded win 3M = holding 5M, and a 5M change is '
        'allowed', () async {
      final c = await _stock();

      // P1 buys in for 2M; P2 buys in for 3M.
      await ChipTrackingService.recordDistribution(
        distribution: {c['1m']!.id: 2},
        from: ChipLocation.bank,
        to: ChipLocation.player('p1'),
        reason: ChipMovementReason.buyIn,
      );
      await ChipTrackingService.recordDistribution(
        distribution: {c['1m']!.id: 3},
        from: ChipLocation.bank,
        to: ChipLocation.player('p2'),
        reason: ChipMovementReason.buyIn,
      );

      // P1 wins P2's 3M during play — recorded as a chip transfer.
      await ChipTrackingService.recordPlayerTransfer(
        fromPlayerId: 'p2',
        toPlayerId: 'p1',
        distribution: {c['1m']!.id: 3},
      );

      // The holding now reflects the win: 5M, not the 2M buy-in.
      expect(_atPlayer('p1', c['1m']!.id), 5);
      expect(ChipTrackingService.playerHolding('p1').totalValue, 5000000);
      // P2P transfer left the Bank untouched.
      expect(_atBank(c['1m']!.id), 15);

      // A 5M chip change (five 1M -> one 5M) must be ALLOWED.
      expect(
        exchangeAllowed(
          playerId: 'p1',
          given: {c['1m']!.id: 5},
          received: {c['5m']!.id: 1},
        ),
        isTrue,
      );
      await ChipTrackingService.recordExchange(
        counterparty: ChipLocation.player('p1'),
        chipsIn: {c['1m']!.id: 5},
        chipsOut: {c['5m']!.id: 1},
      );
      // Same value, different composition.
      expect(ChipTrackingService.playerHolding('p1').totalValue, 5000000);
      expect(_atPlayer('p1', c['5m']!.id), 1);
      expect(_atPlayer('p1', c['1m']!.id), 0);
    });

    test('a change above the actual derived holding is blocked', () async {
      final c = await _stock();
      await ChipTrackingService.recordDistribution(
        distribution: {c['1m']!.id: 2},
        from: ChipLocation.bank,
        to: ChipLocation.player('p1'),
        reason: ChipMovementReason.buyIn,
      );
      // 3M requested against a 2M holding — blocked by the cover gate.
      expect(
        exchangeAllowed(
          playerId: 'p1',
          given: {c['1m']!.id: 3},
          received: {c['5m']!.id: 1},
        ),
        isFalse,
      );
    });

    test('unrecorded physical winnings do not appear in the ledger',
        () async {
      final c = await _stock();
      await ChipTrackingService.recordDistribution(
        distribution: {c['1m']!.id: 2},
        from: ChipLocation.bank,
        to: ChipLocation.player('p1'),
        reason: ChipMovementReason.buyIn,
      );
      // The ledger only knows recorded movements: holding is exactly
      // the buy-in until a transfer or an adjustment says otherwise.
      expect(_atPlayer('p1', c['1m']!.id), 2);
      expect(
        exchangeAllowed(
          playerId: 'p1',
          given: {c['1m']!.id: 5},
          received: {c['5m']!.id: 1},
        ),
        isFalse,
      );
    });
  });

  group('Physical-count adjustment', () {
    test('holding 2M, physical count 5M -> one +3M adjustment, holding 5M',
        () async {
      final c = await _stock();
      await ChipTrackingService.recordDistribution(
        distribution: {c['1m']!.id: 2},
        from: ChipLocation.bank,
        to: ChipLocation.player('p1'),
        reason: ChipMovementReason.buyIn,
      );

      final made = await ChipTrackingService.adjustPlayerHoldingToCount(
        playerId: 'p1',
        counted: {c['1m']!.id: 5, c['5m']!.id: 0},
      );
      expect(made.length, 1);
      expect(made.single.reasonEnum, ChipMovementReason.adjustment);
      expect(made.single.quantity, 3);
      expect(made.single.fromLocation, ChipLocation.bank.encoded);
      expect(made.single.toLocation, ChipLocation.player('p1').encoded);
      expect(_atPlayer('p1', c['1m']!.id), 5);
      expect(ChipTrackingService.playerHolding('p1').totalValue, 5000000);
    });

    test('after the adjustment, the 5M chip change is allowed', () async {
      final c = await _stock();
      await ChipTrackingService.recordDistribution(
        distribution: {c['1m']!.id: 2},
        from: ChipLocation.bank,
        to: ChipLocation.player('p1'),
        reason: ChipMovementReason.buyIn,
      );
      await ChipTrackingService.adjustPlayerHoldingToCount(
        playerId: 'p1',
        counted: {c['1m']!.id: 5, c['5m']!.id: 0},
      );

      expect(
        exchangeAllowed(
          playerId: 'p1',
          given: {c['1m']!.id: 5},
          received: {c['5m']!.id: 1},
        ),
        isTrue,
      );
      await ChipTrackingService.recordExchange(
        counterparty: ChipLocation.player('p1'),
        chipsIn: {c['1m']!.id: 5},
        chipsOut: {c['5m']!.id: 1},
      );
      expect(ChipTrackingService.playerHolding('p1').totalValue, 5000000);
    });

    test('a shortfall count moves chips back toward the bank', () async {
      final c = await _stock();
      await ChipTrackingService.recordDistribution(
        distribution: {c['1m']!.id: 5},
        from: ChipLocation.bank,
        to: ChipLocation.player('p1'),
        reason: ChipMovementReason.buyIn,
      );
      final made = await ChipTrackingService.adjustPlayerHoldingToCount(
        playerId: 'p1',
        counted: {c['1m']!.id: 2, c['5m']!.id: 0},
      );
      expect(made.length, 1);
      expect(made.single.fromLocation, ChipLocation.player('p1').encoded);
      expect(made.single.toLocation, ChipLocation.bank.encoded);
      expect(_atPlayer('p1', c['1m']!.id), 2);
    });

    test('the adjustment stays in the movement history — append-only',
        () async {
      final c = await _stock();
      await ChipTrackingService.recordDistribution(
        distribution: {c['1m']!.id: 2},
        from: ChipLocation.bank,
        to: ChipLocation.player('p1'),
        reason: ChipMovementReason.buyIn,
      );
      await ChipTrackingService.adjustPlayerHoldingToCount(
        playerId: 'p1',
        counted: {c['1m']!.id: 5, c['5m']!.id: 0},
      );

      final all = ChipTrackingService.allMovements();
      expect(all.length, 2);
      expect(
        all.map((m) => m.reasonEnum),
        containsAll([
          ChipMovementReason.buyIn,
          ChipMovementReason.adjustment,
        ]),
      );
      final adj =
          all.firstWhere((m) => m.reasonEnum == ChipMovementReason.adjustment);
      expect(adj.note, startsWith('count:'));
      expect(adj.note, contains('recorded=2'));
      expect(adj.note, contains('counted=5'));
    });

    test('count equal to the recorded holding writes nothing', () async {
      final c = await _stock();
      await ChipTrackingService.recordDistribution(
        distribution: {c['1m']!.id: 2},
        from: ChipLocation.bank,
        to: ChipLocation.player('p1'),
        reason: ChipMovementReason.buyIn,
      );
      final made = await ChipTrackingService.adjustPlayerHoldingToCount(
        playerId: 'p1',
        counted: {c['1m']!.id: 2, c['5m']!.id: 0},
      );
      expect(made, isEmpty);
      expect(ChipTrackingService.allMovements().length, 1);
    });

    test('empty and negative counts are refused', () async {
      final c = await _stock();
      await ChipTrackingService.recordDistribution(
        distribution: {c['1m']!.id: 2},
        from: ChipLocation.bank,
        to: ChipLocation.player('p1'),
        reason: ChipMovementReason.buyIn,
      );
      await expectLater(
        ChipTrackingService.adjustPlayerHoldingToCount(
          playerId: 'p1',
          counted: const {},
        ),
        throwsArgumentError,
      );
      await expectLater(
        ChipTrackingService.adjustPlayerHoldingToCount(
          playerId: 'p1',
          counted: {c['1m']!.id: -1},
        ),
        throwsArgumentError,
      );
    });
  });

  group('Accounting boundary — adjustment and change are chip-only', () {
    test('no Money In/Out, no transaction, no FinancialEvent, no Discount '
        'effect; the chip identity still balances', () async {
      final c = await _stock();
      final txBefore = HiveService.transactions.length;
      final finBefore = HiveService.financialEvents.length;
      final startingValue = ChipTrackingService.startingBankValue();

      await ChipTrackingService.recordDistribution(
        distribution: {c['1m']!.id: 2},
        from: ChipLocation.bank,
        to: ChipLocation.player('p1'),
        reason: ChipMovementReason.buyIn,
      );
      await ChipTrackingService.adjustPlayerHoldingToCount(
        playerId: 'p1',
        counted: {c['1m']!.id: 5, c['5m']!.id: 0},
      );
      await ChipTrackingService.recordExchange(
        counterparty: ChipLocation.player('p1'),
        chipsIn: {c['1m']!.id: 5},
        chipsOut: {c['5m']!.id: 1},
      );

      // Nothing money-shaped was written by any of it.
      expect(HiveService.transactions.length, txBefore);
      expect(HiveService.financialEvents.length, finBefore,
          reason: 'chip-only operations never create FinancialEvents, '
              'so the Discount engine has nothing new to read');

      // The physical identity holds: every chip is somewhere.
      final report = ChipTrackingService.audit();
      expect(report.balances, isTrue);

      final totalAccountedValue = report.lines.fold<double>(
        0,
        (sum, line) => sum + (line.accountedFor * line.chipValue),
      );
      expect(totalAccountedValue, startingValue);
      // Exchange changed composition, not value.
      expect(ChipTrackingService.playerHolding('p1').totalValue, 5000000);
    });
  });
}
