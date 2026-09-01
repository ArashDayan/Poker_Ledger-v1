// Phase 3 — Player Bank is identity-scoped.
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
import 'package:poker_ledger/providers/session_provider.dart';
import 'package:poker_ledger/services/financial_ledger_service.dart';
import 'package:poker_ledger/services/hive_service.dart';
import 'package:poker_ledger/services/player_history_service.dart';
import 'package:poker_ledger/services/player_identity_service.dart';
import 'package:poker_ledger/services/session_service.dart';

import 'test_helper.dart';

late Directory _tmp;

Future<void> _open() async {
  _tmp = await Directory.systemTemp.createTemp('pl_bank_');
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

Future<SessionProvider> _session(String id) async {
  final s = PokerSession(
    id: id,
    name: 'Night $id',
    location: 'Home',
    dateTime: DateTime.now(),
    smallBlind: 1,
    bigBlind: 2,
    tableNumber: '1',
  );
  await HiveService.sessions.put(s.id, s);
  return SessionProvider()..loadSession(s);
}

void main() {
  setUp(_open);
  tearDown(_close);

  test('1. first registration creates a persistent identity', () async {
    // ICR-03: creation is an explicit decision even when there is no
    // name suggestion; cancel is a zero-write path.
    final id = await PlayerIdentityService.resolveForSeating(
      name: 'Ali',
      confirm: (_) async => const IdentityLinkResult.createNew(),
    );
    expect(id, isNotNull);
    expect(PlayerIdentityService.byId(id!)!.displayName, 'Ali');
    final provider = await _session('s1');
    final seat = await provider.addPlayer(
      name: 'Ali',
      seatNumber: 1,
      personId: id,
    );
    expect(seat.id, isNot(id));
    expect(seat.personId, id);
  });

  test('2. returning player reuses the same identity', () async {
    final existing = await PlayerIdentityService.createNew('Ali');
    final again = await PlayerIdentityService.resolveForSeating(
      name: 'Ali',
      confirm: (hits) async => IdentityLinkResult.link(hits.single.id),
    );
    expect(again, existing!.id);
    expect(HiveService.playerIdentities.length, 1);
  });

  test('3–4. same name does not merge; different person is a new id', () async {
    final a = await PlayerIdentityService.createNew('Ali');
    final b = await PlayerIdentityService.resolveForSeating(
      name: 'Ali',
      confirm: (_) async => const IdentityLinkResult.createNew(),
    );
    expect(b, isNot(a!.id));
    expect(PlayerIdentityService.suggest('Ali'), hasLength(2));
  });

  test('5–10. Player Account and events are keyed by personId', () async {
    final aliA = await PlayerIdentityService.createNew('Ali');
    final aliB = await PlayerIdentityService.createNew('Ali');
    final s = await _session('money');
    final pA = await s.addPlayer(
        name: 'Ali', seatNumber: 1, personId: aliA!.id);
    final pB = await s.addPlayer(
        name: 'Ali', seatNumber: 2, personId: aliB!.id);
    await SessionService.recordTransaction(
      sessionId: s.current!.id,
      playerId: pA.id,
      type: TransactionType.buyIn,
      amount: 1000,
      hostSignatureBase64: 'sig',
    );
    await SessionService.recordTransaction(
      sessionId: s.current!.id,
      playerId: pA.id,
      type: TransactionType.rebuy,
      amount: 200,
      hostSignatureBase64: 'sig',
    );
    await SessionService.recordTransaction(
      sessionId: s.current!.id,
      playerId: pB.id,
      type: TransactionType.buyIn,
      amount: 500,
      hostSignatureBase64: 'sig',
    );
    await SessionService.recordTransaction(
      sessionId: s.current!.id,
      playerId: pB.id,
      type: TransactionType.cashOut,
      amount: 400,
      hostSignatureBase64: 'sig',
    );
    await FinancialLedgerService.record(
      personId: aliA.id,
      currency: AppCurrency.usd,
      type: FinancialEventType.cashInForChips,
      amount: 1200,
      sessionId: s.current!.id,
    );
    await FinancialLedgerService.record(
      personId: aliB.id,
      currency: AppCurrency.usd,
      type: FinancialEventType.cashOutForChips,
      amount: 400,
      sessionId: s.current!.id,
    );

    final accA = FinancialLedgerService.accountFor(aliA.id);
    final accB = FinancialLedgerService.accountFor(aliB.id);
    expect(accA.personId, aliA.id);
    expect(accB.personId, aliB.id);
    expect(accA.events.every((e) => e.personId == aliA.id), isTrue);
    expect(accB.events.every((e) => e.personId == aliB.id), isTrue);
    expect(accA.events.any((e) => e.personId == aliB.id), isFalse);
    expect(SessionService.playerBuyInOnly(s.current!.id, pA.id), 1000);
    expect(SessionService.playerRebuyOnly(s.current!.id, pA.id), 200);
    expect(SessionService.playerTotalCashOut(s.current!.id, pB.id), 400);

    final careerA = PlayerHistoryService.careerForPersonId(aliA.id);
    final careerB = PlayerHistoryService.careerForPersonId(aliB.id);
    expect(careerA.totalBuyIn, 1000);
    expect(careerA.totalRebuy, 200);
    expect(careerB.totalBuyIn, 500);
    expect(careerB.totalCashOut, 400);
    expect(careerA.personId, aliA.id);
    expect(careerB.personId, aliB.id);
  });

  test('11. Session Player id is not the Lifetime personId', () async {
    final person = await PlayerIdentityService.createNew('Sara');
    final provider = await _session('sep');
    final seat = await provider.addPlayer(
      name: 'Sara',
      seatNumber: 3,
      personId: person!.id,
    );
    expect(seat.id, isNot(person.id));
    expect(seat.sessionId, provider.current!.id);
    expect(seat.personId, person.id);
  });

  test('12. unlinked historic seats stay a legacy name group', () async {
    final provider = await _session('legacy');
    await provider.addPlayer(name: 'Old Ali', seatNumber: 1);
    final bank = PlayerHistoryService.bankCareers();
    expect(bank.where((c) => c.isLegacyNameGroup), isNotEmpty);
    expect(
      bank.where((c) => c.isLegacyNameGroup).every((c) => c.personId == null),
      isTrue,
    );
    final json = HiveService.players.values.first.toJson();
    expect(Player.fromJson(json).name, 'Old Ali');
  });

  test('bank search lists two Alis as two identities', () async {
    await PlayerIdentityService.createNew('Ali');
    await PlayerIdentityService.createNew('Ali');
    final hits = PlayerHistoryService.searchBank('ali');
    expect(hits.where((c) => c.hasPersistentIdentity), hasLength(2));
    expect(hits[0].personId, isNot(hits[1].personId));
  });

  test('EN/FA bank keys exist', () {
    expect(
      AppLocalizations.keysOf('en').toSet(),
      AppLocalizations.keysOf('fa').toSet(),
    );
    expect(AppLocalizations.lookup('en', 'identity_legacy_group'), isNot(
        'identity_legacy_group'));
  });
}
