// Phase 3 — wallet service.
//
// The wallet is a DERIVED, never-stored view (W-1) over the Financial
// Ledger (deposit / credit / net, existing formulas unchanged), the
// person-scoped Chip Ledger (chips in hand, Phase 2a) and the seating
// rows (informational reference only).
//
// E8: the wallet's remaining deposit is the LIFETIME source of truth;
// session-scoped deposit figures are projections.
// W-2 (approved E2): available marker balance = deposit held.
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
import 'package:poker_ledger/services/financial_ledger_service.dart';
import 'package:poker_ledger/services/hive_service.dart';
import 'package:poker_ledger/services/player_identity_service.dart';
import 'package:poker_ledger/services/session_service.dart';
import 'package:poker_ledger/services/wallet_service.dart';

import 'test_helper.dart';

late Directory _tmp;

Future<void> _open() async {
  _tmp = await Directory.systemTemp.createTemp('pl_preset_wal_');
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

Future<PokerSession> _session(String id, {bool active = true}) async {
  final s = PokerSession(
    id: id,
    name: id,
    location: 'Home',
    dateTime: DateTime(2026, 1, 1),
    smallBlind: 1,
    bigBlind: 2,
    tableNumber: '1',
    status: active ? SessionStatus.active : SessionStatus.ended,
  );
  await HiveService.sessions.put(s.id, s);
  return s;
}

Future<void> _fe(
  String personId,
  FinancialEventType type,
  double amount, {
  String? sessionId,
}) async {
  await FinancialLedgerService.record(
    personId: personId,
    currency: AppCurrency.usd,
    type: type,
    amount: amount,
    sessionId: sessionId,
  );
}

void main() {
  setUp(_open);
  tearDown(_close);

  test('deposit / credit / net derive from the existing formulas', () async {
    final pid = await _person('Ali');
    await _fe(pid, FinancialEventType.frontMoneyIn, 10000);
    await _fe(pid, FinancialEventType.frontMoneyOut, 2000);
    await _fe(pid, FinancialEventType.creditIssued, 1500);
    await _fe(pid, FinancialEventType.creditRepaid, 500);

    final w = WalletService.walletFor(pid);
    final p = w.positionFor(AppCurrency.usd)!;

    // Deposit: 10000 - 2000 = 8000.
    expect(p.depositHeld, 8000);
    // Credit: 1500 - 500 = 1000 (front money is NOT credit).
    expect(p.creditOutstanding, 1000);
    // Net (the existing outstanding formula):
    // creditIssued 1500 + frontMoneyOut 2000 - creditRepaid 500
    // - frontMoneyIn 10000 = -7000 (banker holds).
    expect(p.outstandingNet, -7000);
    // W-2 (approved E2): a marker is a draw on the deposit, so the
    // available amount is the deposit after all draws.
    expect(p.availableMarkerBalance, 8000);
    expect(p.availableMarkerBalanceMinor, p.depositHeldMinor);
    expect(w.hasActivity, isTrue);
    expect(w.seatedNow, isFalse);
  });

  test('cashOutUnbacked counts as credit; front money never does', () async {
    final pid = await _person('Reza');
    await _fe(pid, FinancialEventType.cashOutUnbacked, 300);
    await _fe(pid, FinancialEventType.frontMoneyIn, 5000);

    final p = WalletService.walletFor(pid).positionFor(AppCurrency.usd)!;
    expect(p.creditOutstanding, 300);
    expect(p.depositHeld, 5000);
  });

  test('reversed credit drops out of the wallet (active-events rule)',
      () async {
    final pid = await _person('Dana');
    final credit =
        await FinancialLedgerService.record(
      personId: pid,
      currency: AppCurrency.usd,
      type: FinancialEventType.creditIssued,
      amount: 400,
    );
    expect(
        WalletService.walletFor(pid).positionFor(AppCurrency.usd)!.creditOutstanding,
        400);
    await FinancialLedgerService.reverse(credit.id);
    expect(
        WalletService.walletFor(pid).positionFor(AppCurrency.usd)!.creditOutstanding,
        0);
  });

  test('chips in hand come from the PERSON-scoped holding (Phase 2a)',
      () async {
    final pid = await _person('Ali');
    final c100 = await ChipBankService.addChip(value: 100, quantity: 50);
    final c500 = await ChipBankService.addChip(value: 500, quantity: 20);

    // The person holds 2 x 100 + 1 x 500 = 700.
    await ChipTrackingService.recordDistribution(
      distribution: {c100.id: 2, c500.id: 1},
      from: ChipLocation.bank,
      to: ChipLocation.player(pid),
      reason: ChipMovementReason.buyIn,
    );
    // An UNLINKED seat's chips are a different holder — not this
    // person's holding.
    await ChipTrackingService.recordDistribution(
      distribution: {c100.id: 5},
      from: ChipLocation.bank,
      to: ChipLocation.player('seat-9'),
      reason: ChipMovementReason.buyIn,
    );

    final w = WalletService.walletFor(pid);
    expect(w.chipsInHand, 700);
  });

  test('a pre-seat person (no session at all) has a working wallet',
      () async {
    // Phase 1: a person can exist before any session.
    final pid = await _person('Nina');
    await _fe(pid, FinancialEventType.frontMoneyIn, 2500);

    final w = WalletService.walletFor(pid);
    expect(w.currencies, hasLength(1));
    expect(w.positionFor(AppCurrency.usd)!.depositHeld, 2500);
    expect(w.seatedNow, isFalse);
    expect(w.seatedSessionId, isNull);
    expect(w.hasActivity, isTrue);
  });

  test('seating reference: active session only, clears on unseat',
      () async {
    final pid = await _person('Ali');
    final s1 = await _session('s1');
    final ended = await _session('s2', active: false);

    // Seated in an ENDED session: not "seated now".
    Player p1 = Player(
      id: 'seat-1',
      sessionId: ended.id,
      name: 'Ali',
      seatNumber: 1,
      personId: pid,
    );
    await HiveService.players.put(p1.id, p1);
    expect(WalletService.walletFor(pid).seatedNow, isFalse);

    // Seated in the active session: reference set.
    p1 = Player(
      id: 'seat-2',
      sessionId: s1.id,
      name: 'Ali',
      seatNumber: 3,
      tableId: 'table-1',
      personId: pid,
    );
    await HiveService.players.put(p1.id, p1);
    final w = WalletService.walletFor(pid);
    expect(w.seatedNow, isTrue);
    expect(w.seatedSessionId, s1.id);
    expect(w.seatedTableId, 'table-1');

    // Unseat: the reference clears (wallet re-derived, nothing stored).
    p1.seated = false;
    p1.tableId = null;
    await p1.save();
    expect(WalletService.walletFor(pid).seatedNow, isFalse);
  });

  test('currency isolation: one position per currency, never netted',
      () async {
    final pid = await _person('Ali');
    await FinancialLedgerService.record(
      personId: pid,
      currency: AppCurrency.usd,
      type: FinancialEventType.frontMoneyIn,
      amount: 1000,
    );
    await FinancialLedgerService.record(
      personId: pid,
      currency: AppCurrency.toman,
      type: FinancialEventType.frontMoneyIn,
      amount: 2000,
    );

    final w = WalletService.walletFor(pid);
    expect(w.currencies, hasLength(2));
    expect(w.positionFor(AppCurrency.usd)!.depositHeld, 1000);
    expect(w.positionFor(AppCurrency.toman)!.depositHeld, 2000);
  });

  test('W-1: the wallet NEVER writes (derived, never stored)', () async {
    final pid = await _person('Ali');
    await _fe(pid, FinancialEventType.frontMoneyIn, 1000);

    final feBefore = HiveService.financialEvents.length;
    final mvBefore = HiveService.chipMovements.length;
    final plBefore = HiveService.players.length;
    final stBefore = HiveService.settings.length;

    WalletService.walletFor(pid);
    WalletService.walletFor(pid); // twice — still nothing

    expect(HiveService.financialEvents.length, feBefore);
    expect(HiveService.chipMovements.length, mvBefore);
    expect(HiveService.players.length, plBefore);
    expect(HiveService.settings.length, stBefore);
  });

  test('E8: wallet deposit is the lifetime truth; session figure is a projection',
      () async {
    final pid = await _person('Ali');
    final s = await _session('s1');

    // Deposit before the session (no session link): lifetime only.
    await _fe(pid, FinancialEventType.frontMoneyIn, 6000);
    // Deposit inside the session: both lifetime and the projection.
    await _fe(pid, FinancialEventType.frontMoneyIn, 1000, sessionId: s.id);
    await _fe(pid, FinancialEventType.frontMoneyOut, 400, sessionId: s.id);

    // Lifetime wallet: 6000 + 1000 - 400 = 6600.
    final walletDeposit =
        WalletService.walletFor(pid).positionFor(AppCurrency.usd)!.depositHeld;
    expect(walletDeposit, 6600);
    // The wallet and the ledger agree — one source of truth.
    expect(
        walletDeposit, FinancialLedgerService.depositHeldMajor(pid, AppCurrency.usd));

    // Session projection: only this session's activity: 1000 - 400 = 600.
    final snap = FinancialLedgerService.snapshotForSession(s.id,
        currency: AppCurrency.usd, personId: pid);
    expect(snap.depositRemaining, 600);
    // The two figures are different by design — the session figure is
    // a projection, the wallet figure is the truth.
    expect(snap.depositRemaining, isNot(walletDeposit));
  });

  test('a person with no activity: not-recorded, not zero', () async {
    final pid = await _person('Mina');
    final w = WalletService.walletFor(pid);
    expect(w.currencies, isEmpty);
    expect(w.chipsInHand, 0);
    expect(w.hasActivity, isFalse);
    // The ledger's own "not recorded" rule still holds underneath.
    expect(
        FinancialLedgerService.balance(pid, AppCurrency.usd).isNotRecorded,
        isTrue);
  });

  test('unused session money flow is untouched by the wallet reads',
      () async {
    // Regression guard: wallet reads must not perturb the settlement
    // figures they report alongside.
    final pid = await _person('Ali');
    final s = await _session('s1');
    final p = Player(
      id: 'seat-1',
      sessionId: s.id,
      name: 'Ali',
      seatNumber: 1,
      personId: pid,
    );
    await HiveService.players.put(p.id, p);
    await SessionService.recordTransaction(
      sessionId: s.id,
      playerId: p.id,
      type: TransactionType.buyIn,
      amount: 500,
      hostSignatureBase64: 'sig',
    );
    final before = SessionService.checkBalance(s.id);
    WalletService.walletFor(pid);
    final after = SessionService.checkBalance(s.id);
    expect(after.moneyIn, before.moneyIn);
    expect(after.moneyOut, before.moneyOut);
    expect(after.discrepancy, before.discrepancy);
  });
}
