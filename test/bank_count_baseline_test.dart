// Phase 2b — bank count-sheet baseline.
//
// The case ledger's baseline is the LATEST physical count sheet +
// movements strictly after it. When NO count sheet exists, the legacy
// quantity baseline applies EXACTLY as before (invariance asserted).
// Counts are facts: they never edit movements, quantities or financial
// records, and a variance is reported, never auto-corrected.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:poker_ledger/models/bank_count.dart';
import 'package:poker_ledger/models/chip_movement.dart';
import 'package:poker_ledger/models/chip_type.dart';
import 'package:poker_ledger/services/backup_service.dart';
import 'package:poker_ledger/services/chip_bank_service.dart';
import 'package:poker_ledger/services/chip_tracking_service.dart';
import 'package:poker_ledger/services/hive_service.dart';

import 'test_helper.dart';

late Directory _tmp;

Future<void> _open() async {
  _tmp = await Directory.systemTemp.createTemp('pl_preset_cnt_');
  Hive.init(_tmp.path);
  registerTestAdapters();
  await Hive.openBox(HiveService.sessionsBox);
  await Hive.openBox(HiveService.playersBox);
  await Hive.openBox(HiveService.transactionsBox);
  await Hive.openBox(HiveService.settingsBox);
  await Hive.openBox<ChipType>(HiveService.chipsBox);
  await Hive.openBox<ChipMovement>(HiveService.chipMovementsBox);
  await Hive.openBox<BankCount>(HiveService.bankCountsBox);
}

Future<void> _close() async {
  await Hive.deleteFromDisk();
  if (await _tmp.exists()) await _tmp.delete(recursive: true);
}

Future<String> _chip(double value, int quantity) async {
  final c = await ChipBankService.addChip(value: value, quantity: quantity);
  return c.id;
}

/// A movement with an EXACT timestamp (the service default is "now",
/// which is uncontrollable for boundary tests).
Future<void> _moveAt(
  String chipTypeId,
  int qty,
  ChipLocation from,
  ChipLocation to,
  DateTime at, {
  String reason = ChipMovementReason.buyIn.wire,
}) async {
  final value = ChipBankService.byId(chipTypeId)!.value;
  final m = ChipMovement(
    id: 'm-${DateTime.now().microsecondsSinceEpoch}-${from.encoded}-$to',
    chipTypeId: chipTypeId,
    chipValue: value,
    quantity: qty,
    fromLocation: from.encoded,
    toLocation: to.encoded,
    reason: reason,
    timestamp: at,
  );
  await HiveService.chipMovements.put(m.id, m);
}

Future<BankCount> _count(Map<String, int> counts, DateTime at,
    {String? note}) async {
  final c = BankCount(
    id: 'count-${at.microsecondsSinceEpoch}',
    countedAt: at,
    counts: counts,
    note: note,
  );
  await HiveService.bankCounts.put(c.id, c);
  return c;
}

void main() {
  setUp(_open);
  tearDown(_close);

  test('INVAR: no count sheet — the legacy quantity baseline is unchanged',
      () async {
    final c100 = await _chip(100, 100);
    final c500 = await _chip(500, 10);

    // 10 out, 3 back.
    await _moveAt(c100, 10, ChipLocation.bank, ChipLocation.player('p1'),
        DateTime(2026, 1, 1, 10));
    await _moveAt(c100, 3, ChipLocation.player('p1'), ChipLocation.bank,
        DateTime(2026, 1, 1, 11), reason: ChipMovementReason.cashOut.wire);

    // Exactly the pre-2b formula: quantity + all movements.
    expect(ChipTrackingService.latestBankCount(), isNull);
    expect(ChipTrackingService.quantityAt(ChipLocation.bank, c100), 93);
    expect(ChipTrackingService.quantityAt(ChipLocation.bank, c500), 10);
    expect(ChipTrackingService.startingBankValue(), 100 * 100 + 500 * 10);
    expect(ChipTrackingService.currentBankValue(), 100 * 93 + 500 * 10);
    expect(ChipTrackingService.bankRemainingFraction(),
        closeTo((100 * 93 + 500 * 10) / (100 * 100 + 500 * 10), 1e-12));
  });

  test('count sheet becomes the baseline; only post-count movements apply',
      () async {
    final c100 = await _chip(100, 100);

    await _moveAt(c100, 10, ChipLocation.bank, ChipLocation.player('p1'),
        DateTime(2026, 1, 1, 10));

    // Counted 85 at 12:00 — the ledger said 90, so there is a 5-chip
    // variance. The count is the fact; the variance is NOT corrected.
    await _count({c100: 85}, DateTime(2026, 1, 1, 12));

    expect(ChipTrackingService.quantityAt(ChipLocation.bank, c100), 85);

    // A movement at the EXACT count instant is ambiguous → excluded
    // (documented rule: count again).
    await _moveAt(c100, 2, ChipLocation.bank, ChipLocation.player('p2'),
        DateTime(2026, 1, 1, 12));
    expect(ChipTrackingService.quantityAt(ChipLocation.bank, c100), 85);

    // A movement strictly AFTER the count applies.
    await _moveAt(c100, 3, ChipLocation.bank, ChipLocation.player('p3'),
        DateTime(2026, 1, 1, 13));
    expect(ChipTrackingService.quantityAt(ChipLocation.bank, c100), 82);

    // The pre-count movement (10 chips, 10:00) must NOT apply again on
    // top of the count — it is already inside the counted 85.
    expect(ChipTrackingService.quantityAt(ChipLocation.bank, c100), 82);

    // The baseline value follows the count, not the quantity record.
    expect(ChipTrackingService.startingBankValue(), 85 * 100);

    // The quantity record itself is untouched by the count.
    expect(ChipBankService.byId(c100)!.quantity, 100);
  });

  test('the latest count wins (multiple count sheets)', () async {
    final c100 = await _chip(100, 100);
    await _count({c100: 80}, DateTime(2026, 1, 1, 12));
    await _count({c100: 70}, DateTime(2026, 1, 2, 12));

    expect(ChipTrackingService.quantityAt(ChipLocation.bank, c100), 70);
    expect(ChipTrackingService.startingBankValue(), 70 * 100);
    // Both sheets stay in the box as audit history.
    expect(HiveService.bankCounts.length, 2);
  });

  test('chip types absent from the count are treated as zero in the case',
      () async {
    final c100 = await _chip(100, 100);
    final c500 = await _chip(500, 10);
    await _count({c100: 50}, DateTime(2026, 1, 1, 12));

    // c500 was not in the sheet → the case holds 0 of it until a
    // post-count movement says otherwise.
    expect(ChipTrackingService.quantityAt(ChipLocation.bank, c500), 0);
    await _moveAt(c500, 4, ChipLocation.bank, ChipLocation.player('p1'),
        DateTime(2026, 1, 1, 13));
    expect(ChipTrackingService.quantityAt(ChipLocation.bank, c500), -4);
  });

  test('a count sheet persists across a box close/reopen', () async {
    final c100 = await _chip(100, 100);
    final c = await _count({c100: 60}, DateTime(2026, 1, 1, 12),
        note: 'session opening');

    await Hive.closeBox(HiveService.bankCountsBox);
    await Hive.openBox<BankCount>(HiveService.bankCountsBox);

    final latest = ChipTrackingService.latestBankCount();
    expect(latest, isNotNull);
    expect(latest!.id, c.id);
    expect(latest.counts[c100], 60);
    expect(latest.note, 'session opening');
  });

  test('backup: payload includes bankCounts, v6, imports idempotently',
      () async {
    final c100 = await _chip(100, 100);
    await _count({c100: 55}, DateTime(2026, 1, 1, 12));

    final payload = BackupService.exportPayload();
    expect(payload['formatVersion'], BackupService.formatVersion);
    expect(BackupService.formatVersion, 7);
    final exported = (payload['bankCounts'] as List? ?? []).length;
    expect(exported, 1);

    // Delete locally, then restore from the payload twice — idempotent.
    await HiveService.bankCounts.clear();
    expect(HiveService.bankCounts.length, 0);

    final r1 = await BackupService.importPayload(payload);
    expect(r1.bankCountsImported, 1);
    expect(HiveService.bankCounts.length, 1);

    await HiveService.bankCounts.clear();
    final r2 = await BackupService.importPayload(payload);
    expect(r2.bankCountsImported, 1);
    expect(HiveService.bankCounts.length, 1); // merge, not duplicate
  });

  test('backup: a pre-v6 payload without bankCounts restores safely',
      () async {
    final c100 = await _chip(100, 100);
    await _count({c100: 55}, DateTime(2026, 1, 1, 12));

    final oldStyle = <String, dynamic>{
      'formatVersion': 5,
      'sessions': <dynamic>[],
      'players': <dynamic>[],
      'transactions': <dynamic>[],
      'chips': <dynamic>[],
      'chipMovements': <dynamic>[],
      'playerIdentities': <dynamic>[],
      'financialEvents': <dynamic>[],
      'settings': <String, dynamic>{},
    };
    final r = await BackupService.importPayload(oldStyle);
    expect(r.bankCountsImported, 0);
    // Existing sheets untouched.
    expect(HiveService.bankCounts.length, 1);
  });
}
