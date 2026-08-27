// Session Timer pause/resume.
//
// The bug lived in PokerSession.elapsed, not in the refresh layer. It
// subtracted only `totalBreakSeconds` (breaks that had already FINISHED)
// and ignored `breakStartedAt` (a break still IN PROGRESS). So the clock
// kept advancing while the session sat ON BREAK, then snapped backwards
// when the banker resumed and endBreak() finally banked the break.
//
// elapsed is derived from timestamps, so these tests set the timestamps
// directly rather than sleeping — the same way the real app computes it.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:poker_ledger/models/enums.dart';
import 'package:poker_ledger/models/financial_event.dart';
import 'package:poker_ledger/models/hand.dart';
import 'package:poker_ledger/models/player.dart';
import 'package:poker_ledger/models/session.dart';
import 'package:poker_ledger/models/transaction.dart';
import 'package:poker_ledger/providers/session_provider.dart';
import 'package:poker_ledger/services/hive_service.dart';
import 'package:poker_ledger/services/table_service.dart';

import 'test_helper.dart';

late Directory _tmp;

Future<void> _open() async {
  _tmp = await Directory.systemTemp.createTemp('pl_session_timer_');
  Hive.init(_tmp.path);
  registerTestAdapters();
  await Hive.openBox<PokerSession>(HiveService.sessionsBox);
  await Hive.openBox<Player>(HiveService.playersBox);
  await Hive.openBox<LedgerTransaction>(HiveService.transactionsBox);
  await Hive.openBox(HiveService.settingsBox);
  await Hive.openBox<FinancialEvent>(HiveService.financialEventsBox);
  await Hive.openBox<Hand>(HiveService.handsBox);
}

Future<void> _close() async {
  await Hive.deleteFromDisk();
  if (await _tmp.exists()) await _tmp.delete(recursive: true);
}

/// A session that started [ago] before now, so elapsed is deterministic.
PokerSession _session({
  required Duration ago,
  int totalBreakSeconds = 0,
  Duration? onBreakFor,
  DateTime? endedAt,
}) {
  final now = DateTime.now();
  return PokerSession(
    id: 'session-1',
    name: 'Friday',
    location: 'Home',
    dateTime: now.subtract(ago),
    smallBlind: 1,
    bigBlind: 2,
    tableNumber: '1',
    totalBreakSeconds: totalBreakSeconds,
    breakStartedAt:
        onBreakFor == null ? null : now.subtract(onBreakFor),
    endedAt: endedAt,
  );
}

void main() {
  setUp(_open);
  tearDown(_close);

  group('1. running normally', () {
    test('elapsed tracks wall-clock time while active', () {
      final s = _session(ago: const Duration(minutes: 30));
      expect(s.elapsed.inMinutes, 30);
    });

    test('a finished break is excluded', () {
      final s = _session(
        ago: const Duration(minutes: 30),
        totalBreakSeconds: 300,
      );
      expect(s.elapsed.inMinutes, 25);
    });
  });

  group('2-3. pause freezes the clock', () {
    test('elapsed stops at the moment the break began', () {
      // Started 35m ago, on break for the last 5m -> 30m played.
      final s = _session(
        ago: const Duration(minutes: 35),
        onBreakFor: const Duration(minutes: 5),
      );
      expect(s.elapsed.inMinutes, 30);
    });

    test('waiting longer on break does not increase it', () {
      // Same 30m of play, but the break has run much longer.
      for (final wait in [1, 5, 30, 120]) {
        final s = _session(
          ago: Duration(minutes: 30 + wait),
          onBreakFor: Duration(minutes: wait),
        );
        expect(s.elapsed.inMinutes, 30,
            reason: 'after $wait minutes on break');
      }
    });

    test('status is ON BREAK while paused', () async {
      final s = _session(ago: const Duration(minutes: 30));
      await HiveService.sessions.put(s.id, s);
      final provider = SessionProvider()..loadSession(s);

      await provider.startBreak();

      final live = HiveService.sessions.get('session-1')!;
      expect(live.status, SessionStatus.onBreak);
      expect(live.breakStartedAt, isNotNull);
    });

    test('startBreak freezes elapsed immediately', () async {
      final s = _session(ago: const Duration(minutes: 30));
      await HiveService.sessions.put(s.id, s);
      final provider = SessionProvider()..loadSession(s);

      await provider.startBreak();
      final frozen = HiveService.sessions.get('session-1')!.elapsed;

      // Re-read repeatedly: the value must not drift.
      await Future<void>.delayed(const Duration(milliseconds: 30));
      final again = HiveService.sessions.get('session-1')!.elapsed;
      expect(again.inSeconds, frozen.inSeconds);
    });
  });

  group('4. resume continues from the frozen value', () {
    test('elapsed picks up where it stopped', () {
      // 30m played, 5m break already banked, now running again.
      final s = _session(
        ago: const Duration(minutes: 35),
        totalBreakSeconds: 300,
      );
      expect(s.elapsed.inMinutes, 30);
    });

    test('endBreak banks the break and clears the marker', () async {
      final s = _session(
        ago: const Duration(minutes: 35),
        onBreakFor: const Duration(minutes: 5),
      );
      await HiveService.sessions.put(s.id, s);
      final provider = SessionProvider()..loadSession(s);
      expect(s.elapsed.inMinutes, 30);

      await provider.endBreak();

      final live = HiveService.sessions.get('session-1')!;
      expect(live.status, SessionStatus.active);
      expect(live.breakStartedAt, isNull);
      expect(live.totalBreakSeconds, closeTo(300, 2));
      // No jump at the boundary — still 30 minutes.
      expect(live.elapsed.inMinutes, 30);
    });

    test('no double-subtraction across the resume boundary', () async {
      final s = _session(
        ago: const Duration(minutes: 35),
        onBreakFor: const Duration(minutes: 5),
      );
      await HiveService.sessions.put(s.id, s);
      final provider = SessionProvider()..loadSession(s);

      final before = s.elapsed.inSeconds;
      await provider.endBreak();
      final after = HiveService.sessions.get('session-1')!.elapsed.inSeconds;

      // The break must be counted once, not twice.
      expect((after - before).abs(), lessThanOrEqualTo(2));
    });
  });

  group('5. multiple pause/resume cycles', () {
    test('three cycles accumulate only played time', () async {
      // 30m of play split across 3 cycles, plus 21m of banked break.
      final s = _session(
        ago: const Duration(minutes: 51),
        totalBreakSeconds: 21 * 60,
      );
      expect(s.elapsed.inMinutes, 30);
    });

    test('a fourth break freezes on top of banked breaks', () {
      final s = _session(
        ago: const Duration(minutes: 61),
        totalBreakSeconds: 21 * 60,
        onBreakFor: const Duration(minutes: 10),
      );
      // 61 total - 21 banked - 10 in progress = 30 played.
      expect(s.elapsed.inMinutes, 30);
    });

    test('repeated startBreak does not double-count', () async {
      final s = _session(ago: const Duration(minutes: 30));
      await HiveService.sessions.put(s.id, s);
      final provider = SessionProvider()..loadSession(s);

      await provider.startBreak();
      final first = HiveService.sessions.get('session-1')!.breakStartedAt;
      await provider.startBreak();
      final second = HiveService.sessions.get('session-1')!.breakStartedAt;

      // Even if the marker is refreshed, elapsed stays frozen and
      // totalBreakSeconds is untouched until endBreak runs.
      expect(HiveService.sessions.get('session-1')!.totalBreakSeconds, 0);
      expect(first, isNotNull);
      expect(second, isNotNull);
    });
  });

  group('6. Table Timers remain independent', () {
    test('pausing the session does not touch any table clock', () async {
      final s = _session(ago: const Duration(minutes: 30));
      await HiveService.sessions.put(s.id, s);
      final provider = SessionProvider()..loadSession(s);
      await provider.addTable(name: 'Table 2');

      final live = HiveService.sessions.get('session-1')!;
      final ids = TableService.tablesFor(live).map((t) => t.id).toList();
      await TableService.startTableTimer(live, ids[1]);

      final beforeRunning =
          TableService.tableById(HiveService.sessions.get('session-1')!,
                  ids[1])
              .timerRunning;
      expect(beforeRunning, isTrue);

      await provider.startBreak();

      final after = TableService.tableById(
          HiveService.sessions.get('session-1')!, ids[1]);
      expect(after.timerRunning, isTrue,
          reason: 'a session break must not stop a table clock');
    });

    test('a table clock keeps advancing while the session is paused',
        () async {
      final s = _session(
        ago: const Duration(minutes: 35),
        onBreakFor: const Duration(minutes: 5),
      );
      await HiveService.sessions.put(s.id, s);

      final live = HiveService.sessions.get('session-1')!;
      await TableService.materialise(live);
      final id = TableService.tablesFor(live).first.id;
      await TableService.startTableTimer(live, id);

      // Session is frozen...
      expect(HiveService.sessions.get('session-1')!.elapsed.inMinutes, 30);
      // ...the table clock is a separate, still-running quantity.
      final t = TableService.tableById(
          HiveService.sessions.get('session-1')!, id);
      expect(t.timerRunning, isTrue);
    });
  });

  group('7. rebuilds never restart a paused clock', () {
    test('elapsed is idempotent across many reads while paused', () {
      final s = _session(
        ago: const Duration(minutes: 35),
        onBreakFor: const Duration(minutes: 5),
      );
      final values = <int>{};
      for (var i = 0; i < 50; i++) {
        values.add(s.elapsed.inMinutes);
      }
      expect(values, {30}, reason: 'no drift across rebuilds');
    });

    test('reloading from storage keeps the frozen value', () async {
      final s = _session(
        ago: const Duration(minutes: 35),
        onBreakFor: const Duration(minutes: 5),
      );
      await HiveService.sessions.put(s.id, s);

      await Hive.box<PokerSession>(HiveService.sessionsBox).close();
      await Hive.openBox<PokerSession>(HiveService.sessionsBox);

      expect(HiveService.sessions.get('session-1')!.elapsed.inMinutes, 30);
    });
  });

  group('edge cases', () {
    test('a session ended while on break reports time actually played',
        () {
      final now = DateTime.now();
      final s = PokerSession(
        id: 'session-1',
        name: 'F',
        location: 'H',
        dateTime: now.subtract(const Duration(minutes: 50)),
        smallBlind: 1,
        bigBlind: 2,
        tableNumber: '1',
        breakStartedAt: now.subtract(const Duration(minutes: 20)),
        endedAt: now.subtract(const Duration(minutes: 5)),
      );
      // 50m total, ended 5m ago -> 45m span; on break from 20m ago, so
      // the break ran 15m before the session ended -> 30m played.
      expect(s.elapsed.inMinutes, 30);
    });

    test('elapsed never goes negative', () {
      final now = DateTime.now();
      final s = PokerSession(
        id: 'session-1',
        name: 'F',
        location: 'H',
        dateTime: now,
        smallBlind: 1,
        bigBlind: 2,
        tableNumber: '1',
        totalBreakSeconds: 99999,
      );
      expect(s.elapsed, Duration.zero);
      expect(s.elapsed.isNegative, isFalse);
    });

    test('timeRemaining respects the frozen clock', () {
      final s = _session(
        ago: const Duration(minutes: 35),
        onBreakFor: const Duration(minutes: 5),
      )..plannedMinutes = 60;
      // 30m played of a 60m target -> 30m left, not 25m.
      expect(s.timeRemaining!.inMinutes, 30);
    });

    test('a session never paused behaves exactly as before', () {
      final s = _session(ago: const Duration(minutes: 42));
      expect(s.breakStartedAt, isNull);
      expect(s.elapsed.inMinutes, 42);
    });
  });
}
