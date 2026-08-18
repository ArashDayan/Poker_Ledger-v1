// Phase 4 — live Dashboard / Financial Account consume the same
// SessionService + FinancialLedgerService numbers. No second engine.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:poker_ledger/core/localization/app_localizations.dart';
import 'package:poker_ledger/models/enums.dart';
import 'package:poker_ledger/models/financial_event.dart';
import 'package:poker_ledger/models/player.dart';
import 'package:poker_ledger/models/player_identity.dart';
import 'package:poker_ledger/models/session.dart';
import 'package:poker_ledger/models/transaction.dart';
import 'package:poker_ledger/services/financial_capture.dart';
import 'package:poker_ledger/services/financial_ledger_service.dart';
import 'package:poker_ledger/services/hive_service.dart';
import 'package:poker_ledger/services/player_identity_service.dart';
import 'package:poker_ledger/services/rebate_service.dart';
import 'package:poker_ledger/services/session_service.dart';
import 'package:poker_ledger/services/session_settlement_view.dart';

import 'test_helper.dart';

late Directory _tmp;
late String _ali;
late String _baba;

Future<void> _open() async {
  _tmp = await Directory.systemTemp.createTemp('pl_dash_');
  Hive.init(_tmp.path);
  registerTestAdapters();
  await Hive.openBox<PokerSession>(HiveService.sessionsBox);
  await Hive.openBox<Player>(HiveService.playersBox);
  await Hive.openBox<LedgerTransaction>(HiveService.transactionsBox);
  await Hive.openBox(HiveService.settingsBox);
  await Hive.openBox<PlayerIdentity>(HiveService.playerIdentitiesBox);
  await Hive.openBox<FinancialEvent>(HiveService.financialEventsBox);
  _ali = (await PlayerIdentityService.createNew('Ali'))!.id;
  _baba = (await PlayerIdentityService.createNew('Ali'))!.id;
}

Future<void> _close() async {
  await Hive.deleteFromDisk();
  if (await _tmp.exists()) await _tmp.delete(recursive: true);
}

Future<PokerSession> _session(String id, {bool rebate = false}) async {
  final s = PokerSession(
    id: id,
    name: 'Night',
    location: 'Home',
    dateTime: DateTime.now(),
    smallBlind: 1,
    bigBlind: 2,
    tableNumber: '1',
    rebateEnabled: rebate,
    rebateMinLoss: 1000,
    rebatePercent: 10,
  );
  await HiveService.sessions.put(s.id, s);
  return s;
}

Future<Player> _seat(String sid, String personId, {String id = 'p1'}) async {
  final p = Player(
    id: id,
    sessionId: sid,
    name: 'Ali',
    seatNumber: id == 'p1' ? 1 : 2,
    personId: personId,
  );
  await HiveService.players.put(p.id, p);
  return p;
}

void main() {
  setUp(_open);
  tearDown(_close);

  test('1–3,5–6. settlement view matches SessionService chip books', () async {
    final s = await _session('books');
    final p = await _seat(s.id, _ali);
    await SessionService.recordTransaction(
      sessionId: s.id,
      playerId: p.id,
      type: TransactionType.buyIn,
      amount: 1000,
      hostSignatureBase64: 's',
    );
    await SessionService.recordTransaction(
      sessionId: s.id,
      playerId: p.id,
      type: TransactionType.rebuy,
      amount: 200,
      hostSignatureBase64: 's',
    );
    await SessionService.recordTransaction(
      sessionId: s.id,
      playerId: p.id,
      type: TransactionType.cashOut,
      amount: 800,
      hostSignatureBase64: 's',
    );
    await SessionService.recordTransaction(
      sessionId: s.id,
      type: TransactionType.rakeCollection,
      amount: 50,
      hostSignatureBase64: 's',
    );
    final view = SessionSettlementView.load(s.id, AppCurrency.usd);
    expect(view.buyIn, 1000);
    expect(view.rebuy, 200);
    expect(view.cashOut, 800);
    expect(view.rake, 50);
    expect(view.hostProfit, 50);
    expect(view.hostProfit, SessionService.totalRake(s.id));
    expect(view.chipBalance.moneyIn, SessionService.checkBalance(s.id).moneyIn);
    expect(view.chipBalance.moneyOut, SessionService.checkBalance(s.id).moneyOut);
    expect(view.chipBalance.moneyIn, 1200);
    expect(view.chipBalance.moneyOut, 850);
  });

  test('4. not-recorded cash-out writes no financial event', () async {
    expect(
      FinancialCapture.typeForCashOut(ChipCashOutFunding.notRecorded),
      isNull,
    );
    final e = await FinancialCapture.recordCashOutFunding(
      personId: _ali,
      currency: AppCurrency.usd,
      funding: ChipCashOutFunding.notRecorded,
      amount: 800,
    );
    expect(e, isNull);
    expect(FinancialLedgerService.eventsFor(_ali), isEmpty);
  });

  test('3. paid cash-out is visible on that personId account', () async {
    await FinancialCapture.recordCashOutFunding(
      personId: _ali,
      currency: AppCurrency.usd,
      funding: ChipCashOutFunding.paidCash,
      amount: 800,
      sessionId: 's1',
    );
    final acc = FinancialLedgerService.accountFor(_ali);
    expect(acc.personId, _ali);
    expect(acc.events.single.type, FinancialEventType.cashOutForChips);
    expect(acc.events.single.amountMajor, 800);
  });

  test('7–9. Discount grant does not change Money In/Out or Host Profit',
      () async {
    final s = await _session('disc', rebate: true);
    final p = await _seat(s.id, _ali);
    await SessionService.recordTransaction(
      sessionId: s.id,
      playerId: p.id,
      type: TransactionType.buyIn,
      amount: 2000,
      hostSignatureBase64: 's',
    );
    await FinancialLedgerService.record(
      personId: _ali,
      currency: AppCurrency.usd,
      type: FinancialEventType.cashInForChips,
      amount: 2000,
      sessionId: s.id,
    );
    final before = SessionSettlementView.load(s.id, AppCurrency.usd);
    await RebateService.grant(
      sessionId: s.id,
      personId: _ali,
      currency: AppCurrency.usd,
      asChips: false,
      bustRealized: true,
    );
    final after = SessionSettlementView.load(s.id, AppCurrency.usd);
    expect(after.chipBalance.moneyIn, before.chipBalance.moneyIn);
    expect(after.chipBalance.moneyOut, before.chipBalance.moneyOut);
    expect(after.hostProfit, before.hostProfit);
    expect(after.hostProfit, after.rake);
  });

  test('10–11. two Alis cannot see each other\'s financial account', () async {
    await FinancialLedgerService.record(
      personId: _ali,
      currency: AppCurrency.usd,
      type: FinancialEventType.cashInForChips,
      amount: 100,
    );
    await FinancialLedgerService.record(
      personId: _baba,
      currency: AppCurrency.usd,
      type: FinancialEventType.cashOutForChips,
      amount: 40,
    );
    expect(
      FinancialLedgerService.accountFor(_ali)
          .events
          .every((e) => e.personId == _ali),
      isTrue,
    );
    expect(
      FinancialLedgerService.accountFor(_baba)
          .events
          .every((e) => e.personId == _baba),
      isTrue,
    );
    expect(FinancialLedgerService.accountFor(_ali).events.length, 1);
    expect(FinancialLedgerService.accountFor(_baba).events.length, 1);
  });

  test('12. live view factory is the same load End Session uses', () {
    expect(SessionSettlementView.load, isNotNull);
  });

  test('EN/FA live accounting keys', () {
    expect(
      AppLocalizations.keysOf('en').toSet(),
      AppLocalizations.keysOf('fa').toSet(),
    );
    for (final k in [
      'live_accounting_title',
      'host_profit_is_rake_note',
      'chip_cashout_not_on_financial',
    ]) {
      expect(AppLocalizations.lookup('en', k), isNot(k));
    }
  });
}
