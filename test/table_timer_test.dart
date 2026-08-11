// Issue #2 — independent per-table countdown timers.
//
// The display bug (frozen seconds) is a widget-repaint concern and is
// covered by TableTimerDisplay owning its own ticker; what is asserted
// here is everything that must be TRUE UNDERNEATH that display:
// timestamp-derived accuracy, per-table independence, duration storage,
// pause/resume, clamping at zero, auto-stop, and a one-shot notice.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:poker_ledger/models/enums.dart';
import 'package:poker_ledger/models/player.dart';
import 'package:poker_ledger/models/session.dart';
import 'package:poker_ledger/models/transaction.dart';
import 'package:poker_ledger/providers/session_provider.dart';
import 'package:poker_ledger/services/hive_service.dart';
import 'package:poker_ledger/services/table_service.dart';
import 'package:poker_ledger/widgets/table_timer_display.dart';

import 'test_helper.dart';

late Directory _tmp;

Future<void> _open() async {
  _tmp = await Directory.systemTemp.createTemp('pl_tabletimer_');
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

Future<PokerSession> _session() async {
  final s = PokerSession(
    id: 'session-1',
    name: 'Friday',
    location: 'Home',
    dateTime: DateTime.now(),
    smallBlind: 1,
    bigBlind: 2,
    tableNumber: '1',
  );
  await HiveService.sessions.put(s.id, s);
  return s;
}

PokerSession get _live => HiveService.sessions.get('session-1')!;

PokerTable _table(String id) =>
    TableService.tablesFor(_live).firstWhere((t) => t.id == id);

/// Rewrites a table's stored clock so a countdown can be placed at an
/// arbitrary point without waiting in real time.
Future<void> _setClock(
  String tableId, {
  int? bankedSeconds,
  DateTime? runningSince,
  bool clearRunning = false,
}) async {
  final session = _live;
  final tables = TableService.tablesFor(session).map((t) {
    if (t.id != tableId) return t;
    return t.copyWith(
      bankedSeconds: bankedSeconds ?? t.bankedSeconds,
      runningSince: runningSince,
      clearRunningSince: clearRunning,
    );
  }).toList();
  session.tables = tables.map((t) => t.toMap()).toList();
  await session.save();
}

void main() {
  setUp(_open);
  tearDown(_close);

  group('1-2. clock formatting (hours, minutes and seconds)', () {
    test('formats HH:MM:SS across the whole range', () {
      expect(formatTableClock(Duration.zero), '00:00:00');
      expect(formatTableClock(const Duration(seconds: 1)), '00:00:01');
      expect(formatTableClock(const Duration(seconds: 59)), '00:00:59');
      expect(formatTableClock(const Duration(minutes: 1)), '00:01:00');
      expect(formatTableClock(const Duration(minutes: 90)), '01:30:00');
      // The exact sequence from the report.
      expect(formatTableClock(const Duration(hours: 1, minutes: 29, seconds: 57)),
          '01:29:57');
      expect(formatTableClock(const Duration(hours: 1, minutes: 29, seconds: 58)),
          '01:29:58');
      expect(formatTableClock(const Duration(hours: 1, minutes: 29, seconds: 59)),
          '01:29:59');
      expect(formatTableClock(const Duration(hours: 1, minutes: 30)), '01:30:00');
    });

    test('never renders negative time', () {
      expect(formatTableClock(const Duration(seconds: -5)), '00:00:00');
    });

    test('the whole field advances, not just the seconds', () {
      // Crossing an hour boundary must roll all three components.
      expect(formatTableClock(const Duration(hours: 1, seconds: -1)),
          '00:59:59');
      expect(formatTableClock(const Duration(hours: 2)), '02:00:00');
    });
  });

  group('3. elapsed is timestamp-derived, not a counter', () {
    test('elapsed grows from runningSince without any ticking', () async {
      final session = await _session();
      await TableService.materialise(session);
      final id = TableService.tablesFor(_live).first.id;

      await _setClock(id,
          runningSince: DateTime.now().subtract(const Duration(seconds: 42)));

      // No timer ran; the value is derived purely from the timestamp,
      // which is why navigation and rebuilds cannot corrupt it.
      expect(_table(id).elapsed.inSeconds, greaterThanOrEqualTo(42));
      expect(_table(id).timerRunning, isTrue);
    });
  });

  group('4. durations are stored per table', () {
    test('60 / 90 / 120 and a custom value all persist', () async {
      final session = await _session();
      await TableService.materialise(session);
      final id = TableService.tablesFor(_live).first.id;

      for (final mins in [60, 90, 120, 45]) {
        await TableService.setTableTimerDuration(_live, id, mins);
        expect(_table(id).plannedMinutes, mins);
        expect(_table(id).hasTimer, isTrue);
        expect(_table(id).timeRemaining, Duration(minutes: mins));
      }
    });

    test('a duration survives a reload from storage', () async {
      final session = await _session();
      await TableService.materialise(session);
      final id = TableService.tablesFor(_live).first.id;
      await TableService.setTableTimerDuration(_live, id, 90);

      await Hive.box<PokerSession>(HiveService.sessionsBox).close();
      await Hive.openBox<PokerSession>(HiveService.sessionsBox);

      expect(_table(id).plannedMinutes, 90);
    });

    test('null clears the duration and reverts to counting up', () async {
      final session = await _session();
      await TableService.materialise(session);
      final id = TableService.tablesFor(_live).first.id;

      await TableService.setTableTimerDuration(_live, id, 90);
      await TableService.setTableTimerDuration(_live, id, null);

      expect(_table(id).hasTimer, isFalse);
      expect(_table(id).plannedMinutes, isNull);
      expect(_table(id).timeRemaining, isNull);
    });
  });

  group('5-6. pause preserves, resume continues', () {
    test('pausing banks the elapsed time and stops the clock', () async {
      final session = await _session();
      await TableService.materialise(session);
      final id = TableService.tablesFor(_live).first.id;
      await TableService.setTableTimerDuration(_live, id, 90);

      await _setClock(id,
          runningSince: DateTime.now().subtract(const Duration(minutes: 10)));
      await TableService.pauseTableTimer(_live, id);

      final t = _table(id);
      expect(t.timerRunning, isFalse);
      expect(t.bankedSeconds, closeTo(600, 2));
      expect(t.timeRemaining!.inMinutes, 80);
    });

    test('remaining time does not move while paused', () async {
      final session = await _session();
      await TableService.materialise(session);
      final id = TableService.tablesFor(_live).first.id;
      await TableService.setTableTimerDuration(_live, id, 60);
      await _setClock(id, bankedSeconds: 900, clearRunning: true);

      final first = _table(id).timeRemaining;
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(_table(id).timeRemaining, first);
    });

    test('resume continues from the banked time, not from zero', () async {
      final session = await _session();
      await TableService.materialise(session);
      final id = TableService.tablesFor(_live).first.id;
      await TableService.setTableTimerDuration(_live, id, 90);
      await _setClock(id, bankedSeconds: 1800, clearRunning: true); // 30 min

      await TableService.startTableTimer(_live, id);

      final t = _table(id);
      expect(t.timerRunning, isTrue);
      expect(t.elapsed.inSeconds, greaterThanOrEqualTo(1800));
      expect(t.timeRemaining!.inMinutes, lessThanOrEqualTo(60));
    });

    test('stop returns to zero but keeps the chosen duration', () async {
      final session = await _session();
      await TableService.materialise(session);
      final id = TableService.tablesFor(_live).first.id;
      await TableService.setTableTimerDuration(_live, id, 90);
      await _setClock(id, bankedSeconds: 1800, clearRunning: true);

      await TableService.stopTableTimer(_live, id);

      final t = _table(id);
      expect(t.timerRunning, isFalse);
      expect(t.bankedSeconds, 0);
      expect(t.elapsed, Duration.zero);
      expect(t.plannedMinutes, 90, reason: 'duration is kept for restart');
      expect(t.timeRemaining, const Duration(minutes: 90));
    });
  });

  group('7. persistence across rebuilds / navigation', () {
    test('a running countdown is unaffected by reload', () async {
      final session = await _session();
      await TableService.materialise(session);
      final id = TableService.tablesFor(_live).first.id;
      await TableService.setTableTimerDuration(_live, id, 90);
      await _setClock(id,
          runningSince: DateTime.now().subtract(const Duration(minutes: 20)));

      final before = _table(id).timeRemaining!.inMinutes;

      await Hive.box<PokerSession>(HiveService.sessionsBox).close();
      await Hive.openBox<PokerSession>(HiveService.sessionsBox);

      expect(_table(id).timerRunning, isTrue);
      expect(_table(id).timeRemaining!.inMinutes, before);
    });
  });

  group('8-10. completion', () {
    test('remaining reaches exactly zero and clamps there', () async {
      final session = await _session();
      await TableService.materialise(session);
      final id = TableService.tablesFor(_live).first.id;
      await TableService.setTableTimerDuration(_live, id, 60);

      // Overrun by ten minutes: must read 00:00:00, never negative.
      await _setClock(id, bankedSeconds: 70 * 60, clearRunning: true);

      final t = _table(id);
      expect(t.timeRemaining, Duration.zero);
      expect(t.timeRemaining!.isNegative, isFalse);
      expect(t.isFinished, isTrue);
      expect(formatTableClock(t.timeRemaining!), '00:00:00');
    });

    test('a finished countdown auto-stops and lands on the exact duration',
        () async {
      final session = await _session();
      await TableService.materialise(session);
      final id = TableService.tablesFor(_live).first.id;
      await TableService.setTableTimerDuration(_live, id, 60);
      await _setClock(id,
          runningSince: DateTime.now().subtract(const Duration(minutes: 61)));

      final provider = SessionProvider()..loadSession(_live);
      final notice = provider.consumeTableTimerNotice();

      expect(notice, isNotNull);
      final t = _table(id);
      expect(t.timerRunning, isFalse, reason: 'must stop automatically');
      expect(t.bankedSeconds, const Duration(minutes: 60).inSeconds);
      expect(t.timeRemaining, Duration.zero);
    });

    test('a table with no duration never finishes', () async {
      final session = await _session();
      await TableService.materialise(session);
      final id = TableService.tablesFor(_live).first.id;
      await _setClock(id, bankedSeconds: 99999, clearRunning: true);

      expect(_table(id).hasTimer, isFalse);
      expect(_table(id).isFinished, isFalse);

      final provider = SessionProvider()..loadSession(_live);
      expect(provider.consumeTableTimerNotice(), isNull);
      provider.dispose();
    });

    test('a finished timer cannot be restarted into negative time',
        () async {
      final session = await _session();
      await TableService.materialise(session);
      final id = TableService.tablesFor(_live).first.id;
      await TableService.setTableTimerDuration(_live, id, 60);
      await _setClock(id, bankedSeconds: 60 * 60, clearRunning: true);

      await TableService.startTableTimer(_live, id);

      expect(_table(id).timerRunning, isFalse);
      expect(_table(id).timeRemaining, Duration.zero);
    });
  });

  group('11-12. the notice', () {
    test('fires exactly once and names the right table', () async {
      final session = await _session();
      await TableService.materialise(session);
      await TableService.addTable(_live, name: 'Table 2');
      final t2 = TableService.tablesFor(_live).last;

      await TableService.setTableTimerDuration(_live, t2.id, 90);
      await _setClock(t2.id,
          runningSince: DateTime.now().subtract(const Duration(minutes: 91)));

      final provider = SessionProvider()..loadSession(_live);

      final first = provider.consumeTableTimerNotice();
      expect(first, isNotNull);
      expect(first!.tableId, t2.id);
      expect(first.tableName, 'Table 2');
      expect(first.plannedMinutes, 90);

      // Polled every second by the shell — must not repeat.
      expect(provider.consumeTableTimerNotice(), isNull);
      expect(provider.consumeTableTimerNotice(), isNull);
      provider.dispose();
    });

    test('the notice flag survives a reload, so it cannot re-fire',
        () async {
      final session = await _session();
      await TableService.materialise(session);
      final id = TableService.tablesFor(_live).first.id;
      await TableService.setTableTimerDuration(_live, id, 60);
      await _setClock(id,
          runningSince: DateTime.now().subtract(const Duration(minutes: 61)));

      final p1 = SessionProvider()..loadSession(_live)..consumeTableTimerNotice();
      p1.dispose();

      await Hive.box<PokerSession>(HiveService.sessionsBox).close();
      await Hive.openBox<PokerSession>(HiveService.sessionsBox);

      expect(_table(id).finishNoticeShown, isTrue);
      final provider2 = SessionProvider()..loadSession(_live);
      expect(provider2.consumeTableTimerNotice(), isNull);
      provider2.dispose();
    });

    test('re-setting the duration re-arms the alarm', () async {
      final session = await _session();
      await TableService.materialise(session);
      final id = TableService.tablesFor(_live).first.id;
      await TableService.setTableTimerDuration(_live, id, 60);
      await _setClock(id, bankedSeconds: 61 * 60, clearRunning: true);

      final provider = SessionProvider()..loadSession(_live);
      expect(provider.consumeTableTimerNotice(), isNotNull);
      expect(provider.consumeTableTimerNotice(), isNull);

      // New level, new duration: the table must be able to finish again.
      await TableService.setTableTimerDuration(_live, id, 30);
      expect(_table(id).finishNoticeShown, isFalse);
      provider.dispose();
    });
  });

  group('13-14. multiple independent tables', () {
    test('three tables hold three different durations', () async {
      final session = await _session();
      await TableService.materialise(session);
      await TableService.addTable(_live, name: 'Table 2');
      await TableService.addTable(_live, name: 'Table 3');
      final ids = TableService.tablesFor(_live).map((t) => t.id).toList();

      await TableService.setTableTimerDuration(_live, ids[0], 90);
      await TableService.setTableTimerDuration(_live, ids[1], 60);
      await TableService.setTableTimerDuration(_live, ids[2], 120);

      expect(_table(ids[0]).plannedMinutes, 90);
      expect(_table(ids[1]).plannedMinutes, 60);
      expect(_table(ids[2]).plannedMinutes, 120);
    });

    test('starting and pausing one table leaves the others alone',
        () async {
      final session = await _session();
      await TableService.materialise(session);
      await TableService.addTable(_live, name: 'Table 2');
      final ids = TableService.tablesFor(_live).map((t) => t.id).toList();

      await TableService.startTableTimer(_live, ids[0]);
      expect(_table(ids[0]).timerRunning, isTrue);
      expect(_table(ids[1]).timerRunning, isFalse);

      await TableService.startTableTimer(_live, ids[1]);
      await TableService.pauseTableTimer(_live, ids[0]);
      expect(_table(ids[0]).timerRunning, isFalse);
      expect(_table(ids[1]).timerRunning, isTrue,
          reason: 'pausing table 1 must not pause table 2');
    });

    test('finishing table 1 does not disturb tables 2 and 3', () async {
      final session = await _session();
      await TableService.materialise(session);
      await TableService.addTable(_live, name: 'Table 2');
      await TableService.addTable(_live, name: 'Table 3');
      final ids = TableService.tablesFor(_live).map((t) => t.id).toList();

      await TableService.setTableTimerDuration(_live, ids[0], 60);
      await TableService.setTableTimerDuration(_live, ids[1], 90);
      await TableService.setTableTimerDuration(_live, ids[2], 120);

      // Table 1 has run out; tables 2 and 3 are mid-countdown.
      await _setClock(ids[0],
          runningSince: DateTime.now().subtract(const Duration(minutes: 61)));
      await _setClock(ids[1],
          runningSince: DateTime.now().subtract(const Duration(minutes: 10)));
      await _setClock(ids[2],
          runningSince: DateTime.now().subtract(const Duration(minutes: 5)));

      final provider = SessionProvider()..loadSession(_live);
      final notice = provider.consumeTableTimerNotice();

      expect(notice!.tableId, ids[0]);
      expect(_table(ids[0]).isFinished, isTrue);
      expect(_table(ids[0]).timerRunning, isFalse);

      // Untouched.
      expect(_table(ids[1]).timerRunning, isTrue);
      expect(_table(ids[1]).isFinished, isFalse);
      expect(_table(ids[1]).timeRemaining!.inMinutes, closeTo(80, 1));
      expect(_table(ids[2]).timerRunning, isTrue);
      expect(_table(ids[2]).isFinished, isFalse);
      expect(_table(ids[2]).timeRemaining!.inMinutes, closeTo(115, 1));
      provider.dispose();
    });

    test('two simultaneous expiries produce two separate notices',
        () async {
      final session = await _session();
      await TableService.materialise(session);
      await TableService.addTable(_live, name: 'Table 2');
      final ids = TableService.tablesFor(_live).map((t) => t.id).toList();

      for (final id in ids) {
        await TableService.setTableTimerDuration(_live, id, 60);
        await _setClock(id, bankedSeconds: 61 * 60, clearRunning: true);
      }

      final provider = SessionProvider()..loadSession(_live);
      final a = provider.consumeTableTimerNotice();
      final b = provider.consumeTableTimerNotice();
      final c = provider.consumeTableTimerNotice();

      expect(a, isNotNull);
      expect(b, isNotNull);
      expect(a!.tableId, isNot(b!.tableId),
          reason: 'each table gets its own correctly-labelled alert');
      expect(c, isNull);
      provider.dispose();
    });
  });

  group('15. backward compatibility', () {
    test('a table map saved before durations existed still loads',
        () async {
      // Exactly the old shape: no plannedMinutes, no finishNoticeShown.
      final legacy = PokerTable.fromMap({
        'id': 'table-1',
        'name': 'Table 1',
        'seatCount': 9,
        'dealerSeat': 1,
        'status': 'active',
        'bankedSeconds': 120,
      });

      expect(legacy.plannedMinutes, isNull);
      expect(legacy.hasTimer, isFalse);
      expect(legacy.finishNoticeShown, isFalse);
      expect(legacy.isFinished, isFalse);
      expect(legacy.timeRemaining, isNull);
      // The original count-up behaviour is intact.
      expect(legacy.elapsed, const Duration(seconds: 120));
    });

    test('round-tripping a legacy table keeps the new fields absent-safe',
        () async {
      final legacy = PokerTable.fromMap({
        'id': 'table-1',
        'name': 'Table 1',
        'seatCount': 9,
        'dealerSeat': 1,
        'status': 'active',
      });
      final restored = PokerTable.fromMap(legacy.toMap());
      expect(restored.plannedMinutes, isNull);
      expect(restored.finishNoticeShown, isFalse);
    });

    test('pausing the TIMER never changes the TABLE status', () async {
      final session = await _session();
      await TableService.materialise(session);
      final id = TableService.tablesFor(_live).first.id;
      await TableService.setTableTimerDuration(_live, id, 60);

      await TableService.startTableTimer(_live, id);
      expect(_table(id).status, TableStatus.active);
      expect(_table(id).timerRunning, isTrue);

      await TableService.pauseTableTimer(_live, id);
      expect(_table(id).status, TableStatus.active,
          reason: 'a stopped clock does not pause the table');
      expect(_table(id).timerRunning, isFalse);

      // Stopping the timer likewise leaves the table active.
      await TableService.stopTableTimer(_live, id);
      expect(_table(id).status, TableStatus.active);
    });

    test('pausing the TABLE banks the clock but keeps the duration',
        () async {
      // NOTE: this direction is a PRE-EXISTING, deliberate relationship —
      // setTableStatus() stops a running clock because a table that is
      // not being dealt should not accrue play time. Issue #2 preserves
      // it rather than changing established behaviour. The duration and
      // the banked time both survive, so resuming continues correctly.
      final session = await _session();
      await TableService.materialise(session);
      final id = TableService.tablesFor(_live).first.id;
      await TableService.setTableTimerDuration(_live, id, 60);
      await _setClock(id,
          runningSince: DateTime.now().subtract(const Duration(minutes: 5)));

      await TableService.setTableStatus(_live, id, TableStatus.paused);

      final t = _table(id);
      expect(t.status, TableStatus.paused);
      expect(t.timerRunning, isFalse);
      expect(t.bankedSeconds, closeTo(300, 2), reason: 'time is banked');
      expect(t.plannedMinutes, 60, reason: 'duration is retained');
      expect(t.timeRemaining!.inMinutes, 55);
    });
  });
}
