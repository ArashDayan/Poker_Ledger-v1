// Phase 6 — table participation.
//
// A participation is the lifecycle of one person's commitment of
// chips/money to one table in one session (P-1: identity + lifecycle
// ONLY — money is derived from the linked transactions). It opens on
// the first money leg, exactly one open per (person-or-seat, table,
// session), closes on transfer-out / table-cash-out (Phase 7) /
// session end. Unlinked legacy seats get seat-scoped participations
// (no identity is ever invented).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:poker_ledger/models/enums.dart';
import 'package:poker_ledger/models/player.dart';
import 'package:poker_ledger/models/player_identity.dart';
import 'package:poker_ledger/models/session.dart';
import 'package:poker_ledger/models/table_participation.dart';
import 'package:poker_ledger/models/transaction.dart';
import 'package:poker_ledger/services/hive_service.dart';
import 'package:poker_ledger/services/participation_service.dart';
import 'package:poker_ledger/services/player_identity_service.dart';
import 'package:poker_ledger/services/session_service.dart';
import 'package:poker_ledger/services/table_service.dart';
import 'package:poker_ledger/services/wallet_service.dart';

import 'test_helper.dart';

late Directory _tmp;

Future<void> _open() async {
  _tmp = await Directory.systemTemp.createTemp('pl_preset_par_');
  Hive.init(_tmp.path);
  registerTestAdapters();
  await Hive.openBox<PokerSession>(HiveService.sessionsBox);
  await Hive.openBox<Player>(HiveService.playersBox);
  await Hive.openBox<LedgerTransaction>(HiveService.transactionsBox);
  await Hive.openBox(HiveService.settingsBox);
  await Hive.openBox<PlayerIdentity>(HiveService.playerIdentitiesBox);
  await Hive.openBox<TableParticipation>(HiveService.participationsBox);
  await Hive.openBox(HiveService.transferEventsBox);
}

/// No participations box: the degraded mode must not break money.
Future<void> _openNoPartBox() async {
  _tmp = await Directory.systemTemp.createTemp('pl_preset_parx_');
  Hive.init(_tmp.path);
  registerTestAdapters();
  await Hive.openBox<PokerSession>(HiveService.sessionsBox);
  await Hive.openBox<Player>(HiveService.playersBox);
  await Hive.openBox<LedgerTransaction>(HiveService.transactionsBox);
  await Hive.openBox(HiveService.settingsBox);
  await Hive.openBox<PlayerIdentity>(HiveService.playerIdentitiesBox);
  await Hive.openBox(HiveService.transferEventsBox);
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
  final linkedPersonId = personId ?? await _person(name);
  final p = Player(
    id: 'seat-${name.toLowerCase()}-$seatNo',
    sessionId: s.id,
    name: name,
    seatNumber: seatNo,
    tableId: tables[table - 1].id,
    personId: linkedPersonId,
  );
  await HiveService.players.put(p.id, p);
  return p;
}

void main() {
  setUp(_open);
  tearDown(_close);

  test('a buy-in opens a participation; the leg is stamped', () async {
    final s = await _session('s1');
    final pid = await _person('Ali');
    final seat = await _seat(s, 'Ali', 1, personId: pid);
    final tableId = TableService.tablesFor(s).first.id;

    final tx = await SessionService.recordTransaction(
      sessionId: s.id,
      playerId: seat.id,
      type: TransactionType.buyIn,
      amount: 1000,
      hostSignatureBase64: 'sig',
    );

    expect(tx.participationId, isNotNull);
    final p = HiveService.participations.get(tx.participationId!);
    expect(p, isNotNull);
    expect(p!.isOpen, isTrue);
    expect(p.personId, pid);
    expect(p.seatPlayerId, seat.id);
    expect(p.tableId, tableId);
    expect(p.sessionId, s.id);

    // P-1: the legs are derived from the linked transactions.
    final legs = ParticipationService.legsFor(p.id);
    expect(legs.moneyIn, 1000);
    expect(legs.moneyOut, 0);
    expect(legs.legCount, 1);
  });

  test('a rebuy joins the SAME participation (P-1: one open)', () async {
    final s = await _session('s1');
    final pid = await _person('Ali');
    final seat = await _seat(s, 'Ali', 1, personId: pid);

    await SessionService.recordTransaction(
      sessionId: s.id,
      playerId: seat.id,
      type: TransactionType.buyIn,
      amount: 1000,
      hostSignatureBase64: 'sig',
    );
    final rebuy = await SessionService.recordTransaction(
      sessionId: s.id,
      playerId: seat.id,
      type: TransactionType.rebuy,
      amount: 500,
      hostSignatureBase64: 'sig',
    );

    final parts = ParticipationService.forSession(s.id);
    expect(parts, hasLength(1)); // one open, not two
    expect(rebuy.participationId, parts.single.id);
    expect(ParticipationService.legsFor(parts.single.id).moneyIn, 1500);
  });

  test('a second person at the same table gets a separate participation',
      () async {
    final s = await _session('s1');
    final pidA = await _person('Ali');
    final pidB = await _person('Reza');
    final a = await _seat(s, 'Ali', 1, personId: pidA);
    final b = await _seat(s, 'Reza', 2, personId: pidB);

    await SessionService.recordTransaction(
      sessionId: s.id,
      playerId: a.id,
      type: TransactionType.buyIn,
      amount: 1000,
      hostSignatureBase64: 'sig',
    );
    await SessionService.recordTransaction(
      sessionId: s.id,
      playerId: b.id,
      type: TransactionType.buyIn,
      amount: 800,
      hostSignatureBase64: 'sig',
    );

    final parts = ParticipationService.forSession(s.id);
    expect(parts, hasLength(2));
    expect(
        parts.map((p) => p.personId).toSet(), {pidA, pidB});
  });

  test('a registered person gets a person-scoped participation',
      () async {
    final s = await _session('s1');
    // J5: the seat is linked to the registered Player Master created by
    // the fixture helper — an unlinked anonymous seat is refused by the
    // central gate instead of getting a legacy seat-scoped overlay.
    final seat = await _seat(s, 'Mystery', 1);

    final tx = await SessionService.recordTransaction(
      sessionId: s.id,
      playerId: seat.id,
      type: TransactionType.buyIn,
      amount: 300,
      hostSignatureBase64: 'sig',
    );

    expect(tx.participationId, isNotNull);
    final p = HiveService.participations.get(tx.participationId!);
    expect(p!.personId, seat.personId); // real identity, never invented
    expect(p.isOpen, isTrue);
  });

  test('a cash-out stamps the open participation (no new one)', () async {
    final s = await _session('s1');
    final pid = await _person('Ali');
    final seat = await _seat(s, 'Ali', 1, personId: pid);

    await SessionService.recordTransaction(
      sessionId: s.id,
      playerId: seat.id,
      type: TransactionType.buyIn,
      amount: 1000,
      hostSignatureBase64: 'sig',
    );
    final cashOut = await SessionService.recordTransaction(
      sessionId: s.id,
      playerId: seat.id,
      type: TransactionType.cashOut,
      amount: 1200,
      hostSignatureBase64: 'sig',
    );

    final parts = ParticipationService.forSession(s.id);
    expect(parts, hasLength(1));
    expect(cashOut.participationId, parts.single.id);
    final legs = ParticipationService.legsFor(parts.single.id);
    expect(legs.moneyIn, 1000);
    expect(legs.moneyOut, 1200);
    expect(legs.net, -200);
  });

  test('table rows (rake) are never stamped', () async {
    final s = await _session('s1');
    final tableId = TableService.tablesFor(s).first.id;

    final rake = await SessionService.recordTransaction(
      sessionId: s.id,
      type: TransactionType.rakeCollection,
      amount: 50,
      tableId: tableId,
    );
    expect(rake.participationId, isNull);
    expect(HiveService.participations.length, 0);
  });

  test('a funded move closes the source, opens the destination',
      () async {
    final s = await _session('s1', tables: 2);
    final pid = await _person('Ali');
    final seat = await _seat(s, 'Ali', 1, personId: pid);
    final tables = TableService.tablesFor(s);

    await SessionService.recordTransaction(
      sessionId: s.id,
      playerId: seat.id,
      type: TransactionType.buyIn,
      amount: 1000,
      hostSignatureBase64: 'sig',
    );
    expect(ParticipationService.forSession(s.id), hasLength(1));

    await TableService.movePlayer(s, seat, tables[1].id,
        amount: 500, hostSignatureBase64: 'sig');

    final parts = ParticipationService.forSession(s.id);
    expect(parts, hasLength(2));
    final source = parts.singleWhere((p) => p.tableId == tables[0].id);
    final dest = parts.singleWhere((p) => p.tableId == tables[1].id);

    // Source: closed by the transfer-out, whose leg is stamped.
    expect(source.isOpen, isFalse);
    expect(source.closeReason, ParticipationCloseReason.transferOut);
    expect(source.closedAt, isNotNull);
    // Destination: open, opened by the transfer-in.
    expect(dest.isOpen, isTrue);
    expect(dest.personId, pid);

    // Derived legs follow the money.
    expect(ParticipationService.legsFor(source.id).moneyOut, 500);
    expect(ParticipationService.legsFor(source.id).moneyIn, 1000);
    expect(ParticipationService.legsFor(dest.id).moneyIn, 500);
  });

  test('a dry move moves the commitment, no legs, no new participation',
      () async {
    final s = await _session('s1', tables: 2);
    final pid = await _person('Ali');
    final seat = await _seat(s, 'Ali', 1, personId: pid);
    final tables = TableService.tablesFor(s);

    await SessionService.recordTransaction(
      sessionId: s.id,
      playerId: seat.id,
      type: TransactionType.buyIn,
      amount: 1000,
      hostSignatureBase64: 'sig',
    );
    final openId =
        ParticipationService.forSession(s.id).single.id;

    await TableService.movePlayer(s, seat, tables[1].id,
        amount: 0, dryMove: true, hostSignatureBase64: 'sig'); // explicit dry

    final parts = ParticipationService.forSession(s.id);
    expect(parts, hasLength(1)); // the same participation...
    expect(parts.single.id, openId);
    expect(parts.single.isOpen, isTrue);
    expect(parts.single.tableId, tables[1].id); // ...followed the seat
    // No transfer legs were written.
    expect(
        SessionService.transactionsFor(s.id).any((t) =>
            t.type == TransactionType.transferOut ||
            t.type == TransactionType.transferIn),
        isFalse);
  });

  test('session end closes every open participation (sessionEnd)',
      () async {
    final s = await _session('s1');
    final pidA = await _person('Ali');
    final pidB = await _person('Reza');
    final a = await _seat(s, 'Ali', 1, personId: pidA);
    final b = await _seat(s, 'Reza', 2, personId: pidB);
    await SessionService.recordTransaction(
      sessionId: s.id,
      playerId: a.id,
      type: TransactionType.buyIn,
      amount: 1000,
      hostSignatureBase64: 'sig',
    );
    await SessionService.recordTransaction(
      sessionId: s.id,
      playerId: b.id,
      type: TransactionType.buyIn,
      amount: 800,
      hostSignatureBase64: 'sig',
    );

    final closed = ParticipationService.closeOpenAtSessionEnd(s.id);
    expect(closed, 2);
    for (final p in ParticipationService.forSession(s.id)) {
      expect(p.isOpen, isFalse);
      expect(p.closeReason, ParticipationCloseReason.sessionEnd);
    }
    // Idempotent: a second pass closes nothing.
    expect(ParticipationService.closeOpenAtSessionEnd(s.id), 0);
  });

  test('the wallet exposes open commitments (Phase 3 integration)',
      () async {
    final s = await _session('s1');
    final pid = await _person('Ali');
    final seat = await _seat(s, 'Ali', 1, personId: pid);

    expect(WalletService.walletFor(pid).openParticipationCount, 0);

    await SessionService.recordTransaction(
      sessionId: s.id,
      playerId: seat.id,
      type: TransactionType.buyIn,
      amount: 1000,
      hostSignatureBase64: 'sig',
    );
    var w = WalletService.walletFor(pid);
    expect(w.openParticipationCount, 1);
    expect(w.openParticipations.single.tableId,
        TableService.tablesFor(s).first.id);

    ParticipationService.close(w.openParticipations.single.id,
        reason: ParticipationCloseReason.sessionEnd);
    w = WalletService.walletFor(pid);
    expect(w.openParticipationCount, 0);
  });

  test('P-1: settlement is derived from transactions, not participations',
      () async {
    final s = await _session('s1');
    final pid = await _person('Ali');
    final seat = await _seat(s, 'Ali', 1, personId: pid);

    await SessionService.recordTransaction(
      sessionId: s.id,
      playerId: seat.id,
      type: TransactionType.buyIn,
      amount: 1000,
      hostSignatureBase64: 'sig',
    );

    // The participation exists, but the settlement math is the same
    // transaction sums as before Phase 6.
    expect(ParticipationService.forSession(s.id), hasLength(1));
    final b = SessionService.checkBalance(s.id);
    expect(b.moneyIn, 1000);
    expect(b.moneyOut, 0);
    expect(SessionService.playerTotalIn(s.id, seat.id), 1000);
    expect(SessionService.playerProfitLoss(s.id, seat.id), -1000);
  });

  test('voided legs are excluded from derived participation legs',
      () async {
    final s = await _session('s1');
    final pid = await _person('Ali');
    final seat = await _seat(s, 'Ali', 1, personId: pid);

    final buyIn = await SessionService.recordTransaction(
      sessionId: s.id,
      playerId: seat.id,
      type: TransactionType.buyIn,
      amount: 1000,
      hostSignatureBase64: 'sig',
    );
    final rebuy = await SessionService.recordTransaction(
      sessionId: s.id,
      playerId: seat.id,
      type: TransactionType.rebuy,
      amount: 500,
      hostSignatureBase64: 'sig',
    );
    await SessionService.voidTransaction(rebuy.id);

    final legs = ParticipationService.legsFor(buyIn.participationId!);
    expect(legs.moneyIn, 1000); // the voided rebuy is excluded
    expect(legs.legCount, 1);
  });

  test('degraded mode: no participations box never breaks money',
      () async {
    await _close(); // Close boxes opened by setUp
    await _openNoPartBox();
    final s = await _session('s1');
    final seat = await _seat(s, 'Ali', 1);

    final tx = await SessionService.recordTransaction(
      sessionId: s.id,
      playerId: seat.id,
      type: TransactionType.buyIn,
      amount: 1000,
      hostSignatureBase64: 'sig',
    );

    // The money leg is recorded; the tracking overlay is a no-op.
    expect(tx.participationId, isNull);
    expect(SessionService.playerTotalIn(s.id, seat.id), 1000);
    expect(ParticipationService.legsFor('anything').legCount, 0);
  });
}
