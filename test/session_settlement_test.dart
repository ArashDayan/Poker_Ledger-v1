// Step 5 — Session settlement views and void-linked financial flow.
//
// Does not change SessionService formulas. SessionService settlement
// tests remain the source of truth for chip books.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:poker_ledger/core/localization/app_localizations.dart';
import 'package:poker_ledger/models/enums.dart';
import 'package:poker_ledger/models/financial_event.dart';
import 'package:poker_ledger/models/hand.dart';
import 'package:poker_ledger/models/player.dart';
import 'package:poker_ledger/models/player_identity.dart';
import 'package:poker_ledger/models/session.dart';
import 'package:poker_ledger/models/table_participation.dart';
import 'package:poker_ledger/models/transaction.dart';
import 'package:poker_ledger/services/deposit_to_chips.dart';
import 'package:poker_ledger/services/financial_capture.dart';
import 'package:poker_ledger/services/financial_ledger_service.dart';
import 'package:poker_ledger/services/hive_service.dart';
import 'package:poker_ledger/services/player_identity_service.dart';
import 'package:poker_ledger/services/session_service.dart';
import 'package:poker_ledger/services/session_settlement_view.dart';

import 'test_helper.dart';

late Directory _tmp;
late String _personId;

Future<void> _open() async {
  _tmp = await Directory.systemTemp.createTemp('pl_settle_');
  Hive.init(_tmp.path);
  registerTestAdapters();
  await Hive.openBox<PokerSession>(HiveService.sessionsBox);
  await Hive.openBox<Player>(HiveService.playersBox);
  await Hive.openBox<LedgerTransaction>(HiveService.transactionsBox);
  await Hive.openBox(HiveService.settingsBox);
  await Hive.openBox<PlayerIdentity>(HiveService.playerIdentitiesBox);
  await Hive.openBox<FinancialEvent>(HiveService.financialEventsBox);
  await Hive.openBox<TableParticipation>(HiveService.participationsBox);
  await Hive.openBox<Hand>(HiveService.handsBox);
  _personId = (await PlayerIdentityService.createNew('Ali'))!.id;
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
  );
  await HiveService.sessions.put(s.id, s);
  return s;
}

Future<Player> _seat(String sessionId, {String id = 'seat-1'}) async {
  final p = Player(
    id: id,
    sessionId: sessionId,
    name: 'Ali',
    seatNumber: 1,
    personId: _personId,
  );
  await HiveService.players.put(p.id, p);
  return p;
}

void main() {
  setUp(_open);
  tearDown(_close);

  group('session-scoped financial reads', () {
    test('unconverted deposit does not increase Money In', () async {
      final s = await _session('s1');
      await FinancialCapture.recordFrontMoneyIn(
        personId: _personId,
        currency: AppCurrency.usd,
        amount: 1000,
        sessionId: s.id,
      );
      expect(SessionService.totalBuyIn(s.id), 0);
      expect(SessionService.checkBalance(s.id).moneyIn, 0);
      expect(SessionService.hostProfit(s.id), 0);
      final snap = FinancialLedgerService.snapshotForSession(
        s.id,
        currency: AppCurrency.usd,
      );
      expect(snap.depositRemaining, 1000);
      expect(snap.cashInForChips, 0);
    });

    test('deposit to chips updates deposit and writes events once', () async {
      final s = await _session('s2');
      final p = await _seat(s.id);
      await FinancialCapture.recordFrontMoneyIn(
        personId: _personId,
        currency: AppCurrency.usd,
        amount: 1000,
        sessionId: s.id,
      );
      await DepositToChips.convert(
        personId: _personId,
        sessionId: s.id,
        playerId: p.id,
        currency: AppCurrency.usd,
        amount: 600,
        hostSignatureBase64: 'sig',
      );
      final snap = FinancialLedgerService.snapshotForSession(
        s.id,
        currency: AppCurrency.usd,
      );
      expect(snap.depositIn, 1000);
      expect(snap.depositUsedForChips, 600);
      expect(snap.depositRemaining, 400);
      expect(snap.cashInForChips, 600);
      expect(SessionService.totalBuyIn(s.id), 600);
      expect(SessionService.checkBalance(s.id).moneyIn, 600);
      expect(
        HiveService.transactions.values
            .where((t) => t.sessionId == s.id && !t.isVoided)
            .length,
        1,
      );
    });

    test('returning deposit does not create a poker cash-out', () async {
      final s = await _session('s3');
      await FinancialCapture.recordFrontMoneyIn(
        personId: _personId,
        currency: AppCurrency.usd,
        amount: 400,
        sessionId: s.id,
      );
      await FinancialCapture.recordFrontMoneyOut(
        personId: _personId,
        currency: AppCurrency.usd,
        amount: 400,
        sessionId: s.id,
      );
      expect(SessionService.totalCashOut(s.id), 0);
      expect(SessionService.checkBalance(s.id).moneyOut, 0);
      final snap = FinancialLedgerService.snapshotForSession(
        s.id,
        currency: AppCurrency.usd,
      );
      expect(snap.depositReturned, 400);
      expect(snap.depositRemaining, 0);
      expect(snap.cashOutForChips, 0);
    });

    test('credit does not affect poker settlement', () async {
      final s = await _session('s4');
      await FinancialCapture.recordFunding(
        personId: _personId,
        currency: AppCurrency.usd,
        funding: ChipFunding.credit,
        amount: 200,
        sessionId: s.id,
      );
      expect(SessionService.checkBalance(s.id).moneyIn, 0);
      expect(SessionService.hostProfit(s.id), 0);
      expect(
        FinancialLedgerService.snapshotForSession(s.id, currency: AppCurrency.usd)
            .creditIssued,
        200,
      );
    });

    test('unbacked cash-out does not affect Host Profit', () async {
      final s = await _session('s5');
      await FinancialCapture.recordCashOutFunding(
        personId: _personId,
        currency: AppCurrency.usd,
        funding: ChipCashOutFunding.unbacked,
        amount: 80,
        sessionId: s.id,
      );
      expect(SessionService.hostProfit(s.id), 0);
      expect(SessionService.totalRake(s.id), 0);
    });

    test('session-scoped reads ignore another session', () async {
      final a = await _session('sa');
      final b = await _session('sb');
      await FinancialCapture.recordFrontMoneyIn(
        personId: _personId,
        currency: AppCurrency.usd,
        amount: 1000,
        sessionId: a.id,
      );
      await FinancialCapture.recordFrontMoneyIn(
        personId: _personId,
        currency: AppCurrency.usd,
        amount: 250,
        sessionId: b.id,
      );
      expect(
        FinancialLedgerService.snapshotForSession(a.id, currency: AppCurrency.usd)
            .depositRemaining,
        1000,
      );
      expect(
        FinancialLedgerService.snapshotForSession(b.id, currency: AppCurrency.usd)
            .depositRemaining,
        250,
      );
      expect(
        FinancialLedgerService.depositHeldMajor(_personId, AppCurrency.usd),
        1250,
      );
    });

    test('reversed financial events are excluded from session figures',
        () async {
      final s = await _session('s6');
      final e = await FinancialCapture.recordFrontMoneyIn(
        personId: _personId,
        currency: AppCurrency.usd,
        amount: 1000,
        sessionId: s.id,
      );
      await FinancialLedgerService.reverse(e!.id, reason: 'test');
      final snap = FinancialLedgerService.snapshotForSession(
        s.id,
        currency: AppCurrency.usd,
      );
      expect(snap.depositRemaining, 0);
      expect(snap.depositIn, 0);
      expect(FinancialLedgerService.eventsForSession(s.id), hasLength(2));
    });
  });

  group('void linked financial events', () {
    test('void detects linked events and reverse restores deposit', () async {
      final s = await _session('s7');
      final p = await _seat(s.id);
      await FinancialCapture.recordFrontMoneyIn(
        personId: _personId,
        currency: AppCurrency.usd,
        amount: 1000,
        sessionId: s.id,
      );
      final converted = await DepositToChips.convert(
        personId: _personId,
        sessionId: s.id,
        playerId: p.id,
        currency: AppCurrency.usd,
        amount: 600,
        hostSignatureBase64: 'sig',
      );
      final linked = FinancialLedgerService.activeEventsLinkedTo(
        converted.chipTransaction.id,
      );
      expect(linked, hasLength(2));
      expect(
        linked.map((e) => e.type),
        containsAll([
          FinancialEventType.frontMoneyOut,
          FinancialEventType.cashInForChips,
        ]),
      );

      await SessionService.voidTransaction(converted.chipTransaction.id);
      final reversed = await FinancialLedgerService.reverseLinkedTo(
        converted.chipTransaction.id,
        reason: 'test void',
      );
      expect(reversed, hasLength(2));
      expect(
        FinancialLedgerService.snapshotForSession(s.id, currency: AppCurrency.usd)
            .depositRemaining,
        1000,
      );
      expect(
        FinancialLedgerService.snapshotForSession(s.id, currency: AppCurrency.usd)
            .cashInForChips,
        0,
      );
      expect(SessionService.totalBuyIn(s.id), 0);
      // Originals remain in the journal.
      expect(
        FinancialLedgerService.eventsFor(_personId)
            .where((e) =>
                e.id == converted.frontMoneyOut.id ||
                e.id == converted.cashInForChips.id)
            .length,
        2,
      );
    });

    test('void only does not reverse financial events', () async {
      final s = await _session('s8');
      final p = await _seat(s.id);
      await FinancialCapture.recordFrontMoneyIn(
        personId: _personId,
        currency: AppCurrency.usd,
        amount: 1000,
        sessionId: s.id,
      );
      final converted = await DepositToChips.convert(
        personId: _personId,
        sessionId: s.id,
        playerId: p.id,
        currency: AppCurrency.usd,
        amount: 600,
        hostSignatureBase64: 'sig',
      );
      await SessionService.voidTransaction(converted.chipTransaction.id);
      expect(
        FinancialLedgerService.activeEventsLinkedTo(converted.chipTransaction.id),
        hasLength(2),
      );
      expect(
        FinancialLedgerService.snapshotForSession(s.id, currency: AppCurrency.usd)
            .depositRemaining,
        400,
      );
      expect(
        FinancialLedgerService.snapshotForSession(s.id, currency: AppCurrency.usd)
            .cashInForChips,
        600,
      );
    });

    test('unrelated financial events are never reversed', () async {
      final s = await _session('s9');
      final p = await _seat(s.id);
      await FinancialCapture.recordFrontMoneyIn(
        personId: _personId,
        currency: AppCurrency.usd,
        amount: 1000,
        sessionId: s.id,
      );
      final other = await FinancialCapture.recordFunding(
        personId: _personId,
        currency: AppCurrency.usd,
        funding: ChipFunding.credit,
        amount: 50,
        sessionId: s.id,
      );
      final converted = await DepositToChips.convert(
        personId: _personId,
        sessionId: s.id,
        playerId: p.id,
        currency: AppCurrency.usd,
        amount: 600,
        hostSignatureBase64: 'sig',
      );
      await FinancialLedgerService.reverseLinkedTo(converted.chipTransaction.id);
      expect(other!.isReversal, isFalse);
      expect(
        FinancialLedgerService.eventsFor(_personId)
            .where((e) => e.reversesEventId == other.id),
        isEmpty,
      );
      expect(
        FinancialLedgerService.snapshotForSession(s.id, currency: AppCurrency.usd)
            .creditIssued,
        50,
      );
    });
  });

  group('settlement view', () {
    test('dealer tips are in Money Out but not Host Profit', () async {
      final s = await _session('s10');
      await SessionService.recordTransaction(
        sessionId: s.id,
        type: TransactionType.rakeCollection,
        amount: 40,
      );
      await SessionService.recordTransaction(
        sessionId: s.id,
        type: TransactionType.dealerTips,
        amount: 10,
      );
      final view = SessionSettlementView.load(s.id, AppCurrency.usd);
      expect(view.hostProfit, 40);
      expect(view.rake, 40);
      expect(view.dealerTips, 10);
      expect(view.chipBalance.moneyOut, 50);
      expect(SessionService.hostProfit(s.id), SessionService.totalRake(s.id));
    });
  });

  group('localization', () {
    test('EN/FA settlement keys exist and differ', () {
      const keys = [
        'settle_poker_chips',
        'settle_financial_account',
        'settle_deposit',
        'money_out_cashout_rake_tips',
        'void_linked_title',
        'void_chip_only',
        'void_chip_and_reverse',
        'settle_warn_deposit',
      ];
      for (final key in keys) {
        final en = AppLocalizations.lookup('en', key);
        final fa = AppLocalizations.lookup('fa', key);
        expect(en, isNot(key), reason: key);
        expect(fa, isNot(key), reason: key);
        expect(en, isNot(fa), reason: key);
      }
    });
  });
}
