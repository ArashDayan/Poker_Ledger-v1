// Chip Exchange — Player ↔ Bank denomination swap.
//
// Limit is the derived Chip Ledger holding, never Buy-in/Rebuy.
// No Session / Financial / Discount writes.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:poker_ledger/models/chip_movement.dart';
import 'package:poker_ledger/models/chip_type.dart';
import 'package:poker_ledger/models/financial_event.dart';
import 'package:poker_ledger/models/player.dart';
import 'package:poker_ledger/models/session.dart';
import 'package:poker_ledger/models/transaction.dart';
import 'package:poker_ledger/services/chip_bank_service.dart';
import 'package:poker_ledger/services/chip_exchange_rules.dart';
import 'package:poker_ledger/services/chip_tracking_service.dart';
import 'package:poker_ledger/services/hive_service.dart';
import 'package:poker_ledger/services/session_service.dart';
import 'package:uuid/uuid.dart';

import 'test_helper.dart';

const _uuid = Uuid();
late Directory _tmp;

Future<void> _open() async {
  _tmp = await Directory.systemTemp.createTemp('pl_xchg_');
  Hive.init(_tmp.path);
  registerTestAdapters();
  await Hive.openBox<PokerSession>(HiveService.sessionsBox);
  await Hive.openBox<Player>(HiveService.playersBox);
  await Hive.openBox<LedgerTransaction>(HiveService.transactionsBox);
  await Hive.openBox(HiveService.settingsBox);
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

Future<Map<String, ChipType>> _stock() async {
  final c100 = await ChipBankService.addChip(value: 100, quantity: 200);
  final c1000 = await ChipBankService.addChip(value: 1000, quantity: 50);
  return {'100': c100, '1000': c1000};
}

String _session() {
  final s = PokerSession(
    id: _uuid.v4(),
    name: 'X',
    location: 'R',
    dateTime: DateTime.now(),
    smallBlind: 1,
    bigBlind: 2,
    tableNumber: '1',
  );
  HiveService.sessions.put(s.id, s);
  return s.id;
}

void main() {
  setUp(_open);
  tearDown(_close);

  test('1. buy-in 2000 + ledger 10000 can exchange 5000', () async {
    final c = await _stock();
    final sid = _session();
    await SessionService.recordTransaction(
      sessionId: sid,
      playerId: 'p1',
      type: TransactionType.buyIn,
      amount: 2000,
      hostSignatureBase64: 'sig',
    );
    // Ledger holding 10,000 in 100s (wins recorded as chips).
    await ChipTrackingService.recordDistribution(
      distribution: {c['100']!.id: 100},
      from: ChipLocation.bank,
      to: ChipLocation.player('p1'),
      reason: ChipMovementReason.buyIn,
    );
    expect(ChipTrackingService.playerHolding('p1').totalValue, 10000);
    expect(
      ChipExchangeRules.canConfirm(
        playerId: 'p1',
        given: {c['100']!.id: 50},
        received: {c['1000']!.id: 5},
      ),
      isTrue,
    );
    await ChipTrackingService.recordExchange(
      counterparty: ChipLocation.player('p1'),
      chipsIn: {c['100']!.id: 50},
      chipsOut: {c['1000']!.id: 5},
    );
    expect(ChipTrackingService.playerHolding('p1').totalValue, 10000);
  });

  test('2. cannot exceed actual Chip Ledger holding', () async {
    final c = await _stock();
    await ChipTrackingService.recordDistribution(
      distribution: {c['100']!.id: 20},
      from: ChipLocation.bank,
      to: ChipLocation.player('p1'),
      reason: ChipMovementReason.buyIn,
    );
    expect(
      ChipExchangeRules.playerCanCover('p1', {c['100']!.id: 21}),
      isFalse,
    );
    expect(
      ChipExchangeRules.canConfirm(
        playerId: 'p1',
        given: {c['100']!.id: 21},
        received: {c['1000']!.id: 2},
      ),
      isFalse,
    );
  });

  test('3. unequal totals are rejected', () async {
    final c = await _stock();
    await ChipTrackingService.recordDistribution(
      distribution: {c['100']!.id: 50},
      from: ChipLocation.bank,
      to: ChipLocation.player('p1'),
      reason: ChipMovementReason.buyIn,
    );
    expect(ChipExchangeRules.isBalanced({c['100']!.id: 50}, {c['1000']!.id: 4}),
        isFalse);
    await expectLater(
      ChipTrackingService.recordExchange(
        counterparty: ChipLocation.player('p1'),
        chipsIn: {c['100']!.id: 50},
        chipsOut: {c['1000']!.id: 4},
      ),
      throwsArgumentError,
    );
  });

  test('4–5. valid exchange changes composition, not total value', () async {
    final c = await _stock();
    await ChipTrackingService.recordDistribution(
      distribution: {c['100']!.id: 100},
      from: ChipLocation.bank,
      to: ChipLocation.player('p1'),
      reason: ChipMovementReason.buyIn,
    );
    await ChipTrackingService.recordExchange(
      counterparty: ChipLocation.player('p1'),
      chipsIn: {c['100']!.id: 50},
      chipsOut: {c['1000']!.id: 5},
    );
    expect(
        ChipTrackingService.quantityAt(
            ChipLocation.player('p1'), c['100']!.id),
        50);
    expect(
        ChipTrackingService.quantityAt(
            ChipLocation.player('p1'), c['1000']!.id),
        5);
    expect(ChipTrackingService.playerHolding('p1').totalValue, 10000);
  });

  test('6. Chip Bank inventory updates', () async {
    final c = await _stock();
    final bank100 = ChipTrackingService.quantityAt(ChipLocation.bank, c['100']!.id);
    final bank1000 =
        ChipTrackingService.quantityAt(ChipLocation.bank, c['1000']!.id);
    await ChipTrackingService.recordDistribution(
      distribution: {c['100']!.id: 100},
      from: ChipLocation.bank,
      to: ChipLocation.player('p1'),
      reason: ChipMovementReason.buyIn,
    );
    await ChipTrackingService.recordExchange(
      counterparty: ChipLocation.player('p1'),
      chipsIn: {c['100']!.id: 50},
      chipsOut: {c['1000']!.id: 5},
    );
    expect(ChipTrackingService.quantityAt(ChipLocation.bank, c['100']!.id),
        bank100 - 100 + 50);
    expect(ChipTrackingService.quantityAt(ChipLocation.bank, c['1000']!.id),
        bank1000 - 5);
  });

  test('7–11. no Money In/Out/Rake/Host Profit/Discount change', () async {
    final c = await _stock();
    final sid = _session();
    await SessionService.recordTransaction(
      sessionId: sid,
      playerId: 'p1',
      type: TransactionType.buyIn,
      amount: 2000,
      hostSignatureBase64: 'sig',
    );
    await ChipTrackingService.recordDistribution(
      distribution: {c['100']!.id: 100},
      from: ChipLocation.bank,
      to: ChipLocation.player('p1'),
      reason: ChipMovementReason.buyIn,
    );
    final moneyIn = SessionService.totalBuyIn(sid) + SessionService.totalRebuy(sid);
    final moneyOut = SessionService.totalCashOut(sid) + SessionService.totalRake(sid);
    final rake = SessionService.totalRake(sid);
    final profit = SessionService.hostProfit(sid);
    final fin = HiveService.financialEvents.length;
    final tx = HiveService.transactions.length;

    await ChipTrackingService.recordExchange(
      counterparty: ChipLocation.player('p1'),
      chipsIn: {c['100']!.id: 50},
      chipsOut: {c['1000']!.id: 5},
    );

    expect(SessionService.totalBuyIn(sid) + SessionService.totalRebuy(sid),
        moneyIn);
    expect(SessionService.totalCashOut(sid) + SessionService.totalRake(sid),
        moneyOut);
    expect(SessionService.totalRake(sid), rake);
    expect(SessionService.hostProfit(sid), profit);
    expect(HiveService.financialEvents.length, fin);
    expect(HiveService.transactions.length, tx);
  });

  test('12. buy-in/rebuy is not the exchange limit', () async {
    final c = await _stock();
    final sid = _session();
    await SessionService.recordTransaction(
      sessionId: sid,
      playerId: 'p1',
      type: TransactionType.buyIn,
      amount: 2000,
      hostSignatureBase64: 'sig',
    );
    await ChipTrackingService.recordDistribution(
      distribution: {c['100']!.id: 100},
      from: ChipLocation.bank,
      to: ChipLocation.player('p1'),
      reason: ChipMovementReason.buyIn,
    );
    // 5000 > buy-in 2000, but <= holding 10000.
    expect(
      ChipExchangeRules.canConfirm(
        playerId: 'p1',
        given: {c['100']!.id: 50},
        received: {c['1000']!.id: 5},
      ),
      isTrue,
    );
  });

  test('13. physical count adjustment is a separate operation', () async {
    final c = await _stock();
    await ChipTrackingService.recordDistribution(
      distribution: {c['100']!.id: 20},
      from: ChipLocation.bank,
      to: ChipLocation.player('p1'),
      reason: ChipMovementReason.buyIn,
    );
    final made = await ChipTrackingService.adjustPlayerHoldingToCount(
      playerId: 'p1',
      counted: {c['100']!.id: 100, c['1000']!.id: 0},
    );
    expect(made.single.reasonEnum, ChipMovementReason.adjustment);
    expect(
      made.every((m) => m.reasonEnum != ChipMovementReason.exchange),
      isTrue,
    );
    expect(ChipTrackingService.playerHolding('p1').totalValue, 10000);
  });

  test('14. selected player ledger is the live holding, not zero', () async {
    final c = await _stock();
    await ChipTrackingService.recordDistribution(
      distribution: {c['100']!.id: 100},
      from: ChipLocation.bank,
      to: ChipLocation.player('p1'),
      reason: ChipMovementReason.buyIn,
    );
    final holding = ChipTrackingService.playerHolding('p1');
    expect(holding.totalValue, isNot(0));
    expect(holding.totalValue, 10000);
    expect(ChipBankService.allChips(), isNotEmpty);
    expect(
      ChipTrackingService.quantityAt(ChipLocation.player('p1'), c['100']!.id),
      100,
    );
  });
}
