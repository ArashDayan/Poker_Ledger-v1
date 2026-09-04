// Unit tests for the parts of Poker Ledger that actually have to be
// correct for real money to be trusted: the settlement engine, the
// zero-cash-out rule, rebuy eligibility math, and session locking.
//
// Run with: flutter test
//
// These use Hive.init() (the plain Dart core API, not initFlutter())
// against a fresh temp directory per test run, so they don't depend on
// any platform channel — just real Hive boxes with real data, exercised
// through the exact same HiveService/SessionService code the app uses.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:poker_ledger/models/player.dart';
import 'package:poker_ledger/models/player_identity.dart';
import 'package:poker_ledger/models/session.dart';
import 'package:poker_ledger/models/transaction.dart';
import 'package:poker_ledger/services/hive_service.dart';
import 'package:poker_ledger/services/session_service.dart';
import 'package:uuid/uuid.dart';
import 'test_helper.dart';

const _uuid = Uuid();
late Directory _tempDir;

Future<void> _openTestBoxes() async {
  _tempDir = await Directory.systemTemp.createTemp('poker_ledger_test_');
  Hive.init(_tempDir.path);
  registerTestAdapters();
  await Hive.openBox<PokerSession>(HiveService.sessionsBox);
  await Hive.openBox<Player>(HiveService.playersBox);
  await Hive.openBox<LedgerTransaction>(HiveService.transactionsBox);
  await Hive.openBox(HiveService.settingsBox);
  await Hive.openBox<PlayerIdentity>(HiveService.playerIdentitiesBox);
}

Future<void> _closeTestBoxes() async {
  await Hive.deleteFromDisk();
  if (await _tempDir.exists()) {
    await _tempDir.delete(recursive: true);
  }
}

PokerSession _makeSession({
  int rebuyLastLevel = 6,
  bool rebuyLevelEnforcementEnabled = true,
  int currentLevel = 1,
}) {
  final session = PokerSession(
    id: _uuid.v4(),
    name: 'Test Session',
    location: 'Test Room',
    dateTime: DateTime.now(),
    smallBlind: 1,
    bigBlind: 2,
    tableNumber: '1',
    rebuyLastLevel: rebuyLastLevel,
    rebuyLevelEnforcementEnabled: rebuyLevelEnforcementEnabled,
    currentLevel: currentLevel,
  );
  HiveService.sessions.put(session.id, session);
  return session;
}

Future<Player> _makePlayer(String sessionId, {int seat = 1, bool isActive = true}) async {
  final personId = _uuid.v4();
  final player = Player(
    id: _uuid.v4(),
    sessionId: sessionId,
    name: 'Player $seat',
    seatNumber: seat,
    isActive: isActive,
    personId: personId,
  );
  await HiveService.playerIdentities.put(
    personId,
    PlayerIdentity(id: personId, displayName: player.name),
  );
  await HiveService.players.put(player.id, player);
  return player;
}

void main() {
  setUp(() async {
    await _openTestBoxes();
  });

  tearDown(() async {
    await _closeTestBoxes();
  });

  group('Settlement engine — BalanceResult', () {
    test('a session with matching buy-ins and cash-outs is balanced', () async {
      final session = _makeSession();
      final p1 = await _makePlayer(session.id);

      await SessionService.recordTransaction(
        sessionId: session.id,
        playerId: p1.id,
        type: TransactionType.buyIn,
        amount: 1000,
        hostSignatureBase64: 'sig',
      );
      await SessionService.recordTransaction(
        sessionId: session.id,
        playerId: p1.id,
        type: TransactionType.cashOut,
        amount: 1000,
        hostSignatureBase64: 'sig',
      );

      final balance = SessionService.checkBalance(session.id);
      expect(balance.isBalanced, isTrue);
      expect(balance.discrepancy, 0);
    });

    test('a winner cashing out MORE than their buy-in is never blocked, and the '
        'session still balances once rake covers the difference', () async {
      final session = _makeSession();
      final winner = await _makePlayer(session.id, seat: 1);
      final loser = await _makePlayer(session.id, seat: 2);

      // Winner buys in for 2,000, ends up cashing out 5,000 (won from the loser).
      await SessionService.recordTransaction(
        sessionId: session.id,
        playerId: winner.id,
        type: TransactionType.buyIn,
        amount: 2000,
        hostSignatureBase64: 'sig',
      );
      await SessionService.recordTransaction(
        sessionId: session.id,
        playerId: loser.id,
        type: TransactionType.buyIn,
        amount: 3000,
        hostSignatureBase64: 'sig',
      );
      await SessionService.recordTransaction(
        sessionId: session.id,
        playerId: winner.id,
        type: TransactionType.cashOut,
        amount: 5000,
        hostSignatureBase64: 'sig',
      );
      await SessionService.recordTransaction(
        sessionId: session.id,
        playerId: loser.id,
        type: TransactionType.cashOut,
        amount: 0, // busted out completely — must be accepted
        hostSignatureBase64: 'sig',
      );

      final balance = SessionService.checkBalance(session.id);
      // Money in: 2000 + 3000 = 5000. Money out: 5000 + 0 = 5000. Balanced.
      expect(balance.isBalanced, isTrue);
      expect(SessionService.playerProfitLoss(session.id, winner.id), 3000);
      expect(SessionService.playerProfitLoss(session.id, loser.id), -3000);
    });

    test('a real discrepancy is reported with the correct sign and magnitude', () async {
      final session = _makeSession();
      final p1 = await _makePlayer(session.id);

      await SessionService.recordTransaction(
        sessionId: session.id,
        playerId: p1.id,
        type: TransactionType.buyIn,
        amount: 1000,
        hostSignatureBase64: 'sig',
      );
      // No cash-out recorded — Money In (1000) > Money Out (0).

      final balance = SessionService.checkBalance(session.id);
      expect(balance.isBalanced, isFalse);
      expect(balance.discrepancy, 1000);
      expect(balance.playersNeverCashedOut, contains(p1));
    });

    test('known issues (unsettled players) are reported separately from generic '
        'possible causes, and known issues come first conceptually', () async {
      final session = _makeSession();
      final p1 = await _makePlayer(session.id);
      await SessionService.recordTransaction(
        sessionId: session.id,
        playerId: p1.id,
        type: TransactionType.buyIn,
        amount: 500,
        hostSignatureBase64: 'sig',
      );

      final balance = SessionService.checkBalance(session.id);
      expect(balance.knownIssues, isNotEmpty);
      expect(balance.possibleCauses, isNotEmpty);
      // These must be two distinct lists, not merged into one.
      expect(balance.knownIssues, isNot(equals(balance.possibleCauses)));
    });

    test('a \$0 cash-out correctly counts as "cashed out", not "never cashed out"',
        () async {
      final session = _makeSession();
      final p1 = await _makePlayer(session.id);
      await SessionService.recordTransaction(
        sessionId: session.id,
        playerId: p1.id,
        type: TransactionType.buyIn,
        amount: 500,
        hostSignatureBase64: 'sig',
      );
      await SessionService.recordTransaction(
        sessionId: session.id,
        playerId: p1.id,
        type: TransactionType.cashOut,
        amount: 0,
        hostSignatureBase64: 'sig',
      );

      expect(SessionService.hasCashedOut(session.id, p1.id), isTrue);
      final balance = SessionService.checkBalance(session.id);
      expect(balance.playersNeverCashedOut, isEmpty);
    });
  });

  group('Transaction validation', () {
    test('cash-out of exactly 0 is accepted', () async {
      final session = _makeSession();
      final p1 = await _makePlayer(session.id);
      final tx = await SessionService.recordTransaction(
        sessionId: session.id,
        playerId: p1.id,
        type: TransactionType.cashOut,
        amount: 0,
        hostSignatureBase64: 'sig',
      );
      expect(tx.amount, 0);
    });

    test('a \$0 buy-in is rejected', () async {
      final session = _makeSession();
      final p1 = await _makePlayer(session.id);
      expect(
        () => SessionService.recordTransaction(
          sessionId: session.id,
          playerId: p1.id,
          type: TransactionType.buyIn,
          amount: 0,
          hostSignatureBase64: 'sig',
        ),
        throwsArgumentError,
      );
    });

    test('a negative amount is always rejected, regardless of type', () async {
      final session = _makeSession();
      final p1 = await _makePlayer(session.id);
      expect(
        () => SessionService.recordTransaction(
          sessionId: session.id,
          playerId: p1.id,
          type: TransactionType.cashOut,
          amount: -50,
          hostSignatureBase64: 'sig',
        ),
        throwsArgumentError,
      );
    });

    test('buy-in without a signature is rejected', () async {
      final session = _makeSession();
      final p1 = await _makePlayer(session.id);
      expect(
        () => SessionService.recordTransaction(
          sessionId: session.id,
          playerId: p1.id,
          type: TransactionType.buyIn,
          amount: 100,
        ),
        throwsStateError,
      );
    });

    test('rake collection does not require a signature', () async {
      final session = _makeSession();
      final tx = await SessionService.recordTransaction(
        sessionId: session.id,
        type: TransactionType.rakeCollection,
        amount: 50,
      );
      expect(tx.amount, 50);
    });

    test('a transaction recorded for an inactive player is flagged signedWhileAbsent',
        () async {
      final session = _makeSession();
      final p1 = await _makePlayer(session.id, isActive: false);
      final tx = await SessionService.recordTransaction(
        sessionId: session.id,
        playerId: p1.id,
        type: TransactionType.cashOut,
        amount: 10,
        hostSignatureBase64: 'sig',
      );
      expect(tx.signedWhileAbsent, isTrue);
    });

    test('a transaction for an active player is NOT flagged signedWhileAbsent',
        () async {
      final session = _makeSession();
      final p1 = await _makePlayer(session.id, isActive: true);
      final tx = await SessionService.recordTransaction(
        sessionId: session.id,
        playerId: p1.id,
        type: TransactionType.cashOut,
        amount: 10,
        hostSignatureBase64: 'sig',
      );
      expect(tx.signedWhileAbsent, isFalse);
    });
  });

  group('Session locking', () {
    test('recording a transaction on an ended session throws', () async {
      final session = _makeSession();
      session.status = SessionStatus.ended;
      await session.save();

      expect(
        () => SessionService.recordTransaction(
          sessionId: session.id,
          type: TransactionType.rakeCollection,
          amount: 10,
        ),
        throwsA(isA<SessionEndedException>()),
      );
    });

    test('voiding a transaction on an ended session throws', () async {
      final session = _makeSession();
      final p1 = await _makePlayer(session.id);
      final tx = await SessionService.recordTransaction(
        sessionId: session.id,
        playerId: p1.id,
        type: TransactionType.buyIn,
        amount: 100,
        hostSignatureBase64: 'sig',
      );

      session.status = SessionStatus.ended;
      await session.save();

      expect(
        () => SessionService.voidTransaction(tx.id),
        throwsA(isA<SessionEndedException>()),
      );
    });

    test('an active session accepts transactions normally', () async {
      final session = _makeSession(); // active by default
      final tx = await SessionService.recordTransaction(
        sessionId: session.id,
        type: TransactionType.rakeCollection,
        amount: 10,
      );
      expect(tx.amount, 10);
    });
  });

  group('Rebuy eligibility', () {
    test('a player with 0 rebuys is eligible at level 2', () async {
      final session = _makeSession(currentLevel: 2);
      final p1 = await _makePlayer(session.id);
      expect(SessionService.canRebuy(session, p1.id), isTrue);
    });

    test('a player is not eligible for a 2nd rebuy before level 4', () async {
      final session = _makeSession(currentLevel: 3);
      final p1 = await _makePlayer(session.id);
      await SessionService.recordTransaction(
        sessionId: session.id,
        playerId: p1.id,
        type: TransactionType.rebuy,
        amount: 100,
        hostSignatureBase64: 'sig',
      );
      // Allowed at level 3 is 3~/2 = 1. Already used 1. Not eligible for a 2nd.
      expect(SessionService.canRebuy(session, p1.id), isFalse);
    });

    test('disabling rebuyLevelEnforcementEnabled always allows a rebuy', () async {
      final session = _makeSession(currentLevel: 1, rebuyLevelEnforcementEnabled: false);
      final p1 = await _makePlayer(session.id);
      // At level 1 with enforcement on, allowed = 0 — normally ineligible.
      expect(SessionService.canRebuy(session, p1.id), isTrue);
    });
  });

  group('Outlier amount detection', () {
    test('an amount within normal range is not flagged', () async {
      final session = _makeSession();
      final p1 = await _makePlayer(session.id);
      await SessionService.recordTransaction(
        sessionId: session.id,
        playerId: p1.id,
        type: TransactionType.buyIn,
        amount: 1000,
        hostSignatureBase64: 'sig',
      );
      expect(SessionService.isAmountOutlier(session.id, 1200), isFalse);
    });

    test('an amount far larger than anything recorded so far is flagged '
        '(the classic extra-zero typo)', () async {
      final session = _makeSession();
      final p1 = await _makePlayer(session.id);
      await SessionService.recordTransaction(
        sessionId: session.id,
        playerId: p1.id,
        type: TransactionType.buyIn,
        amount: 1000,
        hostSignatureBase64: 'sig',
      );
      expect(SessionService.isAmountOutlier(session.id, 10000000), isTrue);
    });

    test('with no prior transactions, nothing is flagged as an outlier', () async {
      final session = _makeSession();
      expect(SessionService.isAmountOutlier(session.id, 999999999), isFalse);
    });
  });

  group('Player sample signature (specimen on file)', () {
    test('a player can be seated without a sample — it is never required',
        () async {
      final session = _makeSession();
      final p1 = await _makePlayer(session.id);
      expect(p1.hasSampleSignature, isFalse);
      expect(p1.sampleSignatureBase64, isNull);
      expect(p1.sampleSignatureAt, isNull);

      // ...and recording money for them still works normally.
      await SessionService.recordTransaction(
        sessionId: session.id,
        playerId: p1.id,
        type: TransactionType.buyIn,
        amount: 200,
        hostSignatureBase64: 'sig',
      );
      expect(SessionService.playerTotalIn(session.id, p1.id), 200);
    });

    test('a stored sample survives a save/reload round trip', () async {
      final session = _makeSession();
      final p1 = await _makePlayer(session.id);
      p1.sampleSignatureBase64 = 'BASE64SPECIMEN';
      p1.sampleSignatureAt = DateTime(2026, 8, 3, 21, 30);
      await p1.save();

      final reloaded = HiveService.players.get(p1.id)!;
      expect(reloaded.hasSampleSignature, isTrue);
      expect(reloaded.sampleSignatureBase64, 'BASE64SPECIMEN');
      expect(reloaded.sampleSignatureAt, DateTime(2026, 8, 3, 21, 30));
    });

    test('an empty-string sample does not count as having one', () async {
      final session = _makeSession();
      final p1 = await _makePlayer(session.id);
      p1.sampleSignatureBase64 = '';
      await p1.save();
      expect(HiveService.players.get(p1.id)!.hasSampleSignature, isFalse);
    });

    test('players created before this feature still load (null sample)',
        () async {
      // Hive returns null for fields that were never written by an older
      // build — the adapter must tolerate that rather than throw.
      final session = _makeSession();
      final p1 = await _makePlayer(session.id);
      final json = p1.toJson();
      json.remove('sampleSignatureBase64');
      json.remove('sampleSignatureAt');
      final restored = Player.fromJson(json);
      expect(restored.hasSampleSignature, isFalse);
      expect(restored.name, p1.name);
    });

    test('the sample is round-tripped through backup JSON', () async {
      final session = _makeSession();
      final p1 = await _makePlayer(session.id);
      p1.sampleSignatureBase64 = 'SPECIMEN';
      p1.sampleSignatureAt = DateTime(2026, 1, 2, 3, 4);
      final restored = Player.fromJson(p1.toJson());
      expect(restored.sampleSignatureBase64, 'SPECIMEN');
      expect(restored.sampleSignatureAt, DateTime(2026, 1, 2, 3, 4));
    });
  });

  group('Quick rake slots', () {
    test('a session stores exactly the five amounts the banker configured',
        () async {
      final session = _makeSession();
      session.quickRakeAmounts = [5, 10, 15, 20, 25];
      await session.save();
      expect(HiveService.sessions.get(session.id)!.quickRakeAmounts,
          [5, 10, 15, 20, 25]);
    });

    test('slot order is preserved, not sorted — muscle memory depends on it',
        () async {
      final session = _makeSession();
      session.quickRakeAmounts = [25, 5, 20, 10, 15];
      await session.save();
      expect(HiveService.sessions.get(session.id)!.quickRakeAmounts,
          [25, 5, 20, 10, 15]);
    });

    test('blank slots simply mean fewer buttons, never an error', () async {
      final session = _makeSession();
      session.quickRakeAmounts = [5, 10];
      await session.save();
      final stored = HiveService.sessions.get(session.id)!.quickRakeAmounts!;
      expect(stored.length, 2);
      expect(stored, [5, 10]);
    });

    test('a rake collected from a quick slot lands in the ledger like any '
        'other rake', () async {
      final session = _makeSession();
      session.quickRakeAmounts = [5, 10, 15, 20, 25];
      await session.save();

      await SessionService.recordTransaction(
        sessionId: session.id,
        type: TransactionType.rakeCollection,
        amount: 15,
        hostSignatureBase64: '',
      );
      expect(SessionService.totalRake(session.id), 15);
      expect(SessionService.hostProfit(session.id), 15);
    });
  });

  // ---------------------------------------------------------------------
  // Live refresh regression tests.
  //
  // The V2 bug was NOT wrong data — every getter reads Hive on demand, so
  // the numbers were always right the moment something repainted. The bug
  // was a missed repaint: several service methods write to Hive with a
  // direct HiveObject.save() without going through SessionProvider, so
  // nothing told the UI to rebuild and the banker had to reopen the
  // session. These tests lock in that a box write is observable, which is
  // exactly what SessionProvider's box watchers now key off.
  // ---------------------------------------------------------------------
  group('Live refresh — every mutation is observable on its Hive box', () {
    test('markPlayerSettled emits a players-box event', () async {
      final session = _makeSession();
      final p1 = await _makePlayer(session.id);
      final events = <BoxEvent>[];
      final sub = HiveService.players.watch().listen(events.add);

      await SessionService.markPlayerSettled(p1, settled: true);
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();

      expect(events, isNotEmpty,
          reason: 'settling a player must notify the UI without a reopen');
      expect(HiveService.players.get(p1.id)!.isActive, isFalse);
    });

    test('recordTransaction emits a transactions-box event', () async {
      final session = _makeSession();
      final p1 = await _makePlayer(session.id);
      final events = <BoxEvent>[];
      final sub = HiveService.transactions.watch().listen(events.add);

      await SessionService.recordTransaction(
        sessionId: session.id,
        playerId: p1.id,
        type: TransactionType.buyIn,
        amount: 200,
        hostSignatureBase64: 'sig',
      );
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();

      expect(events, isNotEmpty);
      expect(SessionService.playerTotalIn(session.id, p1.id), 200);
    });

    test('an in-place player edit (rename/reseat) emits an event', () async {
      final session = _makeSession();
      final p1 = await _makePlayer(session.id);
      final events = <BoxEvent>[];
      final sub = HiveService.players.watch().listen(events.add);

      // Exactly what the Edit Player sheet does: mutate fields, then save.
      p1.name = 'Renamed';
      p1.seatNumber = 7;
      await p1.save();
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();

      expect(events, isNotEmpty);
      final reloaded = HiveService.players.get(p1.id)!;
      expect(reloaded.name, 'Renamed');
      expect(reloaded.seatNumber, 7);
    });

    test('undoLast emits an event so totals repaint immediately', () async {
      final session = _makeSession();
      final p1 = await _makePlayer(session.id);
      await SessionService.recordTransaction(
        sessionId: session.id,
        playerId: p1.id,
        type: TransactionType.buyIn,
        amount: 500,
        hostSignatureBase64: 'sig',
      );
      expect(SessionService.totalBuyIn(session.id), 500);

      final events = <BoxEvent>[];
      final sub = HiveService.transactions.watch().listen(events.add);
      await SessionService.undoLast(session.id);
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();

      expect(events, isNotEmpty);
      // Voided transactions leave the totals — the ledger must reflect the
      // undo the instant it happens, not after a reopen.
      expect(SessionService.totalBuyIn(session.id), 0);
    });

    test('advanceLevel emits a sessions-box event', () async {
      final session = _makeSession();
      final events = <BoxEvent>[];
      final sub = HiveService.sessions.watch().listen(events.add);

      await SessionService.advanceLevel(session);
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();

      expect(events, isNotEmpty);
      expect(HiveService.sessions.get(session.id)!.currentLevel, 2);
    });

    test('a burst of writes still leaves the ledger exactly correct',
        () async {
      // Nine players seated back to back — the scenario that made the
      // stale UI obvious. Verifies coalescing never drops a write.
      final session = _makeSession();
      for (var i = 1; i <= 9; i++) {
        final p = await _makePlayer(session.id, seat: i);
        await SessionService.recordTransaction(
          sessionId: session.id,
          playerId: p.id,
          type: TransactionType.buyIn,
          amount: 200,
          hostSignatureBase64: 'sig',
        );
      }
      expect(SessionService.playersFor(session.id).length, 9);
      expect(SessionService.totalBuyIn(session.id), 1800);
      expect(SessionService.checkBalance(session.id).moneyIn, 1800);
    });
  });
}
