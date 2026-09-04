// Focused service tests for the approved J1–J8 operational model.
//
// NO TOOLCHAIN IN THE CURRENT SANDBOX: these files are statically
// reviewed only in the session report, not executed here. They are kept
// as the required regression matrix for the next toolchain-enabled run.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:poker_ledger/models/bank_count.dart';
import 'package:poker_ledger/models/chip_movement.dart';
import 'package:poker_ledger/models/chip_type.dart';
import 'package:poker_ledger/models/enums.dart';
import 'package:poker_ledger/models/financial_event.dart';
import 'package:poker_ledger/models/hand.dart';
import 'package:poker_ledger/models/player.dart';
import 'package:poker_ledger/models/player_identity.dart';
import 'package:poker_ledger/models/session.dart';
import 'package:poker_ledger/models/table_operation_event.dart';
import 'package:poker_ledger/models/table_participation.dart';
import 'package:poker_ledger/models/transaction.dart';
import 'package:poker_ledger/services/backup_service.dart';
import 'package:poker_ledger/services/chip_bank_service.dart';
import 'package:poker_ledger/services/chip_tracking_service.dart';
import 'package:poker_ledger/services/dual_verification_service.dart';
import 'package:poker_ledger/services/financial_ledger_service.dart';
import 'package:poker_ledger/services/hive_service.dart';
import 'package:poker_ledger/services/participation_service.dart';
import 'package:poker_ledger/services/session_service.dart';
import 'package:poker_ledger/services/table_movement_service.dart';
import 'package:poker_ledger/services/table_operation_event_service.dart';
import 'package:poker_ledger/services/table_service.dart';
import 'package:uuid/uuid.dart';
import 'test_helper.dart';

const _uuid = Uuid();
late Directory _tempDir;

Future<void> _openAll() async {
  _tempDir = await Directory.systemTemp.createTemp('poker_ledger_j_test_');
  Hive.init(_tempDir.path);
  registerTestAdapters();
  await Hive.openBox<PokerSession>(HiveService.sessionsBox);
  await Hive.openBox<Player>(HiveService.playersBox);
  await Hive.openBox<LedgerTransaction>(HiveService.transactionsBox);
  await Hive.openBox(HiveService.settingsBox);
  await Hive.openBox<ChipType>(HiveService.chipsBox);
  await Hive.openBox<ChipMovement>(HiveService.chipMovementsBox);
  await Hive.openBox<PlayerIdentity>(HiveService.playerIdentitiesBox);
  await Hive.openBox<FinancialEvent>(HiveService.financialEventsBox);
  await Hive.openBox<BankCount>(HiveService.bankCountsBox);
  await Hive.openBox<TableParticipation>(HiveService.participationsBox);
  await Hive.openBox<Hand>(HiveService.handsBox);
  await Hive.openBox(HiveService.transferEventsBox);
}

Future<void> _closeAll() async {
  await Hive.deleteFromDisk();
  if (await _tempDir.exists()) {
    await _tempDir.delete(recursive: true);
  }
}

PokerSession _session() {
  final s = PokerSession(
    id: _uuid.v4(),
    name: 'J Test',
    location: 'Test Room',
    dateTime: DateTime.now(),
    smallBlind: 1,
    bigBlind: 2,
    tableNumber: '1',
  );
  HiveService.sessions.put(s.id, s);
  return s;
}

Future<Player> _registeredSeat(PokerSession s, {int seat = 1}) async {
  final personId = _uuid.v4();
  final identity = PlayerIdentity(id: personId, displayName: 'Person $seat');
  await HiveService.playerIdentities.put(personId, identity);
  final p = Player(
    id: _uuid.v4(),
    sessionId: s.id,
    name: 'Person $seat',
    seatNumber: seat,
    tableId: 'table-1',
    personId: personId,
  );
  await HiveService.players.put(p.id, p);
  return p;
}

void main() {
  setUp(_openAll);
  tearDown(_closeAll);

  test('J5 identity gate refuses a table transfer for an anonymous seat',
      () async {
    final s = _session();
    final anon = Player(
      id: _uuid.v4(),
      sessionId: s.id,
      name: 'Anonymous',
      seatNumber: 1,
      tableId: 'table-1',
    );
    await HiveService.players.put(anon.id, anon);
    final table2 = await TableService.addTable(s, name: 'Table 2');
    expect(
      () => TableService.movePlayer(
        s,
        anon,
        table2,
        amount: 100,
        hostSignatureBase64: 'host',
      ),
      throwsA(isA<StateError>()),
    );
  });

  test('J5 central gate refuses an anonymous recordTransaction', () async {
    final s = _session();
    final anon = Player(
      id: _uuid.v4(),
      sessionId: s.id,
      name: 'Anonymous',
      seatNumber: 1,
      tableId: 'table-1',
    );
    await HiveService.players.put(anon.id, anon);
    expect(
      () => SessionService.recordTransaction(
        sessionId: s.id,
        playerId: anon.id,
        type: TransactionType.buyIn,
        amount: 100,
        hostSignatureBase64: 'sig',
      ),
      throwsA(isA<StateError>()),
    );
  });

  test('J5 central gate refuses anonymous settle/leave', () async {
    final s = _session();
    final anon = Player(
      id: _uuid.v4(),
      sessionId: s.id,
      name: 'Anonymous',
      seatNumber: 1,
      tableId: 'table-1',
    );
    await HiveService.players.put(anon.id, anon);
    expect(
      () => SessionService.markPlayerSettled(anon, settled: true),
      throwsA(isA<StateError>()),
    );
  });

  test('J5 central gate refuses an anonymous chip movement', () async {
    final s = _session();
    final anon = Player(
      id: _uuid.v4(),
      sessionId: s.id,
      name: 'Anonymous',
      seatNumber: 1,
      tableId: 'table-1',
    );
    await HiveService.players.put(anon.id, anon);
    final chip = await ChipBankService.addChip(value: 100, quantity: 10);
    expect(
      () => ChipTrackingService.record(
        chipTypeId: chip.id,
        quantity: 1,
        from: ChipLocation.bank,
        to: ChipLocation.player(anon.id),
        reason: ChipMovementReason.buyIn,
      ),
      throwsA(isA<StateError>()),
    );
    expect(HiveService.chipMovements.length, 0);
  });

  test('J5 central gate refuses anonymous participation writes', () async {
    final s = _session();
    final anon = Player(
      id: _uuid.v4(),
      sessionId: s.id,
      name: 'Anonymous',
      seatNumber: 1,
      tableId: 'table-1',
    );
    await HiveService.players.put(anon.id, anon);

    expect(
      () => ParticipationService.openOrFind(
        sessionId: s.id,
        seatPlayerId: anon.id,
        tableId: 'table-1',
      ),
      throwsA(isA<StateError>()),
    );

    final legacy = TableParticipation(
      id: _uuid.v4(),
      sessionId: s.id,
      personId: null,
      tableId: 'table-1',
      seatPlayerId: anon.id,
    );
    await HiveService.participations.put(legacy.id, legacy);
    expect(
      () => ParticipationService.close(legacy.id,
          reason: ParticipationCloseReason.sessionEnd),
      throwsA(isA<StateError>()),
    );
    expect(HiveService.participations.get(legacy.id)!.status,
        ParticipationStatus.open);
  });

  test('J5 gate applies to financial ledger reversal', () async {
    final s = _session();
    final p = await _registeredSeat(s);
    final event = await FinancialLedgerService.record(
      personId: p.personId!,
      currency: AppCurrency.usd,
      type: FinancialEventType.cashInForChips,
      amount: 100,
      sessionId: s.id,
    );
    await HiveService.playerIdentities.delete(p.personId!);
    expect(
      () => FinancialLedgerService.reverse(event.id),
      throwsA(isA<FinancialLedgerException>()),
    );
  });

  test('J1/J2/J3/J7 funded transfer validates, writes legs and links event',
      () async {
    final s = _session();
    final p = await _registeredSeat(s);
    final table2 = await TableService.addTable(s, name: 'Table 2');

    // Missing amount must not become zero.
    expect(
      () => TableService.movePlayer(s, p, table2,
          hostSignatureBase64: 'host'),
      throwsA(isA<StateError>()),
    );
    // Missing host confirmation must block.
    expect(
      () => TableService.movePlayer(s, p, table2, amount: 100),
      throwsA(isA<StateError>()),
    );

    await TableService.movePlayer(
      s,
      p,
      table2,
      amount: 100,
      hostSignatureBase64: 'host',
      operatorName: 'Floor',
      reason: 'move',
    );

    final out = SessionService.transactionsFor(s.id)
        .where((t) => t.type == TransactionType.transferOut)
        .toList();
    final inn = SessionService.transactionsFor(s.id)
        .where((t) => t.type == TransactionType.transferIn)
        .toList();
    expect(out, hasLength(1));
    expect(inn, hasLength(1));
    expect(out.single.requiresSignature, isTrue);
    expect(inn.single.requiresSignature, isTrue);

    final events = TableOperationEventService.all()
        .where((e) => e.operation == TableOperationType.tableTransfer)
        .toList();
    expect(events, hasLength(1));
    expect(events.single.transferOutTransactionId, out.single.id);
    expect(events.single.transferInTransactionId, inn.single.id);
    expect(events.single.carriedAmount, 100);
    expect(events.single.dryMove, isFalse);
    expect(events.single.hostSignatureBase64, 'host');

    final sourceOpen = ParticipationService.openFor(
      sessionId: s.id,
      seatPlayerId: p.id,
      tableId: 'table-1',
    );
    final destOpen = ParticipationService.openFor(
      sessionId: s.id,
      seatPlayerId: p.id,
      tableId: table2,
    );
    expect(sourceOpen, isNull);
    expect(destOpen, isNotNull);
  });

  test('J1 explicit Dry Move has no money legs and still needs confirmation',
      () async {
    final s = _session();
    final p = await _registeredSeat(s);
    final table2 = await TableService.addTable(s, name: 'Table 2');
    await TableService.movePlayer(
      s,
      p,
      table2,
      amount: 0,
      dryMove: true,
      hostSignatureBase64: 'host',
    );

    expect(
      SessionService.transactionsFor(s.id)
          .where((t) => t.type == TransactionType.transferOut),
      isEmpty,
    );
    expect(
      SessionService.transactionsFor(s.id)
          .where((t) => t.type == TransactionType.transferIn),
      isEmpty,
    );
    final events = TableOperationEventService.all()
        .where((e) => e.operation == TableOperationType.tableTransfer);
    expect(events.single.dryMove, isTrue);
    expect(events.single.carriedAmount, 0);
  });

  test('J4 incompatible tables are blocked', () async {
    final s = _session();
    final p = await _registeredSeat(s);
    final table2 = await TableService.addTable(
      s,
      name: 'Table 2',
      smallStake: 2,
      bigStake: 5,
    );
    expect(
      () => TableService.movePlayer(
        s,
        p,
        table2,
        amount: 100,
        hostSignatureBase64: 'host',
      ),
      throwsA(isA<StateError>()),
    );
  });

  test('J5 temporary absence is non-financial and preserves the seat',
      () async {
    final s = _session();
    final p = await _registeredSeat(s);
    await TableMovementService.startTemporaryAbsence(s, p);
    await TableMovementService.endTemporaryAbsence(s, p);

    expect(p.seated, isTrue);
    expect(p.tableId, 'table-1');
    expect(p.seatNumber, 1);
    expect(SessionService.transactionsFor(s.id), isEmpty);
    final ops = TableOperationEventService.all().map((e) => e.operation);
    expect(ops, contains(TableOperationType.temporaryAbsence));
    expect(ops, contains(TableOperationType.returnFromAbsence));
  });

  test('J6 unseat is distinct from cash-out: no money leg, held event',
      () async {
    final s = _session();
    final p = await _registeredSeat(s);
    await TableMovementService.unseat(
      session: s,
      player: p,
      heldByFloor: true,
      heldAmount: 50,
      reason: 'left table',
    );
    expect(p.seated, isFalse);
    expect(p.tableId, isNull);
    expect(SessionService.transactionsFor(s.id), isEmpty);
    final ops = TableOperationEventService.all().map((e) => e.operation);
    expect(ops, contains(TableOperationType.unseat));
    expect(ops, contains(TableOperationType.heldChips));
  });

  test('J9 same-table seat change is non-financial', () async {
    final s = _session();
    final p = await _registeredSeat(s);
    await TableMovementService.changeSeat(s, p, 3);
    expect(p.seatNumber, 3);
    expect(SessionService.transactionsFor(s.id), isEmpty);
    final op = TableOperationEventService.all().where(
        (e) => e.operation == TableOperationType.seatChange);
    expect(op.single.sourceSeat, 1);
    expect(op.single.destinationSeat, 3);
  });

  test('J8 configurable threshold records a second-authorisation event',
      () async {
    final s = _session();
    final p = await _registeredSeat(s);
    await DualVerificationService.configure(enabled: true, threshold: 1000);
    expect(DualVerificationService.requiresSecond(1000), isTrue);
    expect(DualVerificationService.requiresSecond(999), isFalse);

    await SessionService.recordTransaction(
      sessionId: s.id,
      playerId: p.id,
      type: TransactionType.buyIn,
      amount: 1000,
      hostSignatureBase64: 'host',
      secondVerifierName: 'CFO',
      secondVerifierSignature: 'second',
    );

    final events = TableOperationEventService.all()
        .where((e) => e.operation == TableOperationType.dualVerification)
        .toList();
    expect(events, hasLength(1));
    expect(events.single.secondVerifierName, 'CFO');
    expect(events.single.secondVerifierSignature, 'second');
    expect(events.single.hostSignatureBase64, 'host');

    await DualVerificationService.clearThreshold();
    await DualVerificationService.configure(enabled: false);
  });

  test('J8 missing second signature is refused when above threshold',
      () async {
    final s = _session();
    final p = await _registeredSeat(s);
    await DualVerificationService.configure(enabled: true, threshold: 1000);
    expect(
      () => SessionService.recordTransaction(
        sessionId: s.id,
        playerId: p.id,
        type: TransactionType.rebuy,
        amount: 1500,
        hostSignatureBase64: 'host',
      ),
      throwsA(isA<StateError>()),
    );
    await DualVerificationService.clearThreshold();
    await DualVerificationService.configure(enabled: false);
  });

  test('J8 missing second verifier name is refused when above threshold',
      () async {
    final s = _session();
    final p = await _registeredSeat(s);
    await DualVerificationService.configure(enabled: true, threshold: 1000);
    expect(
      () => SessionService.recordTransaction(
        sessionId: s.id,
        playerId: p.id,
        type: TransactionType.rebuy,
        amount: 1500,
        hostSignatureBase64: 'host',
        secondVerifierSignature: 'second',
      ),
      throwsA(isA<StateError>()),
    );
    await DualVerificationService.clearThreshold();
    await DualVerificationService.configure(enabled: false);
  });

  test('backup v9 preserves transfer events and a v8 payload restores',
      () async {
    final s = _session();
    final p = await _registeredSeat(s);
    await TableMovementService.changeSeat(s, p, 2);

    final payload = BackupService.exportPayload();
    expect(payload['formatVersion'], 9);
    expect(payload['transferEvents'] as List, isNotEmpty);

    final oldPayload = Map<String, dynamic>.from(payload);
    oldPayload['formatVersion'] = 8;
    oldPayload.remove('transferEvents');
    final res = await BackupService.importPayload(oldPayload);
    expect(res.formatVersion, 8);
    expect(res.transferEventsImported, 0);

    final fresh = await BackupService.importPayload(payload);
    expect(fresh.transferEventsImported,
        TableOperationEventService.all().length);
  });
}
