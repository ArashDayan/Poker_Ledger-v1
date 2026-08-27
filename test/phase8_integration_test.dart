// Phase 8 — product-integration locks (no new accounting rules).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:poker_ledger/models/financial_event.dart';
import 'package:poker_ledger/models/hand.dart';
import 'package:poker_ledger/models/player.dart';
import 'package:poker_ledger/models/player_identity.dart';
import 'package:poker_ledger/models/session.dart';
import 'package:poker_ledger/models/table_participation.dart';
import 'package:poker_ledger/models/transaction.dart';
import 'package:poker_ledger/providers/session_provider.dart';
import 'package:poker_ledger/services/hive_service.dart';
import 'package:poker_ledger/services/player_history_service.dart';
import 'package:poker_ledger/services/player_identity_service.dart';
import 'package:poker_ledger/services/session_service.dart';

import 'test_helper.dart';

late Directory _tmp;

Future<void> _open() async {
  _tmp = await Directory.systemTemp.createTemp('pl_p8_');
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
}

Future<void> _close() async {
  await Hive.deleteFromDisk();
  if (await _tmp.exists()) await _tmp.delete(recursive: true);
}

void main() {
  setUp(_open);
  tearDown(_close);

  test('create session persists Discount config on that session only', () async {
    final p = SessionProvider();
    final end = DateTime.now().add(const Duration(hours: 8));
    final a = await p.createSession(
      name: 'A',
      location: 'R',
      dateTime: DateTime.now(),
      smallBlind: 1,
      bigBlind: 2,
      rakePercentage: 5,
      tableNumber: '1',
      currency: AppCurrency.usd,
      rebateEnabled: true,
      rebateMinLoss: 1000,
      rebatePercent: 10,
      plannedEndAt: end,
    );
    final b = await p.createSession(
      name: 'B',
      location: 'R',
      dateTime: DateTime.now(),
      smallBlind: 1,
      bigBlind: 2,
      rakePercentage: 5,
      tableNumber: '1',
      currency: AppCurrency.usd,
      rebateEnabled: false,
    );
    expect(HiveService.sessions.get(a.id)!.rebateEnabled, isTrue);
    expect(HiveService.sessions.get(a.id)!.rebatePercent, 10);
    expect(HiveService.sessions.get(a.id)!.plannedEndAt, end);
    expect(HiveService.sessions.get(b.id)!.rebateEnabled, isFalse);
    expect(HiveService.sessions.get(b.id)!.plannedEndAt, isNull);
    p.dispose();
  });

  test('identity cancel writes no personId; createNew is a new person', () async {
    await PlayerIdentityService.createNew('Ali');
    final cancelled = await PlayerIdentityService.resolveForSeating(
      name: 'Ali',
      confirm: (_) async => const IdentityLinkResult.cancel(),
    );
    expect(cancelled, isNull);

    final created = await PlayerIdentityService.resolveForSeating(
      name: 'Ali',
      confirm: (_) async => const IdentityLinkResult.createNew(),
    );
    expect(created, isNotNull);
    expect(PlayerIdentityService.all().length, 2);
  });

  test('unlinked history career is a legacy name group, not a personId', () {
    final career = PlayerHistoryService.careerForName('Ali');
    expect(career.isLegacyNameGroup, isTrue);
    expect(career.personId, isNull);
  });

  test('host profit stays rake after a cash-out (no discount in books)',
      () async {
    final p = SessionProvider();
    final s = await p.createSession(
      name: 'N',
      location: 'R',
      dateTime: DateTime.now(),
      smallBlind: 1,
      bigBlind: 2,
      rakePercentage: 5,
      tableNumber: '1',
      currency: AppCurrency.usd,
    );
    final player = await p.addPlayer(name: 'Bo', seatNumber: 1);
    await p.recordTransaction(
      playerId: player.id,
      type: TransactionType.buyIn,
      amount: 200,
      hostSignatureBase64: 's',
    );
    await p.recordTransaction(
      playerId: player.id,
      type: TransactionType.cashOut,
      amount: 50,
      hostSignatureBase64: 's',
    );
    await p.recordTransaction(
      type: TransactionType.rakeCollection,
      amount: 10,
      hostSignatureBase64: 's',
    );
    expect(SessionService.hostProfit(s.id), 10);
    expect(SessionService.checkBalance(s.id).moneyIn, 200);
    expect(SessionService.checkBalance(s.id).moneyOut, 60);
    p.dispose();
  });
}
