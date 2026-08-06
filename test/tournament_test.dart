// Tournament mode tests.
//
// The priority is proving tournaments cannot disturb cash-game
// accounting: the settlement engine, balance check and every existing
// session must behave exactly as before.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:poker_ledger/models/player.dart';
import 'package:poker_ledger/models/session.dart';
import 'package:poker_ledger/models/transaction.dart';
import 'package:poker_ledger/services/hive_service.dart';
import 'package:poker_ledger/services/session_service.dart';
import 'package:poker_ledger/services/tournament_service.dart';
import 'package:uuid/uuid.dart';
import 'test_helper.dart';

const _uuid = Uuid();
late Directory _tmp;

Future<void> _open() async {
  _tmp = await Directory.systemTemp.createTemp('pl_tourney_');
  Hive.init(_tmp.path);
  registerTestAdapters();
  await Hive.openBox<PokerSession>(HiveService.sessionsBox);
  await Hive.openBox<Player>(HiveService.playersBox);
  await Hive.openBox<LedgerTransaction>(HiveService.transactionsBox);
  await Hive.openBox(HiveService.settingsBox);
}

Future<void> _close() async {
  await Hive.deleteFromDisk();
  if (await _tmp.exists()) await _tmp.delete(recursive: true);
}

PokerSession _tourney({double buyIn = 100, double fee = 10}) {
  final s = PokerSession(
    id: _uuid.v4(),
    name: 'Sunday Major',
    location: 'Room',
    dateTime: DateTime.now(),
    smallBlind: 25,
    bigBlind: 50,
    tableNumber: '1',
    mode: SessionMode.tournament,
    tournamentBuyIn: buyIn,
    tournamentFee: fee,
  );
  HiveService.sessions.put(s.id, s);
  return s;
}

Player _p(String sid, String name, {int seat = 1}) {
  final p = Player(id: _uuid.v4(), sessionId: sid, name: name, seatNumber: seat);
  HiveService.players.put(p.id, p);
  return p;
}

Future<void> _entry(String sid, String pid, double amt,
    {TransactionType type = TransactionType.buyIn}) async {
  await SessionService.recordTransaction(
    sessionId: sid,
    playerId: pid,
    type: type,
    amount: amt,
    hostSignatureBase64: 'sig',
  );
}

void main() {
  setUp(_open);
  tearDown(_close);

  group('Mode separation', () {
    test('sessions default to cash game, so old data is unaffected', () {
      final s = PokerSession(
        id: _uuid.v4(),
        name: 'Old',
        location: 'X',
        dateTime: DateTime.now(),
        smallBlind: 1,
        bigBlind: 2,
        tableNumber: '1',
      );
      expect(s.mode, SessionMode.cashGame);
      expect(s.isTournament, isFalse);
    });

    test('a cash game keeps its exact settlement behaviour', () async {
      final s = PokerSession(
        id: _uuid.v4(),
        name: 'Cash',
        location: 'X',
        dateTime: DateTime.now(),
        smallBlind: 1,
        bigBlind: 2,
        tableNumber: '1',
      );
      HiveService.sessions.put(s.id, s);
      final p = _p(s.id, 'A');
      await _entry(s.id, p.id, 500);
      await _entry(s.id, p.id, 500, type: TransactionType.cashOut);
      final bal = SessionService.checkBalance(s.id);
      expect(bal.isBalanced, isTrue);
      expect(bal.moneyIn, 500);
      expect(bal.moneyOut, 500);
    });

    test('tournament data round-trips through storage', () async {
      final s = _tourney();
      await TournamentService.saveStructure(s, [
        const BlindLevel(smallBlind: 25, bigBlind: 50, minutes: 20),
        const BlindLevel(smallBlind: 0, bigBlind: 0, minutes: 10, isBreak: true),
      ]);
      final r = HiveService.sessions.get(s.id)!;
      expect(r.isTournament, isTrue);
      expect(TournamentService.levelsFor(r).length, 2);
      expect(TournamentService.levelsFor(r)[1].isBreak, isTrue);
    });
  });

  group('Prize pool', () {
    test('pool is entries minus the house fee', () async {
      final s = _tourney(buyIn: 100, fee: 10);
      for (var i = 1; i <= 5; i++) {
        await _entry(s.id, _p(s.id, 'P$i', seat: i).id, 100);
      }
      expect(TournamentService.entryCount(s), 5);
      expect(TournamentService.totalCollected(s.id), 500);
      expect(TournamentService.houseFee(s), 50);
      expect(TournamentService.prizePool(s), 450);
    });

    test('rebuys feed the prize pool', () async {
      final s = _tourney(buyIn: 100, fee: 0);
      final p = _p(s.id, 'A');
      await _entry(s.id, p.id, 100);
      await _entry(s.id, p.id, 100, type: TransactionType.rebuy);
      expect(TournamentService.prizePool(s), 200);
    });

    test('payout percentages split the pool exactly', () async {
      final s = _tourney(buyIn: 100, fee: 0);
      for (var i = 1; i <= 9; i++) {
        await _entry(s.id, _p(s.id, 'P$i', seat: i).id, 100);
      }
      await TournamentService.savePayouts(s, [50, 30, 20]);
      final table = TournamentService.payoutTable(s);
      expect(table.length, 3);
      expect(table[0].amount, 450);
      expect(table[1].amount, 270);
      expect(table[2].amount, 180);
      final sum = table.fold<double>(0, (a, b) => a + b.amount);
      expect(sum, closeTo(TournamentService.prizePool(s), 0.01));
    });

    test('pool never goes negative when the fee exceeds entries', () async {
      final s = _tourney(buyIn: 10, fee: 1000);
      await _entry(s.id, _p(s.id, 'A').id, 10);
      expect(TournamentService.prizePool(s), 0);
    });
  });

  group('Eliminations and rankings', () {
    test('finishing positions count down from the field size', () async {
      final s = _tourney();
      final ps = [for (var i = 1; i <= 4; i++) _p(s.id, 'P$i', seat: i)];
      expect(await TournamentService.eliminatePlayer(s, ps[0]), 4);
      expect(await TournamentService.eliminatePlayer(s, ps[1]), 3);
      expect(await TournamentService.eliminatePlayer(s, ps[2]), 2);
      // One left — the champion is finalised, not "eliminated".
      final winner = await TournamentService.finaliseWinner(s);
      expect(winner?.id, ps[3].id);
      expect(ps[3].finishPosition, 1);
    });

    test('an elimination can be undone', () async {
      final s = _tourney();
      final a = _p(s.id, 'A', seat: 1);
      _p(s.id, 'B', seat: 2);
      await TournamentService.eliminatePlayer(s, a);
      expect(a.isEliminated, isTrue);
      await TournamentService.reinstatePlayer(s, a);
      expect(a.isEliminated, isFalse);
      expect(TournamentService.activePlayers(s.id).length, 2);
    });

    test('eliminating twice does not change the position', () async {
      final s = _tourney();
      final a = _p(s.id, 'A', seat: 1);
      _p(s.id, 'B', seat: 2);
      final first = await TournamentService.eliminatePlayer(s, a);
      final second = await TournamentService.eliminatePlayer(s, a);
      expect(second, first);
    });

    test('eliminated players are listed in finishing order', () async {
      final s = _tourney();
      final ps = [for (var i = 1; i <= 3; i++) _p(s.id, 'P$i', seat: i)];
      await TournamentService.eliminatePlayer(s, ps[0]);
      await TournamentService.eliminatePlayer(s, ps[1]);
      final out = TournamentService.eliminatedPlayers(s.id);
      expect(out.first.finishPosition, 2);
      expect(out.last.finishPosition, 3);
    });
  });

  group('Blind clock', () {
    test('pausing banks elapsed time instead of losing it', () async {
      final s = _tourney();
      await TournamentService.saveStructure(
          s, [const BlindLevel(smallBlind: 25, bigBlind: 50, minutes: 20)]);
      await TournamentService.startTimer(s);
      expect(s.blindTimerRunning, isTrue);
      await TournamentService.pauseTimer(s);
      expect(s.blindTimerRunning, isFalse);
      expect(s.levelElapsedSeconds, greaterThanOrEqualTo(0));
      expect(s.levelStartedAt, isNull);
    });

    test('advancing a level resets the clock and the alerts', () async {
      final s = _tourney();
      await TournamentService.saveStructure(s, [
        const BlindLevel(smallBlind: 25, bigBlind: 50, minutes: 20),
        const BlindLevel(smallBlind: 50, bigBlind: 100, minutes: 20),
      ]);
      s.levelElapsedSeconds = 600;
      s.blindNoticesShown = ['10m'];
      await TournamentService.advanceLevel(s);
      expect(s.currentBlindIndex, 1);
      expect(s.levelElapsedSeconds, 0);
      expect(s.blindNoticesShown, isEmpty);
      expect(TournamentService.currentLevel(s).bigBlind, 100);
    });

    test('level index never runs off the end of the structure', () async {
      final s = _tourney();
      await TournamentService.saveStructure(
          s, [const BlindLevel(smallBlind: 25, bigBlind: 50, minutes: 20)]);
      await TournamentService.advanceLevel(s);
      expect(s.currentBlindIndex, 0);
      await TournamentService.previousLevel(s);
      expect(s.currentBlindIndex, 0);
    });

    test('remaining time is clamped at zero', () async {
      final s = _tourney();
      await TournamentService.saveStructure(
          s, [const BlindLevel(smallBlind: 25, bigBlind: 50, minutes: 1)]);
      s.levelElapsedSeconds = 9999;
      expect(TournamentService.remainingInLevel(s), Duration.zero);
      expect(TournamentService.levelComplete(s), isTrue);
    });

    test('the default structure includes breaks and rising blinds', () {
      final levels = TournamentService.defaultStructure(startingBigBlind: 50);
      expect(levels.length, greaterThan(10));
      expect(levels.any((l) => l.isBreak), isTrue);
      final real = levels.where((l) => !l.isBreak).toList();
      expect(real.last.bigBlind, greaterThan(real.first.bigBlind));
    });
  });
}
