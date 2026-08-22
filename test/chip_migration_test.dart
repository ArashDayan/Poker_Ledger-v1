// Phase 2a — converging seat→person chip-reference migration.
//
// Asserts the safety contract:
//   * linked seats are re-keyed, original references preserved on the
//     record (audit), case fold provably unchanged;
//   * unlinked seats are NEVER re-keyed, never invented, only
//     reported;
//   * idempotent, crash-safe, converging (downgrade-written rows are
//     picked up by the next pass);
//   * first run attempts a pre-migration backup (in a bare test
//     environment the platform path is unavailable — the failure must
//     be a reported, NON-FATAL warning, and the pass must still
//     complete);
//   * the version key and the stored report are persisted.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:poker_ledger/models/chip_movement.dart';
import 'package:poker_ledger/models/chip_type.dart';
import 'package:poker_ledger/models/player.dart';
import 'package:poker_ledger/models/player_identity.dart';
import 'package:poker_ledger/models/session.dart';
import 'package:poker_ledger/models/transaction.dart';
import 'package:poker_ledger/services/chip_migration.dart';
import 'package:poker_ledger/services/chip_tracking_service.dart';
import 'package:poker_ledger/services/hive_service.dart';
import 'package:poker_ledger/services/player_identity_service.dart';

import 'test_helper.dart';

late Directory _tmp;

Future<void> _open() async {
  _tmp = await Directory.systemTemp.createTemp('pl_preset_mig_');
  Hive.init(_tmp.path);
  registerTestAdapters();
  await Hive.openBox<PokerSession>(HiveService.sessionsBox);
  await Hive.openBox<Player>(HiveService.playersBox);
  await Hive.openBox<LedgerTransaction>(HiveService.transactionsBox);
  await Hive.openBox(HiveService.settingsBox);
  await Hive.openBox<PlayerIdentity>(HiveService.playerIdentitiesBox);
  await Hive.openBox<ChipType>(HiveService.chipsBox);
  await Hive.openBox<ChipMovement>(HiveService.chipMovementsBox);
}

Future<void> _close() async {
  await Hive.deleteFromDisk();
  if (await _tmp.exists()) await _tmp.delete(recursive: true);
}

/// Per-denomination total across ALL locations — the conservation
/// figure the migration must never change.
Map<String, int> _conservation() {
  final totals = <String, int>{};
  for (final m in HiveService.chipMovements.values) {
    totals[m.chipTypeId] = (totals[m.chipTypeId] ?? 0) + m.quantity;
  }
  return totals;
}

/// Bank-derived quantity for a chip type (what the case fold shows).
int _bankQty(String chipTypeId) =>
    ChipTrackingService.quantityAt(ChipLocation.bank, chipTypeId);

Future<String> _chip(double value, int quantity) async {
  final c = ChipType(value: value, quantity: quantity);
  await HiveService.chips.put(c.id, c);
  return c.id;
}

Future<void> _session() async {
  final s = PokerSession(
    id: 's1',
    name: 'Fri',
    location: 'Home',
    dateTime: DateTime.now(),
    smallBlind: 1,
    bigBlind: 2,
    tableNumber: '1',
  );
  await HiveService.sessions.put(s.id, s);
}

Future<String> _seat({
  required String name,
  String? personId,
  bool seated = true,
}) async {
  final p = Player(
    id: 'seat-${name.hashCode}',
    sessionId: 's1',
    name: name,
    seatNumber: 1,
    personId: personId,
    seated: seated,
  );
  await HiveService.players.put(p.id, p);
  return p.id;
}

void main() {
  setUp(_open);
  tearDown(_close);

  test('linked seat re-keyed, legacy refs preserved, case fold unchanged',
      () async {
    await _session();
    final pid = (await PlayerIdentityService.createNew('Ali'))!.id;
    final seat = await _seat(name: 'Ali', personId: pid);
    final c100 = await _chip(100, 500);

    await ChipTrackingService.record(
      chipTypeId: c100,
      quantity: 10,
      from: ChipLocation.bank,
      to: ChipLocation.player(seat),
      reason: ChipMovementReason.buyIn,
      sessionId: 's1',
    );

    final bankBefore = _bankQty(c100);
    final consBefore = _conservation();

    final report = await ChipMigration.run();

    final m = HiveService.chipMovements.values.first;
    expect(m.toLocation, 'player:$pid');
    expect(m.fromLocation, 'bank');
    expect(m.legacyTo, 'player:$seat'); // original reference preserved
    expect(m.legacyFrom, null); // bank side was never a seat

    expect(report.rekeyedThisRun, 1);
    expect(report.totalRekeyed, 1);
    expect(report.error, isNull);
    // Case fold + conservation untouched.
    expect(_bankQty(c100), bankBefore);
    expect(_conservation(), consBefore);
    // Version key persisted; in-progress marker cleared.
    expect(HiveService.settings.get(ChipMigration.versionKey),
        ChipMigration.currentVersion);
    expect(HiveService.settings.get(ChipMigration.inProgressKey), isNot(true));
    // Bare test environment: no platform document path — the backup
    // attempt fails and MUST be a non-fatal warning.
    expect(report.backupWarning, isNotNull);
  });

  test('unlinked seat is never re-keyed and is reported, not invented',
      () async {
    await _session();
    final seat = await _seat(name: 'Reza'); // no personId
    final c100 = await _chip(100, 500);
    await ChipTrackingService.record(
      chipTypeId: c100,
      quantity: 5,
      from: ChipLocation.bank,
      to: ChipLocation.player(seat),
      reason: ChipMovementReason.buyIn,
      sessionId: 's1',
    );

    final report = await ChipMigration.run();

    final m = HiveService.chipMovements.values.first;
    expect(m.toLocation, 'player:$seat'); // untouched
    expect(m.legacyTo, isNull);
    expect(report.rekeyedThisRun, 0);
    expect(report.unmigrated, hasLength(1));
    expect(report.unmigrated.first.name, 'Reza');
    expect(report.unmigrated.first.movementCount, 1);
    expect(report.unmigrated.first.totalValue, 500);
    // No identity was invented.
    expect(PlayerIdentityService.all(), isEmpty);
  });

  test('second run is a no-op (idempotency)', () async {
    await _session();
    final pid = (await PlayerIdentityService.createNew('Ali'))!.id;
    final seat = await _seat(name: 'Ali', personId: pid);
    final c100 = await _chip(100, 500);
    await ChipTrackingService.record(
      chipTypeId: c100,
      quantity: 3,
      from: ChipLocation.bank,
      to: ChipLocation.player(seat),
      reason: ChipMovementReason.buyIn,
      sessionId: 's1',
    );

    final first = await ChipMigration.run();
    final m = HiveService.chipMovements.values.first;
    expect(first.rekeyedThisRun, 1);

    final second = await ChipMigration.run();
    expect(second.rekeyedThisRun, 0);
    expect(second.totalRekeyed, 1);
    expect(m.toLocation, 'player:$pid');
    expect(m.legacyTo, 'player:$seat'); // unchanged by re-run
  });

  test('crashed pass is detected and completed on the next run', () async {
    await _session();
    final pid = (await PlayerIdentityService.createNew('Ali'))!.id;
    final seat = await _seat(name: 'Ali', personId: pid);
    final c100 = await _chip(100, 500);
    await ChipTrackingService.record(
      chipTypeId: c100,
      quantity: 2,
      from: ChipLocation.bank,
      to: ChipLocation.player(seat),
      reason: ChipMovementReason.buyIn,
      sessionId: 's1',
    );

    await ChipMigration.run();
    // Simulate a crash leaving the marker set.
    HiveService.settings.put(ChipMigration.inProgressKey, true);
    expect(ChipMigration.interruptedRunPending, isTrue);

    final report = await ChipMigration.run();
    expect(report.recoveredFromInterruptedRun, isTrue);
    expect(report.error, isNull);
    expect(HiveService.settings.get(ChipMigration.inProgressKey), isNot(true));
  });

  test('converging: seat-scoped rows written after migration are picked up',
      () async {
    await _session();
    final pid = (await PlayerIdentityService.createNew('Ali'))!.id;
    final seat = await _seat(name: 'Ali', personId: pid);
    final c100 = await _chip(100, 500);
    await ChipTrackingService.record(
      chipTypeId: c100,
      quantity: 1,
      from: ChipLocation.bank,
      to: ChipLocation.player(seat),
      reason: ChipMovementReason.buyIn,
      sessionId: 's1',
    );
    await ChipMigration.run();

    // Simulates an older app version writing a fresh seat-scoped row
    // (downgrade-and-re-upgrade path).
    await ChipTrackingService.record(
      chipTypeId: c100,
      quantity: 4,
      from: ChipLocation.player(seat),
      to: ChipLocation.bank,
      reason: ChipMovementReason.cashOut,
      sessionId: 's1',
    );
    expect(ChipMigration.hasUnmigratedLegacy, isFalse); // linked seat
    final report = await ChipMigration.run();
    expect(report.rekeyedThisRun, 1);
    final moved = HiveService.chipMovements.values
        .where((m) => m.reason == ChipMovementReason.cashOut.wire)
        .single;
    expect(moved.fromLocation, 'player:$pid');
    expect(moved.legacyFrom, 'player:$seat');
  });

  test('person-scoped rows and unseated registrations are untouched',
      () async {
    await _session();
    final c100 = await _chip(100, 500);
    // Already person-scoped (ref not in the players box): must stay.
    await ChipTrackingService.record(
      chipTypeId: c100,
      quantity: 1,
      from: ChipLocation.bank,
      to: ChipLocation.player('person-abc'),
      reason: ChipMovementReason.buyIn,
      sessionId: 's1',
    );
    // Phase 1 unseated registration (linked, no movements).
    final pid = (await PlayerIdentityService.createNew('Nina'))!.id;
    await _seat(name: 'Nina', personId: pid, seated: false);

    final report = await ChipMigration.run();
    expect(report.rekeyedThisRun, 0);
    final m = HiveService.chipMovements.values.first;
    expect(m.toLocation, 'player:person-abc');
    expect(m.legacyTo, isNull);
    expect(report.unmigrated, isEmpty);
  });

  test('mixed one-sided re-key keeps only the moved side as legacy',
      () async {
    await _session();
    final pid = (await PlayerIdentityService.createNew('Ali'))!.id;
    final seat = await _seat(name: 'Ali', personId: pid);
    final c100 = await _chip(100, 500);
    // bank → seat: only the destination is a seat.
    await ChipTrackingService.record(
      chipTypeId: c100,
      quantity: 1,
      from: ChipLocation.bank,
      to: ChipLocation.player(seat),
      reason: ChipMovementReason.buyIn,
      sessionId: 's1',
    );
    // seat → person-x: only the source is a seat (x unlinked elsewhere).
    await ChipTrackingService.record(
      chipTypeId: c100,
      quantity: 1,
      from: ChipLocation.player(seat),
      to: ChipLocation.player('person-x'),
      reason: ChipMovementReason.exchange,
      sessionId: 's1',
    );

    await ChipMigration.run();

    final first = HiveService.chipMovements.values
        .firstWhere((m) => m.reason == ChipMovementReason.buyIn.wire);
    expect(first.toLocation, 'player:$pid');
    expect(first.legacyTo, 'player:$seat');
    expect(first.legacyFrom, isNull);

    final second = HiveService.chipMovements.values
        .firstWhere((m) => m.reason == ChipMovementReason.exchange.wire);
    expect(second.fromLocation, 'player:$pid');
    expect(second.legacyFrom, 'player:$seat');
    expect(second.legacyTo, isNull);
    // person-x (unknown ref) is never touched.
    expect(second.toLocation, 'player:person-x');
  });

  test('stored report persists and is re-derivable', () async {
    await _session();
    final pid = (await PlayerIdentityService.createNew('Ali'))!.id;
    final seat = await _seat(name: 'Ali', personId: pid);
    final c100 = await _chip(100, 500);
    await ChipTrackingService.record(
      chipTypeId: c100,
      quantity: 2,
      from: ChipLocation.bank,
      to: ChipLocation.player(seat),
      reason: ChipMovementReason.buyIn,
      sessionId: 's1',
    );
    await ChipMigration.run();

    final stored = ChipMigration.storedReport();
    expect(stored, isNotNull);
    expect(stored!.totalRekeyed, 1);
    expect(stored.error, isNull);
    // Live re-derivation agrees with the stored report.
    expect(ChipMigration.unmigratedSeats().length, stored.unmigrated.length);
  });
}
