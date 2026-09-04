// Phase 5 — marker (wallet draw).
//
// A marker is a signed IOU that is a DRAW on the person's available
// deposit (E2 / W-2): it can never exceed the available deposit, the
// draw reduces it, the IOU is credit, and the chips it issues enter
// the person-scoped holding. Seat-free like Phase 4: no seat, no
// table, no session required, NO LedgerTransaction, no participation,
// no P2P.
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
import 'package:poker_ledger/services/dual_verification_service.dart';
import 'package:poker_ledger/services/chip_tracking_service.dart';
import 'package:poker_ledger/services/deposit_to_chips.dart';
import 'package:poker_ledger/services/financial_ledger_service.dart';
import 'package:poker_ledger/services/hive_service.dart';
import 'package:poker_ledger/services/player_identity_service.dart';
import 'package:poker_ledger/services/wallet_service.dart';

import 'test_helper.dart';

late Directory _tmp;

Future<void> _open() async {
  _tmp = await Directory.systemTemp.createTemp('pl_preset_mrk_');
  Hive.init(_tmp.path);
  registerTestAdapters();
  await Hive.openBox<PokerSession>(HiveService.sessionsBox);
  await Hive.openBox<Player>(HiveService.playersBox);
  await Hive.openBox<LedgerTransaction>(HiveService.transactionsBox);
  await Hive.openBox(HiveService.settingsBox);
  await Hive.openBox<PlayerIdentity>(HiveService.playerIdentitiesBox);
  await Hive.openBox<FinancialEvent>(HiveService.financialEventsBox);
  await Hive.openBox<ChipType>(HiveService.chipsBox);
  await Hive.openBox(HiveService.transferEventsBox);
  await Hive.openBox<ChipMovement>(HiveService.chipMovementsBox);
}

Future<void> _close() async {
  await Hive.deleteFromDisk();
  if (await _tmp.exists()) await _tmp.delete(recursive: true);
}

Future<String> _person(String name) async =>
    (await PlayerIdentityService.createNew(name))!.id;

Future<void> _deposit(String personId, double amount) async {
  await FinancialLedgerService.record(
    personId: personId,
    currency: AppCurrency.usd,
    type: FinancialEventType.frontMoneyIn,
    amount: amount,
  );
}

const _d1Auth = DualAuthorization(
  reason: 'test inventory',
  operatorName: 'Op',
  operatorSignatureBase64: 'op-sig',
  secondVerifierName: 'V',
  secondVerifierSignature: 'v-sig',
);

void main() {
  setUp(_open);
  tearDown(_close);

  test('write set: draw + IOU + person-scoped movements, no transaction',
      () async {
    final pid = await _person('Ali');
    await _deposit(pid, 10000);
    final c500 = await ChipBankService.addChip(authorization: _d1Auth, value: 500, quantity: 10);

    final result = await DepositToChips.issueMarker(
      personId: pid,
      currency: AppCurrency.usd,
      amount: 1500,
      composition: {c500.id: 3},
      playerSignatureBase64: 'PLAYER_SIG',
    );

    // The draw: the amount taken from the available deposit, signed.
    expect(result.frontMoneyOut.type, FinancialEventType.frontMoneyOut);
    expect(result.frontMoneyOut.amountMajor, 1500);
    expect(result.frontMoneyOut.personId, pid);
    expect(result.frontMoneyOut.sessionId, isNull);
    expect(result.frontMoneyOut.signatureBase64, 'PLAYER_SIG');

    // The IOU: the player now owes this amount, signed.
    expect(result.creditIssued.type, FinancialEventType.creditIssued);
    expect(result.creditIssued.amountMajor, 1500);
    expect(result.creditIssued.personId, pid);
    expect(result.creditIssued.signatureBase64, 'PLAYER_SIG');

    // No money transaction: no seat, no table, no participation.
    expect(HiveService.transactions.length, 0);

    // The chips: bank -> the PERSON, reason markerIssuance, no P2P.
    final movements = HiveService.chipMovements.values.toList();
    expect(movements.length, 1);
    expect(movements.single.fromLocation, ChipLocation.bank.encoded);
    expect(movements.single.toLocation, 'player:$pid');
    expect(movements.single.reason, ChipMovementReason.markerIssuance.wire);

    // Wallet: the draw reduced the deposit; the IOU is credit;
    // W-2: available marker balance == deposit held.
    final w = WalletService.walletFor(pid);
    final p = w.positionFor(AppCurrency.usd)!;
    expect(p.depositHeld, 8500);
    expect(p.creditOutstanding, 1500);
    expect(p.availableMarkerBalance, 8500);
    expect(p.availableMarkerBalanceMinor, p.depositHeldMinor);
    expect(w.chipsInHand, 1500);
    // Net: banker holds 8500 of the player's cash, player owes 1500.
    expect(p.outstandingNet, -7000);
    // Nothing about seating changed.
    expect(w.seatedNow, isFalse);
  });

  test('a marker can never exceed the available deposit', () async {
    final pid = await _person('Ali');
    await _deposit(pid, 1000);
    final c500 = await ChipBankService.addChip(authorization: _d1Auth, value: 500, quantity: 10);

    await expectLater(
      () => DepositToChips.issueMarker(
        personId: pid,
        currency: AppCurrency.usd,
        amount: 1500,
        composition: {c500.id: 3},
        playerSignatureBase64: 'SIG',
      ),
      throwsA(isA<FinancialLedgerException>()),
    );
    // Nothing was written.
    expect(HiveService.financialEvents.length, 1); // only the deposit
    expect(HiveService.chipMovements.length, 0);
    expect(WalletService.walletFor(pid).positionFor(AppCurrency.usd)!
        .depositHeld, 1000);
  });

  test('the cap is cumulative with earlier wallet draws (Phase 4)',
      () async {
    final pid = await _person('Ali');
    await _deposit(pid, 10000);
    final c500 = await ChipBankService.addChip(authorization: _d1Auth, value: 500, quantity: 40);
    final c100 = await ChipBankService.addChip(authorization: _d1Auth, value: 100, quantity: 100);

    // Phase 4 issuance draws 2000 first: deposit 8000 remains.
    await DepositToChips.issueToWallet(
      personId: pid,
      currency: AppCurrency.usd,
      amount: 2000,
      composition: {c500.id: 2, c100.id: 10},
      hostSignatureBase64: 'SIG',
    );
    var p = WalletService.walletFor(pid).positionFor(AppCurrency.usd)!;
    expect(p.depositHeld, 8000);
    expect(p.creditOutstanding, 0);

    // A marker for exactly the remainder is allowed (E2: draw on the
    // available deposit).
    await DepositToChips.issueMarker(
      personId: pid,
      currency: AppCurrency.usd,
      amount: 8000,
      composition: {c500.id: 16},
      playerSignatureBase64: 'SIG',
    );
    p = WalletService.walletFor(pid).positionFor(AppCurrency.usd)!;
    expect(p.depositHeld, 0);
    expect(p.creditOutstanding, 8000);
    expect(p.availableMarkerBalance, 0);

    // Anything more is refused — the available deposit is gone.
    await expectLater(
      () => DepositToChips.issueMarker(
        personId: pid,
        currency: AppCurrency.usd,
        amount: 100,
        composition: {c100.id: 1},
        playerSignatureBase64: 'SIG',
      ),
      throwsA(isA<FinancialLedgerException>()),
    );
    expect(WalletService.walletFor(pid).positionFor(AppCurrency.usd)!
        .creditOutstanding, 8000); // unchanged
  });

  test('the player signature is required (marker = credit + signature)',
      () async {
    final pid = await _person('Ali');
    await _deposit(pid, 10000);
    final c100 = await ChipBankService.addChip(authorization: _d1Auth, value: 100, quantity: 50);

    await expectLater(
      () => DepositToChips.issueMarker(
        personId: pid,
        currency: AppCurrency.usd,
        amount: 100,
        composition: {c100.id: 1},
        playerSignatureBase64: '',
      ),
      throwsA(isA<FinancialLedgerException>()),
    );
    expect(HiveService.financialEvents.length, 1);
    expect(HiveService.chipMovements.length, 0);
  });

  test('the composition cannot exceed bank holdings', () async {
    final pid = await _person('Ali');
    await _deposit(pid, 10000);
    final c500 = await ChipBankService.addChip(authorization: _d1Auth, value: 500, quantity: 1);

    await expectLater(
      () => DepositToChips.issueMarker(
        personId: pid,
        currency: AppCurrency.usd,
        amount: 1000,
        composition: {c500.id: 2},
        playerSignatureBase64: 'SIG',
      ),
      throwsA(isA<FinancialLedgerException>()),
    );
    expect(HiveService.financialEvents.length, 1);
    expect(HiveService.chipMovements.length, 0);
  });

  test('no participation: issuing a marker creates no buy-in or seat',
      () async {
    final pid = await _person('Ali');
    await _deposit(pid, 5000);
    final c500 = await ChipBankService.addChip(authorization: _d1Auth, value: 500, quantity: 10);

    await DepositToChips.issueMarker(
      personId: pid,
      currency: AppCurrency.usd,
      amount: 1000,
      composition: {c500.id: 2},
      playerSignatureBase64: 'SIG',
      sessionId: 's1', // session-optional; passed when available
    );

    // No transaction anywhere, no seated player, no session needed.
    expect(HiveService.transactions.length, 0);
    expect(HiveService.players.length, 0);
    expect(WalletService.walletFor(pid).seatedNow, isFalse);
    // The events carry the session when given (C-1 reporting).
    for (final e in FinancialLedgerService.eventsFor(pid)) {
      if (e.type == FinancialEventType.frontMoneyOut ||
          e.type == FinancialEventType.creditIssued) {
        expect(e.sessionId, 's1');
      }
    }
  });

  test('repayment clears the credit and does not touch the deposit',
      () async {
    final pid = await _person('Ali');
    await _deposit(pid, 10000);
    final c500 = await ChipBankService.addChip(authorization: _d1Auth, value: 500, quantity: 10);
    await DepositToChips.issueMarker(
      personId: pid,
      currency: AppCurrency.usd,
      amount: 1500,
      composition: {c500.id: 3},
      playerSignatureBase64: 'SIG',
    );

    // The existing repayment operation (unchanged semantics).
    await FinancialLedgerService.record(
      personId: pid,
      currency: AppCurrency.usd,
      type: FinancialEventType.creditRepaid,
      amount: 1500,
    );

    final p = WalletService.walletFor(pid).positionFor(AppCurrency.usd)!;
    expect(p.creditOutstanding, 0);
    expect(p.depositHeld, 8500); // the draw stays drawn
    expect(p.availableMarkerBalance, 8500);
    // Net: banker holds 8500, no credit.
    expect(p.outstandingNet, -8500);
  });

  test('a marker issued chips are still in hand (continuity)', () async {
    final pid = await _person('Ali');
    await _deposit(pid, 5000);
    final c500 = await ChipBankService.addChip(authorization: _d1Auth, value: 500, quantity: 10);

    await DepositToChips.issueMarker(
      personId: pid,
      currency: AppCurrency.usd,
      amount: 1000,
      composition: {c500.id: 2},
      playerSignatureBase64: 'SIG',
    );

    // The person-scoped holding carries the marker chips; a later
    // table entry (Phase 6) will use them without a new issuance.
    expect(
        ChipTrackingService.quantityAt(ChipLocation.player(pid), c500.id), 2);
    expect(WalletService.walletFor(pid).chipsInHand, 1000);
  });
}
