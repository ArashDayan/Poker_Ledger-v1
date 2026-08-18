// Phase 2 — Banker Discount workflow (UI status + frozen engine).
// Does not change RebateService formulas.
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
import 'package:poker_ledger/services/discount_workflow.dart';
import 'package:poker_ledger/services/financial_ledger_service.dart';
import 'package:poker_ledger/services/hive_service.dart';
import 'package:poker_ledger/services/player_identity_service.dart';
import 'package:poker_ledger/services/rebate_service.dart';
import 'package:poker_ledger/services/session_service.dart';

import 'test_helper.dart';

late Directory _tmp;
late String _personId;

Future<void> _open() async {
  _tmp = await Directory.systemTemp.createTemp('pl_disc_wf_');
  Hive.init(_tmp.path);
  registerTestAdapters();
  await Hive.openBox<PokerSession>(HiveService.sessionsBox);
  await Hive.openBox<Player>(HiveService.playersBox);
  await Hive.openBox<LedgerTransaction>(HiveService.transactionsBox);
  await Hive.openBox(HiveService.settingsBox);
  await Hive.openBox<PlayerIdentity>(HiveService.playerIdentitiesBox);
  await Hive.openBox<FinancialEvent>(HiveService.financialEventsBox);
  _personId = (await PlayerIdentityService.createNew('Ali'))!.id;
}

Future<void> _close() async {
  await Hive.deleteFromDisk();
  if (await _tmp.exists()) await _tmp.delete(recursive: true);
}

Future<PokerSession> _session({
  required String id,
  bool rebate = true,
  DateTime? start,
  DateTime? plannedEndAt,
  DateTime? endedAt,
}) async {
  final s = PokerSession(
    id: id,
    name: 'Night',
    location: 'Home',
    dateTime: start ?? DateTime(2026, 1, 1, 18),
    smallBlind: 1,
    bigBlind: 2,
    tableNumber: '1',
    rebateEnabled: rebate,
    rebateMinLoss: 1000,
    rebatePercent: 10,
    plannedEndAt: plannedEndAt,
    endedAt: endedAt,
    status: endedAt == null ? SessionStatus.active : SessionStatus.ended,
  );
  await HiveService.sessions.put(s.id, s);
  return s;
}

Future<void> _cashIn(String sessionId, double amount, {DateTime? at}) {
  return FinancialLedgerService.record(
    personId: _personId,
    currency: AppCurrency.usd,
    type: FinancialEventType.cashInForChips,
    amount: amount,
    sessionId: sessionId,
    occurredAt: at,
  );
}

Future<void> _cashOut(String sessionId, double amount, {DateTime? at}) {
  return FinancialLedgerService.record(
    personId: _personId,
    currency: AppCurrency.usd,
    type: FinancialEventType.cashOutForChips,
    amount: amount,
    sessionId: sessionId,
    occurredAt: at,
  );
}

void main() {
  setUp(_open);
  tearDown(_close);

  test('1. Discount disabled — cannot grant', () async {
    final s = await _session(id: 'off', rebate: false);
    await _cashIn(s.id, 2000);
    await _cashOut(s.id, 0);
    final view = DiscountWorkflowView.inspect(
      sessionId: s.id,
      currency: AppCurrency.usd,
      personId: _personId,
    );
    expect(view.kind, DiscountWorkflowKind.disabled);
    expect(view.canGrant, isFalse);
    expect(view.config.isUsable, isFalse);
    expect(
      () => RebateService.grant(
        sessionId: s.id,
        personId: _personId,
        currency: AppCurrency.usd,
        asChips: false,
        bustRealized: true,
      ),
      throwsA(isA<FinancialLedgerException>()),
    );
  });

  test('2–3. Enabled config and plannedEndAt persist on the session', () async {
    final end = DateTime(2026, 1, 2, 6);
    final s = await _session(id: 'on', plannedEndAt: end);
    expect(RebateService.configFor(s.id).isUsable, isTrue);
    expect(RebateService.configFor(s.id).percent, 10);
    expect(s.plannedEndAt, end);
    final round = PokerSession.fromJson(s.toJson());
    expect(round.plannedEndAt, end);
    expect(round.rebateEnabled, isTrue);
    expect(RebateService.effectivePeriodEnd(round), end);
  });

  test('4–5. Eligibility uses occurredAt; endedAt does not rewrite the period',
      () async {
    final start = DateTime(2026, 1, 1, 12);
    final periodEnd = DateTime(2026, 1, 2, 0);
    final s = await _session(
      id: 'period',
      start: start,
      plannedEndAt: periodEnd,
      endedAt: DateTime(2026, 1, 1, 18),
    );
    await _cashIn(s.id, 2000, at: DateTime(2026, 1, 1, 14));
    await _cashOut(s.id, 200, at: DateTime(2026, 1, 1, 15));
    final inPeriod = RebateService.suggest(
      sessionId: s.id,
      personId: _personId,
      currency: AppCurrency.usd,
    );
    expect(inPeriod.canGrant, isTrue);

    final s2 = await _session(
      id: 'late',
      start: start,
      plannedEndAt: periodEnd,
    );
    await _cashIn(s2.id, 2000, at: DateTime(2026, 1, 2, 2));
    await _cashOut(s2.id, 200, at: DateTime(2026, 1, 2, 3));
    final late = RebateService.suggest(
      sessionId: s2.id,
      personId: _personId,
      currency: AppCurrency.usd,
    );
    expect(late.canGrant, isFalse);
    expect(late.blockReason, contains('period'));
  });

  test('6–7. Discount is session-scoped and does not carry to a new session',
      () async {
    final a = await _session(id: 'a');
    await _cashIn(a.id, 2000);
    await RebateService.grant(
      sessionId: a.id,
      personId: _personId,
      currency: AppCurrency.usd,
      asChips: false,
      bustRealized: true,
    );
    expect(
      RebateService.snapshot(
        sessionId: a.id,
        personId: _personId,
        currency: AppCurrency.usd,
      ).granted,
      200,
    );
    final b = await _session(id: 'b');
    expect(
      RebateService.snapshot(
        sessionId: b.id,
        personId: _personId,
        currency: AppCurrency.usd,
      ).granted,
      0,
    );
    expect(
      RebateService.suggest(
        sessionId: b.id,
        personId: _personId,
        currency: AppCurrency.usd,
        bustRealized: true,
      ).canGrant,
      isFalse,
    );
  });

  test('8. Qualifying player is eligible for Review/Grant', () async {
    final s = await _session(id: 'qual');
    await _cashIn(s.id, 2000);
    await _cashOut(s.id, 200);
    final view = DiscountWorkflowView.inspect(
      sessionId: s.id,
      currency: AppCurrency.usd,
      personId: _personId,
    );
    expect(view.kind, DiscountWorkflowKind.eligible);
    expect(view.canGrant, isTrue);
    expect(view.canOpenReview, isTrue);
  });

  test('9. Non-qualifying / missing cash-out cannot grant', () async {
    final s = await _session(id: 'noq');
    await _cashIn(s.id, 2000);
    final view = DiscountWorkflowView.inspect(
      sessionId: s.id,
      currency: AppCurrency.usd,
      personId: _personId,
    );
    expect(view.kind, DiscountWorkflowKind.needsCashOut);
    expect(view.canGrant, isFalse);
  });

  test('10–12. Grant does not change Money In, Money Out or Host Profit',
      () async {
    final s = await _session(id: 'books');
    final p = Player(
      id: 'seat-1',
      sessionId: s.id,
      name: 'Ali',
      seatNumber: 1,
      personId: _personId,
    );
    await HiveService.players.put(p.id, p);
    await SessionService.recordTransaction(
      sessionId: s.id,
      playerId: p.id,
      type: TransactionType.buyIn,
      amount: 2000,
      hostSignatureBase64: 'sig',
    );
    await _cashIn(s.id, 2000);
    final before = SessionService.checkBalance(s.id);
    final profitBefore = SessionService.hostProfit(s.id);
    await RebateService.grant(
      sessionId: s.id,
      personId: _personId,
      currency: AppCurrency.usd,
      asChips: false,
      bustRealized: true,
    );
    final after = SessionService.checkBalance(s.id);
    expect(after.moneyIn, before.moneyIn);
    expect(after.moneyOut, before.moneyOut);
    expect(SessionService.hostProfit(s.id), profitBefore);
    expect(SessionService.hostProfit(s.id), SessionService.totalRake(s.id));
  });

  test('13. Frozen percent still 10% of qualifying own-cash loss', () async {
    final s = await _session(id: 'math');
    await _cashIn(s.id, 1500);
    final g = await RebateService.grant(
      sessionId: s.id,
      personId: _personId,
      currency: AppCurrency.usd,
      asChips: false,
      bustRealized: true,
    );
    expect(g.amountMajor, 150);
  });

  test('no identity is a blocked review, not a silent grant', () {
    final view = DiscountWorkflowView.inspect(
      sessionId: 'missing',
      currency: AppCurrency.usd,
      personId: null,
    );
    expect(view.kind, DiscountWorkflowKind.noIdentity);
    expect(view.canOpenReview, isFalse);
    expect(view.canGrant, isFalse);
  });

  test('EN/FA workflow keys stay in parity', () {
    expect(
      AppLocalizations.keysOf('en').toSet(),
      AppLocalizations.keysOf('fa').toSet(),
    );
    for (final key in [
      'discount_on',
      'discount_off',
      'discount_status_eligible',
      'discount_status_needs_cashout',
    ]) {
      expect(AppLocalizations.lookup('en', key), isNot(key));
      expect(AppLocalizations.lookup('fa', key), isNot(key));
    }
  });
}
