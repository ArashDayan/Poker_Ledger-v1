// Phase 4 — wallet chip issuance (seat-free).
//
// The cage issues chips from a deposit draw directly into the
// PERSON's holding: no seat, no table, no session required
// (session-optional, C-1), no LedgerTransaction, no P2P. The deposit
// is the funding source (the draw cannot exceed it); the banker
// signature is recorded on both financial events (audit); the
// composition cannot exceed bank holdings.
//
// Continuity: a wallet-issued person later sits and buys in with the
// chips already in hand — no second chip movement.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:poker_ledger/models/chip_movement.dart';
import 'package:poker_ledger/models/chip_type.dart';
import 'package:poker_ledger/models/enums.dart';
import 'package:poker_ledger/models/financial_event.dart';
import 'package:poker_ledger/models/player.dart';
import 'package:poker_ledger/models/player_identity.dart';
import 'package:poker_ledger/models/session.dart';
import 'package:poker_ledger/models/transaction.dart';
import 'package:poker_ledger/services/chip_bank_service.dart';
import 'package:poker_ledger/services/chip_tracking_service.dart';
import 'package:poker_ledger/services/deposit_to_chips.dart';
import 'package:poker_ledger/services/financial_ledger_service.dart';
import 'package:poker_ledger/services/hive_service.dart';
import 'package:poker_ledger/services/player_identity_service.dart';
import 'package:poker_ledger/services/session_service.dart';
import 'package:poker_ledger/services/wallet_service.dart';

import 'test_helper.dart';

late Directory _tmp;

Future<void> _open() async {
  _tmp = await Directory.systemTemp.createTemp('pl_preset_iss_');
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
}

Future<void> _close() async {
  await Hive.deleteFromDisk();
  if (await _tmp.exists()) await _tmp.delete(recursive: true);
}

Future<String> _person(String name) async =>
    (await PlayerIdentityService.createNew(name))!.id;

Future<void> _deposit(String personId, double amount,
    {AppCurrency currency = AppCurrency.usd}) async {
  await FinancialLedgerService.record(
    personId: personId,
    currency: currency,
    type: FinancialEventType.frontMoneyIn,
    amount: amount,
  );
}

void main() {
  setUp(_open);
  tearDown(_close);

  test('write set: the pair + person-scoped movements, no transaction',
      () async {
    final pid = await _person('Ali');
    await _deposit(pid, 10000);
    final c500 = await ChipBankService.addChip(value: 500, quantity: 10);
    final c100 = await ChipBankService.addChip(value: 100, quantity: 50);

    final result = await DepositToChips.issueToWallet(
      personId: pid,
      currency: AppCurrency.usd,
      amount: 1000,
      composition: {c500.id: 1, c100.id: 5},
      hostSignatureBase64: 'SIG',
    );

    // The financial pair: person-scoped, signed, session-optional.
    expect(result.frontMoneyOut.type, FinancialEventType.frontMoneyOut);
    expect(result.frontMoneyOut.amountMajor, 1000);
    expect(result.frontMoneyOut.personId, pid);
    expect(result.frontMoneyOut.sessionId, isNull);
    expect(result.frontMoneyOut.signatureBase64, 'SIG');
    expect(result.frontMoneyOut.linkedTransactionId, isNull);
    expect(result.cashInForChips.type, FinancialEventType.cashInForChips);
    expect(result.cashInForChips.personId, pid);
    expect(result.cashInForChips.signatureBase64, 'SIG');

    // No money transaction: no seat, no table, no participation.
    expect(HiveService.transactions.length, 0);

    // The physical chips: bank -> the PERSON (personId, never a seat),
    // reason depositIssuance, no P2P.
    final movements = HiveService.chipMovements.values.toList();
    expect(movements.length, 2);
    for (final m in movements) {
      expect(m.fromLocation, ChipLocation.bank.encoded);
      expect(m.toLocation, 'player:$pid');
      expect(m.reason, ChipMovementReason.depositIssuance.wire);
    }

    // The wallet moved exactly by the draw (W-2: available = deposit).
    final w = WalletService.walletFor(pid);
    final p = w.positionFor(AppCurrency.usd)!;
    expect(p.depositHeld, 9000);
    expect(p.availableMarkerBalance, 9000);
    expect(p.availableMarkerBalanceMinor, p.depositHeldMinor);
    expect(w.chipsInHand, 1000);
  });

  test('the draw cannot exceed the deposit held (funding source)',
      () async {
    final pid = await _person('Ali');
    await _deposit(pid, 1000);
    final c500 = await ChipBankService.addChip(value: 500, quantity: 10);

    await expectLater(
      () => DepositToChips.issueToWallet(
        personId: pid,
        currency: AppCurrency.usd,
        amount: 1500,
        composition: {c500.id: 3},
        hostSignatureBase64: 'SIG',
      ),
      throwsA(isA<FinancialLedgerException>()),
    );

    // Nothing was written.
    expect(HiveService.financialEvents.length, 1); // only the deposit
    expect(HiveService.chipMovements.length, 0);
    expect(WalletService.walletFor(pid).positionFor(AppCurrency.usd)!.depositHeld,
        1000);
  });

  test('the composition cannot exceed bank holdings (no phantom chips)',
      () async {
    final pid = await _person('Ali');
    await _deposit(pid, 10000);
    final c500 = await ChipBankService.addChip(value: 500, quantity: 1);

    await expectLater(
      () => DepositToChips.issueToWallet(
        personId: pid,
        currency: AppCurrency.usd,
        amount: 1000,
        composition: {c500.id: 2},
        hostSignatureBase64: 'SIG',
      ),
      throwsA(isA<FinancialLedgerException>()),
    );
    expect(HiveService.financialEvents.length, 1); // only the deposit
    expect(HiveService.chipMovements.length, 0);
  });

  test('the banker signature is required (audit trail)', () async {
    final pid = await _person('Ali');
    await _deposit(pid, 10000);
    final c100 = await ChipBankService.addChip(value: 100, quantity: 50);

    await expectLater(
      () => DepositToChips.issueToWallet(
        personId: pid,
        currency: AppCurrency.usd,
        amount: 100,
        composition: {c100.id: 1},
        hostSignatureBase64: '',
      ),
      throwsA(isA<FinancialLedgerException>()),
    );
    expect(HiveService.financialEvents.length, 1);
    expect(HiveService.chipMovements.length, 0);
  });

  test('an empty composition is refused', () async {
    final pid = await _person('Ali');
    await _deposit(pid, 10000);
    final c100 = await ChipBankService.addChip(value: 100, quantity: 50);

    await expectLater(
      () => DepositToChips.issueToWallet(
        personId: pid,
        currency: AppCurrency.usd,
        amount: 100,
        composition: {c100.id: 0},
        hostSignatureBase64: 'SIG',
      ),
      throwsA(isA<FinancialLedgerException>()),
    );
    expect(HiveService.financialEvents.length, 1);
    expect(HiveService.chipMovements.length, 0);
  });

  test('session-optional: with a session the pair is session-scoped',
      () async {
    final pid = await _person('Ali');
    await _deposit(pid, 5000);
    final c100 = await ChipBankService.addChip(value: 100, quantity: 50);

    final s = PokerSession(
      id: 's1',
      name: 's1',
      location: 'Home',
      dateTime: DateTime(2026, 1, 1),
      smallBlind: 1,
      bigBlind: 2,
      tableNumber: '1',
    );
    await HiveService.sessions.put(s.id, s);

    await DepositToChips.issueToWallet(
      personId: pid,
      currency: AppCurrency.usd,
      amount: 200,
      composition: {c100.id: 2},
      hostSignatureBase64: 'SIG',
      sessionId: s.id,
    );

    for (final e in FinancialLedgerService.eventsFor(pid)) {
      if (e.type == FinancialEventType.frontMoneyOut ||
          e.type == FinancialEventType.cashInForChips) {
        expect(e.sessionId, s.id);
      }
    }
    // The session projection sees the draw (C-1: session-scoped view):
    // 5000 deposited - 200 drawn = 4800 remaining.
    // (Known nuance: the snapshot's used-vs-returned split is
    // transaction-link based; a seat-free draw has no transaction and
    // therefore appears under "returned" there. The REMAINING figure —
    // the one the wallet and settlement rely on — is correct either
    // way. Reclassification belongs to the close-report work.)
    final snap = FinancialLedgerService.snapshotForSession(s.id,
        currency: AppCurrency.usd, personId: pid);
    expect(snap.depositRemaining, 4800);
  });

  test('continuity: issued chips are still in hand at a later table entry',
      () async {
    final pid = await _person('Ali');
    await _deposit(pid, 5000);
    final c500 = await ChipBankService.addChip(value: 500, quantity: 10);

    // Wallet issuance, no session.
    await DepositToChips.issueToWallet(
      personId: pid,
      currency: AppCurrency.usd,
      amount: 1000,
      composition: {c500.id: 2},
      hostSignatureBase64: 'SIG',
    );
    expect(WalletService.walletFor(pid).chipsInHand, 1000);

    // Later: the person sits in a session and the table buy-in is
    // recorded with the chip step SKIPPED — the chips are already in
    // hand. No second chip movement may happen.
    final s = PokerSession(
      id: 's1',
      name: 's1',
      location: 'Home',
      dateTime: DateTime(2026, 1, 1),
      smallBlind: 1,
      bigBlind: 2,
      tableNumber: '1',
    );
    await HiveService.sessions.put(s.id, s);
    final seat = Player(
      id: 'seat-1',
      sessionId: s.id,
      name: 'Ali',
      seatNumber: 1,
      tableId: 'table-1',
      personId: pid,
    );
    await HiveService.players.put(seat.id, seat);
    await SessionService.recordTransaction(
      sessionId: s.id,
      playerId: seat.id,
      type: TransactionType.buyIn,
      amount: 1000,
      hostSignatureBase64: 'SIG2',
    );

    // The chips never left the person: holding unchanged, movements
    // still exactly the issuance pair.
    expect(ChipTrackingService.quantityAt(ChipLocation.player(pid), c500.id),
        2);
    expect(HiveService.chipMovements.length, 1); // one denomination
    expect(
        ChipTrackingService.movementsFor(ChipLocation.player(pid)).single
            .reason,
        ChipMovementReason.depositIssuance.wire);
    // The person is seated; the wallet shows the same chips.
    expect(WalletService.walletFor(pid).seatedNow, isTrue);
    expect(WalletService.walletFor(pid).chipsInHand, 1000);
  });

  test('no side writes: only the intended records are touched', () async {
    final pid = await _person('Ali');
    await _deposit(pid, 10000);
    final c100 = await ChipBankService.addChip(value: 100, quantity: 50);

    final feBefore = HiveService.financialEvents.length; // 1 (deposit)
    final plBefore = HiveService.players.length;
    final stBefore = HiveService.settings.length;

    await DepositToChips.issueToWallet(
      personId: pid,
      currency: AppCurrency.usd,
      amount: 100,
      composition: {c100.id: 1},
      hostSignatureBase64: 'SIG',
    );

    expect(HiveService.financialEvents.length, feBefore + 2); // the pair
    expect(HiveService.chipMovements.length, 1);
    expect(HiveService.transactions.length, 0);
    expect(HiveService.players.length, plBefore);
    expect(HiveService.settings.length, stBefore);
  });

  test('seated path regression: convert still writes the buy-in + linked pair',
      () async {
    final pid = await _person('Ali');
    await _deposit(pid, 10000);
    final c500 = await ChipBankService.addChip(value: 500, quantity: 10);

    final s = PokerSession(
      id: 's1',
      name: 's1',
      location: 'Home',
      dateTime: DateTime(2026, 1, 1),
      smallBlind: 1,
      bigBlind: 2,
      tableNumber: '1',
    );
    await HiveService.sessions.put(s.id, s);
    final seat = Player(
      id: 'seat-1',
      sessionId: s.id,
      name: 'Ali',
      seatNumber: 1,
      tableId: 'table-1',
      personId: pid,
    );
    await HiveService.players.put(seat.id, seat);

    final result = await DepositToChips.convert(
      personId: pid,
      sessionId: s.id,
      playerId: seat.id,
      currency: AppCurrency.usd,
      amount: 1000,
      hostSignatureBase64: 'SIG',
    );

    // Seated path unchanged: a real buy-in transaction, and the pair is
    // linked to it. The signature rides on the transaction, so the
    // events carry none (existing behavior preserved).
    expect(result.chipTransaction.type, TransactionType.buyIn);
    expect(result.chipTransaction.amount, 1000);
    expect(result.frontMoneyOut.linkedTransactionId,
        result.chipTransaction.id);
    expect(result.cashInForChips.linkedTransactionId,
        result.chipTransaction.id);
    expect(result.frontMoneyOut.signatureBase64, isNull);
    expect(WalletService.walletFor(pid).positionFor(AppCurrency.usd)!
        .depositHeld, 9000);
  });
}
