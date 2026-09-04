// Chip editor sheet — D1 authorization wiring (widget regression).
//
// WHAT THIS LOCKS IN
// The editor's Save is the fourth inventory entry point alongside the
// Chip Bank remove / +/- steppers and the holding sheet:
//   * ADD path: the always-on two-person sheet MUST appear before any
//     write; cancelling it aborts with ZERO inventory writes and ZERO
//     audit events, and the editor stays open.
//   * COSMETIC edit path (name/colour/note only): no verification sheet
//     appears, the edit applies directly (single operator), and no new
//     dual-verification event is appended beyond the original add.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:poker_ledger/models/chip_movement.dart';
import 'package:poker_ledger/models/chip_type.dart';
import 'package:poker_ledger/models/player_identity.dart';
import 'package:poker_ledger/models/table_operation_event.dart';
import 'package:poker_ledger/providers/chip_bank_provider.dart';
import 'package:poker_ledger/screens/chip_bank/chip_editor_sheet.dart';
import 'package:poker_ledger/services/chip_bank_service.dart';
import 'package:poker_ledger/services/dual_verification_service.dart';
import 'package:poker_ledger/services/hive_service.dart';
import 'package:poker_ledger/services/table_operation_event_service.dart';
import 'package:provider/provider.dart';

import 'test_helper.dart';

late Directory _tmp;

const _auth = DualAuthorization(
  reason: 'test inventory',
  operatorName: 'Op',
  operatorSignatureBase64: 'op-sig',
  secondVerifierName: 'V',
  secondVerifierSignature: 'v-sig',
);

Future<void> _open() async {
  _tmp = await Directory.systemTemp.createTemp('pl_editor_w_');
  Hive.init(_tmp.path);
  registerTestAdapters();
  await Hive.openBox<ChipType>(HiveService.chipsBox);
  await Hive.openBox(HiveService.transferEventsBox);
  await Hive.openBox<ChipMovement>(HiveService.chipMovementsBox);
  await Hive.openBox<PlayerIdentity>(HiveService.playerIdentitiesBox);
  await Hive.openBox(HiveService.settingsBox);
}

Future<void> _close() async {
  ChipBankService.liveQuantityResolver = null;
  await Hive.deleteFromDisk();
  if (await _tmp.exists()) await _tmp.delete(recursive: true);
}

int get _dualEventCount => TableOperationEventService.all()
    .where((e) => e.operation == TableOperationType.dualVerification)
    .length;

Widget _harness(ChipBankProvider provider, {ChipType? existing}) =>
    ChangeNotifierProvider<ChipBankProvider>.value(
      value: provider,
      child: MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: ElevatedButton(
              onPressed: () => showModalBottomSheet(
                context: context,
                isScrollControlled: true,
                builder: (_) => ChipEditorSheet(existing: existing),
              ),
              child: const Text('open-editor'),
            ),
          ),
        ),
      ),
    );

void main() {
  setUp(_open);
  tearDown(_close);

  testWidgets('ADD path: cancelling the always-on authorisation writes nothing',
      (tester) async {
    final provider = ChipBankProvider();
    await tester.pumpWidget(_harness(provider));
    await tester.tap(find.text('open-editor'));
    await tester.pumpAndSettle();

    // Value + quantity are the first two fields.
    await tester.enterText(find.byType(TextField).at(0), '500');
    await tester.enterText(find.byType(TextField).at(1), '100');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    // The always-on two-person sheet appeared BEFORE any write.
    expect(find.text('Second authorisation required'), findsOneWidget);

    // Cancel: zero writes, zero audit events, editor still open.
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(ChipBankService.allChips(), isEmpty);
    expect(_dualEventCount, 0);
    expect(find.byType(ChipEditorSheet), findsOneWidget);
    provider.dispose();
  });

  testWidgets('COSMETIC edit: no authorisation sheet, direct apply',
      (tester) async {
    final chip = await ChipBankService.addChip(
        authorization: _auth, value: 200, quantity: 100);
    expect(_dualEventCount, 1); // the original D1-gated add

    final provider = ChipBankProvider();
    await tester.pumpWidget(_harness(provider, existing: chip));
    await tester.tap(find.text('open-editor'));
    await tester.pumpAndSettle();

    // Change ONLY the display name (third field); value/quantity stay as
    // seeded from the existing chip.
    await tester.ensureVisible(find.byType(TextField).at(2));
    await tester.enterText(find.byType(TextField).at(2), 'Pink chips');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    // No verification sheet ever appeared; the edit applied directly.
    expect(find.text('Second authorisation required'), findsNothing);
    final after = HiveService.chips.get(chip.id)!;
    expect(after.name, 'Pink chips');
    expect(after.quantity, 100);
    expect(after.value, 200);
    expect(_dualEventCount, 1); // still only the original add
    provider.dispose();
  });
}
