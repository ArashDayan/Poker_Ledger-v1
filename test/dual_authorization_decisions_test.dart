// Decision 1 + Decision 2 (Option B) — dual-authorization regression suite.
//
// WHAT THIS LOCKS IN
// D1: every MANUAL chip-bank inventory adjustment (adding a
// denomination, quantity/value edit, setQuantity, the +/- steppers,
// removing a denomination) is ALWAYS two-person verified — no monetary
// threshold, no first-denomination exemption, no remove-and-readd
// bypass — and appends an immutable two-actor audit event carrying
// previous/counted quantity, the denomination, the mandatory reason
// and BOTH actors. Cosmetic edits (name/colour/note) stay
// single-operator. Normal Bank<->Table/Cage movements are untouched.
// D2 (Option B): post-hand stack counts settle WITHOUT a second
// verifier (hand flow is never interrupted); the STANDALONE holding
// reconciliation is ALWAYS gated, audited with the previous/counted
// holding values and the difference, and append-only — historical
// transactions are never edited or deleted.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:poker_ledger/models/chip_movement.dart';
import 'package:poker_ledger/models/chip_type.dart';
import 'package:poker_ledger/models/player.dart';
import 'package:poker_ledger/models/player_identity.dart';
import 'package:poker_ledger/models/table_operation_event.dart';
import 'package:poker_ledger/services/chip_bank_service.dart';
import 'package:poker_ledger/services/chip_tracking_service.dart';
import 'package:poker_ledger/services/dual_verification_service.dart';
import 'package:poker_ledger/services/hive_service.dart';
import 'package:poker_ledger/services/table_operation_event_service.dart';

import 'test_helper.dart';

late Directory _tmp;

const _auth = DualAuthorization(
  reason: 'counted the case with Baba',
  operatorName: 'Op',
  operatorSignatureBase64: 'op-sig',
  secondVerifierName: 'V',
  secondVerifierSignature: 'v-sig',
);

/// Every field present except a meaningful reason — proves the reason
/// is mandatory and validated BEFORE anything is written.
const _blankReason = DualAuthorization(
  reason: '   ',
  operatorName: 'Op',
  operatorSignatureBase64: 'op-sig',
  secondVerifierName: 'V',
  secondVerifierSignature: 'v-sig',
);

Future<void> _open() async {
  _tmp = await Directory.systemTemp.createTemp('pl_dual_');
  Hive.init(_tmp.path);
  registerTestAdapters();
  await Hive.openBox<ChipType>(HiveService.chipsBox);
  await Hive.openBox(HiveService.transferEventsBox);
  await Hive.openBox<ChipMovement>(HiveService.chipMovementsBox);
  await Hive.openBox<PlayerIdentity>(HiveService.playerIdentitiesBox);
  await HiveService.playerIdentities.put(
      'p1', PlayerIdentity(id: 'p1', displayName: 'P1'));
  await Hive.openBox<Player>(HiveService.playersBox);
  ChipTrackingService.installBankResolver();
}

Future<void> _close() async {
  ChipBankService.liveQuantityResolver = null;
  await Hive.deleteFromDisk();
  if (await _tmp.exists()) await _tmp.delete(recursive: true);
}

/// The immutable two-actor audit events appended by the always-on gate.
List<TableOperationEvent> get _dualEvents => TableOperationEventService.all()
    .where((e) => e.operation == TableOperationType.dualVerification)
    .toList();

Future<ChipType> _chip(double value, int quantity) =>
    ChipBankService.addChip(
        authorization: _auth, value: value, quantity: quantity);

void main() {
  setUp(_open);
  tearDown(_close);

  group('D1 — manual inventory adjustments are ALWAYS dual-verified', () {
    test('adding a denomination audits 0 -> N with both actors', () async {
      final chip = await _chip(200, 100);
      final events = _dualEvents;
      expect(events, hasLength(1));
      final e = events.single;
      expect(e.reason, contains('inventory_adjustment'));
      expect(e.reason, contains(_auth.reason));
      expect(e.chipTypeId, chip.id);
      expect(e.previousQuantity, 0);
      expect(e.countedQuantity, 100);
      expect(e.denominationValue, 200);
      expect(e.operatorName, 'Op');
      expect(e.secondVerifierName, 'V');
      expect(e.secondVerifierSignature, 'v-sig');
      expect(e.timestamp, isNotNull);
      // Not a player operation: no player is attached, so no J5 lookup.
      expect(e.playerId, isNull);
    });

    test('a blank reason is refused BEFORE anything is written', () async {
      await expectLater(
        ChipBankService.addChip(
            authorization: _blankReason, value: 200, quantity: 100),
        throwsA(isA<StateError>()),
      );
      expect(ChipBankService.allChips(), isEmpty);
      expect(_dualEvents, isEmpty);
    });

    test('a quantity change without authorization is refused pre-write',
        () async {
      final chip = await _chip(200, 100);
      await expectLater(
        ChipBankService.updateChip(chip.id, quantity: 80),
        throwsA(isA<StateError>()),
      );
      expect(HiveService.chips.get(chip.id)!.quantity, 100);
      expect(_dualEvents, hasLength(1)); // only the original add
    });

    test('the steppers and setQuantity route through the same gate',
        () async {
      final chip = await _chip(200, 100);
      await expectLater(
        ChipBankService.adjustQuantity(chip.id, 5),
        throwsA(isA<StateError>()),
      );
      await expectLater(
        ChipBankService.setQuantity(chip.id, 50),
        throwsA(isA<StateError>()),
      );
      expect(HiveService.chips.get(chip.id)!.quantity, 100);
      expect(_dualEvents, hasLength(1));
    });

    test('a unit-value change is an inventory adjustment (audited with detail)',
        () async {
      final chip = await _chip(200, 100);
      await ChipBankService.updateChip(chip.id,
          value: 500, authorization: _auth);
      final e = _dualEvents.last;
      expect(e.chipTypeId, chip.id);
      expect(e.previousQuantity, 100);
      expect(e.countedQuantity, 100);
      expect(e.denominationValue, 500);
      expect(e.reason, contains('unit value 200.0 -> 500.0'));
    });

    test('cosmetic edits stay single-operator (no gate, no event)', () async {
      final chip = await _chip(200, 100);
      await ChipBankService.updateChip(chip.id,
          name: 'Pink chips', clearNote: true);
      final after = HiveService.chips.get(chip.id)!;
      expect(after.quantity, 100);
      expect(after.name, 'Pink chips');
      expect(_dualEvents, hasLength(1)); // only the original add
    });

    test('remove is gated (N -> 0): no remove-and-readd bypass', () async {
      final chip = await _chip(200, 100);
      await ChipBankService.removeChip(chip.id, authorization: _auth);
      final e = _dualEvents.last;
      expect(e.previousQuantity, 100);
      expect(e.countedQuantity, 0);
      expect(e.denominationValue, 200);
      expect(ChipBankService.allChips(), isEmpty);
      // Re-adding must still present a complete authorization.
      await expectLater(
        ChipBankService.addChip(
            authorization: _blankReason, value: 200, quantity: 100),
        throwsA(isA<StateError>()),
      );
      expect(ChipBankService.allChips(), isEmpty);
    });
  });

  group('D2 Option B — hand flow ungated, standalone reconciliation gated', () {
    Future<ChipType> _buyIn(int qty) async {
      final c = await _chip(1000, 20);
      await ChipTrackingService.recordDistribution(
        distribution: {c.id: qty},
        from: ChipLocation.bank,
        to: ChipLocation.player('p1'),
        reason: ChipMovementReason.buyIn,
      );
      return c;
    }

    test('post-hand stack counts settle WITHOUT a second verifier', () async {
      final c = await _buyIn(5);
      final made =
          await ChipTrackingService.adjustPlayerHoldingForHandSettlement(
        playerId: 'p1',
        counted: {c.id: 8},
      );
      expect(made.single.reasonEnum, ChipMovementReason.adjustment);
      expect(
          ChipTrackingService.quantityAt(ChipLocation.player('p1'), c.id), 8);
      // No dual-verification event was appended by hand settlement.
      expect(_dualEvents, hasLength(1)); // only the D1 add
    });

    test('standalone reconciliation audits prev/counted/diff and both actors',
        () async {
      final c = await _buyIn(2);
      final made = await ChipTrackingService.reconcilePlayerHoldingToCount(
        playerId: 'p1',
        counted: {c.id: 5},
        authorization: _auth,
      );
      expect(made.single.quantity, 3);
      final e = _dualEvents.last;
      expect(e.reason, contains('holding_reconciliation'));
      expect(e.reason, contains(_auth.reason));
      expect(e.personId, 'p1');
      expect(e.previousValue, 2000);
      expect(e.countedValue, 5000);
      expect(e.carriedAmount, 3000);
      expect(e.operatorName, 'Op');
      expect(e.secondVerifierName, 'V');
      expect(e.relatedTransactionId, startsWith('count:'));
      // Append-only: the correction is a NEW movement carrying the
      // count facts and the reason; nothing was rewritten.
      final adj = made.single;
      expect(adj.note, startsWith('count:'));
      expect(adj.note, contains('recorded=2 counted=5'));
      expect(adj.note, endsWith(_auth.reason));
      expect(ChipTrackingService.allMovements().length, 2); // buy-in + adj
    });

    test('standalone reconciliation with a blank reason is refused pre-write',
        () async {
      final c = await _buyIn(2);
      await expectLater(
        ChipTrackingService.reconcilePlayerHoldingToCount(
          playerId: 'p1',
          counted: {c.id: 5},
          authorization: _blankReason,
        ),
        throwsA(isA<StateError>()),
      );
      // Nothing was written: holding unchanged, movements unchanged,
      // no reconciliation event.
      expect(
          ChipTrackingService.quantityAt(ChipLocation.player('p1'), c.id), 2);
      expect(ChipTrackingService.allMovements().length, 1); // buy-in only
      expect(_dualEvents, hasLength(1)); // only the D1 add
    });
  });
}
