// Step 7 — Settlement-safe Discount chips.
//
// Session-level promotional overlay only. SessionService formulas
// stay frozen. Host Profit stays rake.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:poker_ledger/core/localization/app_localizations.dart';
import 'package:poker_ledger/models/chip_movement.dart';
import 'package:poker_ledger/models/chip_type.dart';
import 'package:poker_ledger/models/enums.dart';
import 'package:poker_ledger/models/financial_event.dart';
import 'package:poker_ledger/models/player.dart';
import 'package:poker_ledger/models/player_identity.dart';
import 'package:poker_ledger/models/session.dart';
import 'package:poker_ledger/models/transaction.dart';
import 'package:poker_ledger/services/chip_tracking_service.dart';
import 'package:poker_ledger/services/financial_ledger_service.dart';
import 'package:poker_ledger/services/hive_service.dart';
import 'package:poker_ledger/services/player_identity_service.dart';
import 'package:poker_ledger/services/rebate_service.dart';
import 'package:poker_ledger/services/session_service.dart';

import 'test_helper.dart';

late Directory _tmp;
late String _personId;
late String _otherId;

Future<void> _open() async {
  _tmp = await Directory.systemTemp.createTemp('pl_disc_settle_');
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
  _personId = (await PlayerIdentityService.createNew('Ali'))!.id;
  _otherId = (await PlayerIdentityService.createNew('Baba'))!.id;
}

Future<void> _close() async {
  await Hive.deleteFromDisk();
  if (await _tmp.exists()) await _tmp.delete(recursive: true);
}

Future<PokerSession> _session(String id) async {
  final s = PokerSession(
    id: id,
    name: 'Night',
    location: 'Home',
    dateTime: DateTime.now(),
    smallBlind: 1,
    bigBlind: 2,
    tableNumber: '1',
    rebateEnabled: true,
    rebateMinLoss: 1000,
    rebatePercent: 10,
  );
  await HiveService.sessions.put(s.id, s);
  return s;
}

Future<Player> _seat(
  String sessionId, {
  String id = 'seat-1',
  String? personId,
  int seat = 1,
  String name = 'Ali',
}) async {
  final p = Player(
    id: id,
    sessionId: sessionId,
    name: name,
    seatNumber: seat,
    personId: personId ?? _personId,
  );
  await HiveService.players.put(p.id, p);
  return p;
}

Future<void> _cashIn(String sessionId, double amount, {String? personId}) {
  return FinancialLedgerService.record(
    personId: personId ?? _personId,
    currency: AppCurrency.usd,
    type: FinancialEventType.cashInForChips,
    amount: amount,
    sessionId: sessionId,
  );
}

void main() {
  setUp(_open);
  tearDown(_close);

  test('cash Discount does not create a chip overlay', () async {
    final s = await _session('cash');
    await _cashIn(s.id, 1500);
    await RebateService.grant(
      sessionId: s.id,
      personId: _personId,
      currency: AppCurrency.usd,
      asChips: false,
      bustRealized: true,
    );
    final books = SessionService.checkBalance(s.id);
    expect(books.moneyIn, 0);
    expect(SessionService.hostProfit(s.id), 0);
    expect(
      RebateService.overlayFor(
        sessionId: s.id,
        currency: AppCurrency.usd,
        rawDiscrepancy: books.discrepancy,
        moneyStillInPlay: SessionService.moneyStillInPlay(s.id),
      ),
      isNull,
    );
  });

  test('chip grant in play raises implied still-in-play by the grant',
      () async {
    final s = await _session('inplay');
    final p = await _seat(s.id);
    await SessionService.recordTransaction(
      sessionId: s.id,
      playerId: p.id,
      type: TransactionType.buyIn,
      amount: 1500,
      hostSignatureBase64: 'sig',
    );
    await _cashIn(s.id, 1500);
    await RebateService.grant(
      sessionId: s.id,
      personId: _personId,
      currency: AppCurrency.usd,
      asChips: true,
      bustRealized: true,
    );
    final books = SessionService.checkBalance(s.id);
    expect(books.moneyIn, 1500);
    expect(SessionService.moneyStillInPlay(s.id), 1500);
    expect(SessionService.hostProfit(s.id), 0);
    final rec = RebateService.overlayFor(
      sessionId: s.id,
      currency: AppCurrency.usd,
      rawDiscrepancy: books.discrepancy,
      moneyStillInPlay: SessionService.moneyStillInPlay(s.id),
    );
    expect(rec, isNotNull);
    expect(rec!.issuedMajor, 150);
    expect(rec.impliedStillInPlay, 1650);
    expect(rec.residualAfterDiscount, 1650);
    expect(rec.booksBalancedWithPromoOut, isFalse);
    expect(rec.explainsGap, isFalse);
  });

  test('canonical \$150 grant + \$80 cash-out: implied 1570, financial 80/70/1420',
      () async {
    final s = await _session('canon');
    final p = await _seat(s.id);
    await SessionService.recordTransaction(
      sessionId: s.id,
      playerId: p.id,
      type: TransactionType.buyIn,
      amount: 1500,
      hostSignatureBase64: 'sig',
    );
    await _cashIn(s.id, 1500);
    await RebateService.grant(
      sessionId: s.id,
      personId: _personId,
      currency: AppCurrency.usd,
      asChips: true,
      bustRealized: true,
    );
    await SessionService.recordTransaction(
      sessionId: s.id,
      playerId: p.id,
      type: TransactionType.cashOut,
      amount: 80,
      hostSignatureBase64: 'sig',
    );
    await FinancialLedgerService.record(
      personId: _personId,
      currency: AppCurrency.usd,
      type: FinancialEventType.cashOutForChips,
      amount: 80,
      sessionId: s.id,
    );
    await RebateService.realizeCashOut(
      sessionId: s.id,
      personId: _personId,
      currency: AppCurrency.usd,
      cashOutMinor: 8000,
    );
    expect(SessionService.moneyStillInPlay(s.id), 1420);
    expect(SessionService.checkBalance(s.id).moneyIn, 1500);
    expect(SessionService.checkBalance(s.id).moneyOut, 80);
    expect(SessionService.hostProfit(s.id), 0);
    final rec = RebateService.overlayFor(
      sessionId: s.id,
      currency: AppCurrency.usd,
      rawDiscrepancy: SessionService.checkBalance(s.id).discrepancy,
      moneyStillInPlay: SessionService.moneyStillInPlay(s.id),
    );
    expect(rec!.impliedStillInPlay, 1570);
    final snap = RebateService.snapshot(
      sessionId: s.id,
      personId: _personId,
      currency: AppCurrency.usd,
    );
    expect(snap.actualCashPaid, 80);
    expect(snap.lostInPlay, 70);
    expect(snap.houseRetained, 1420);
    expect(snap.clawback, 0);
  });

  test('full cash of a chip grant explains the frozen short; Host Profit is rake',
      () async {
    final s = await _session('full');
    final p = await _seat(s.id);
    await SessionService.recordTransaction(
      sessionId: s.id,
      playerId: p.id,
      type: TransactionType.buyIn,
      amount: 1500,
      hostSignatureBase64: 'sig',
    );
    await _cashIn(s.id, 1500);
    await RebateService.grant(
      sessionId: s.id,
      personId: _personId,
      currency: AppCurrency.usd,
      asChips: true,
      bustRealized: true,
    );
    await SessionService.recordTransaction(
      sessionId: s.id,
      playerId: p.id,
      type: TransactionType.cashOut,
      amount: 1650,
      hostSignatureBase64: 'sig',
    );
    final books = SessionService.checkBalance(s.id);
    expect(books.moneyIn, 1500);
    expect(books.moneyOut, 1650);
    expect(books.discrepancy, -150);
    expect(SessionService.hostProfit(s.id), SessionService.totalRake(s.id));
    final rec = RebateService.overlayFor(
      sessionId: s.id,
      currency: AppCurrency.usd,
      rawDiscrepancy: books.discrepancy,
      moneyStillInPlay: SessionService.moneyStillInPlay(s.id),
    );
    expect(rec!.explainsGap, isTrue);
    expect(rec.impliedStillInPlay.abs() < 0.005, isTrue);
  });

  test('count moves chips, then another player cashes: session residual, '
      'no grant on them', () async {
    final s = await _session('p2p');
    final a = await _seat(s.id);
    await _seat(s.id,
        id: 'seat-2', personId: _otherId, seat: 2, name: 'Baba');
    await SessionService.recordTransaction(
      sessionId: s.id,
      playerId: a.id,
      type: TransactionType.buyIn,
      amount: 1500,
      hostSignatureBase64: 'sig',
    );
    await _cashIn(s.id, 1500);
    await RebateService.grant(
      sessionId: s.id,
      personId: _personId,
      currency: AppCurrency.usd,
      asChips: true,
      bustRealized: true,
    );
    await HiveService.chips.put(
      'c25',
      ChipType(id: 'c25', value: 25, quantity: 20),
    );
    // The $150 grant chips moved from Ali's stack to Baba's during
    // play — captured by physical counts (P2P transfer removed, E7).
    await ChipTrackingService.adjustPlayerHoldingForHandSettlement(
      playerId: 'seat-1',
      counted: {'c25': 0},
      sessionId: s.id,
    );
    await ChipTrackingService.adjustPlayerHoldingForHandSettlement(
      playerId: 'seat-2',
      counted: {'c25': 6},
      sessionId: s.id,
    );
    await SessionService.recordTransaction(
      sessionId: s.id,
      playerId: 'seat-2',
      type: TransactionType.cashOut,
      amount: 1650,
      hostSignatureBase64: 'sig',
    );
    final books = SessionService.checkBalance(s.id);
    expect(books.discrepancy, -150);
    final rec = RebateService.overlayFor(
      sessionId: s.id,
      currency: AppCurrency.usd,
      rawDiscrepancy: books.discrepancy,
      moneyStillInPlay: SessionService.moneyStillInPlay(s.id),
    );
    expect(rec!.explainsGap, isTrue);
    expect(
      RebateService.snapshot(
        sessionId: s.id,
        personId: _otherId,
        currency: AppCurrency.usd,
      ).granted,
      0,
    );
    expect(
      RebateService.snapshot(
        sessionId: s.id,
        personId: _personId,
        currency: AppCurrency.usd,
      ).granted,
      150,
    );
  });

  test('buy-ins cashed but grant still out: books balance, promo still in play',
      () async {
    final s = await _session('promo-out');
    final p = await _seat(s.id);
    await SessionService.recordTransaction(
      sessionId: s.id,
      playerId: p.id,
      type: TransactionType.buyIn,
      amount: 1500,
      hostSignatureBase64: 'sig',
    );
    await _cashIn(s.id, 1500);
    await RebateService.grant(
      sessionId: s.id,
      personId: _personId,
      currency: AppCurrency.usd,
      asChips: true,
      bustRealized: true,
    );
    await SessionService.recordTransaction(
      sessionId: s.id,
      playerId: p.id,
      type: TransactionType.cashOut,
      amount: 1500,
      hostSignatureBase64: 'sig',
    );
    final books = SessionService.checkBalance(s.id);
    expect(books.isBalanced, isTrue);
    expect(books.moneyIn, 1500);
    expect(books.moneyOut, 1500);
    final rec = RebateService.overlayFor(
      sessionId: s.id,
      currency: AppCurrency.usd,
      rawDiscrepancy: books.discrepancy,
      moneyStillInPlay: SessionService.moneyStillInPlay(s.id),
    );
    expect(rec!.booksBalancedWithPromoOut, isTrue);
    expect(rec.impliedStillInPlay, 150);
    expect(rec.explainsGap, isFalse);
  });

  test('reversed chip grant removes the overlay', () async {
    final s = await _session('rev');
    await _cashIn(s.id, 1500);
    final g = await RebateService.grant(
      sessionId: s.id,
      personId: _personId,
      currency: AppCurrency.usd,
      asChips: true,
      bustRealized: true,
    );
    expect(
      RebateService.chipGrantsIssuedMinor(s.id, AppCurrency.usd),
      15000,
    );
    await RebateService.reverseGrant(g.id);
    expect(RebateService.chipGrantsIssuedMinor(s.id, AppCurrency.usd), 0);
    expect(
      RebateService.overlayFor(
        sessionId: s.id,
        currency: AppCurrency.usd,
        rawDiscrepancy: SessionService.checkBalance(s.id).discrepancy,
        moneyStillInPlay: SessionService.moneyStillInPlay(s.id),
      ),
      isNull,
    );
  });

  test('EN/FA Step 7 overlay keys exist and differ', () {
    const keys = [
      'settle_rebate_chips_in_play',
      'rebate_promo_in_play',
      'rebate_books_explained_short',
      'rebate_chips_issued',
      'rebate_implied_in_play',
      'settle_rebate_chips_explained',
    ];
    for (final key in keys) {
      final en = AppLocalizations.lookup('en', key);
      final fa = AppLocalizations.lookup('fa', key);
      expect(en, isNot(key), reason: key);
      expect(fa, isNot(key), reason: key);
      expect(en, isNot(fa), reason: key);
    }
    expect(
      AppLocalizations.keysOf('en').toSet(),
      AppLocalizations.keysOf('fa').toSet(),
    );
  });
}
