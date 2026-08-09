import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';

import '../core/theme/app_theme.dart';
import '../services/table_service.dart';

/// Formats a duration as HH:MM:SS.
///
/// Always includes hours so the field never changes width mid-session —
/// a clock that jumps from 59:59 to 1:00:00 shifts every control beside
/// it under the banker's thumb.
String formatTableClock(Duration d) {
  final secs = d.inSeconds < 0 ? 0 : d.inSeconds;
  final h = (secs ~/ 3600).toString().padLeft(2, '0');
  final m = ((secs % 3600) ~/ 60).toString().padLeft(2, '0');
  final s = (secs % 60).toString().padLeft(2, '0');
  return '$h:$m:$s';
}

/// A self-contained, live-refreshing clock for ONE table.
///
/// WHY THIS EXISTS
/// `PokerTable.elapsed` was always correct — it is derived from a stored
/// timestamp — but the widgets showing it are `const`/stateless inside a
/// `const TableViewTab()`, so Flutter reused the identical widget on
/// every shell rebuild and the subtree was never re-evaluated. The number
/// only moved when something *else* forced a rebuild, which is why it
/// appeared frozen and then jumped after navigating away and back.
///
/// This widget owns a one-second [Timer] and calls `setState` on itself
/// alone, so the digits advance smoothly while the rest of the table UI —
/// the felt, the seats, the player pods — is left untouched. It is the
/// display only: the source of truth remains the persisted timestamp on
/// [PokerTable], so a rebuild, a navigation, or the app being backgrounded
/// can never make the clock drift.
class TableTimerDisplay extends StatefulWidget {
  final PokerTable table;
  final double fontSize;

  /// Optional override so callers can render the same live value in a
  /// different style without duplicating the ticking logic.
  final Widget Function(BuildContext context, String text, PokerTable table)?
      builder;

  const TableTimerDisplay({
    super.key,
    required this.table,
    this.fontSize = 12,
    this.builder,
  });

  @override
  State<TableTimerDisplay> createState() => _TableTimerDisplayState();
}

class _TableTimerDisplayState extends State<TableTimerDisplay> {
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _syncTicker();
  }

  @override
  void didUpdateWidget(covariant TableTimerDisplay oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The table object is replaced on every persist, so re-evaluate
    // whether a ticker is still needed (e.g. after pause or finish).
    _syncTicker();
  }

  /// Runs the ticker only while there is something to animate. A stopped,
  /// paused or finished clock does not need a repaint every second, and
  /// leaving a timer running would burn battery for no visible change.
  void _syncTicker() {
    final shouldTick = widget.table.timerRunning && !widget.table.isFinished;
    if (shouldTick && _ticker == null) {
      _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted) return;
        setState(() {});
      });
    } else if (!shouldTick && _ticker != null) {
      _ticker!.cancel();
      _ticker = null;
    }
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final table = widget.table;

    // Countdown when a duration is set, otherwise the original count-up.
    final shown = table.hasTimer ? table.timeRemaining! : table.elapsed;
    final text = formatTableClock(shown);

    final custom = widget.builder;
    if (custom != null) return custom(context, text, table);

    final Color colour;
    if (table.isFinished) {
      colour = AppColors.danger;
    } else if (!table.timerRunning) {
      colour = AppColors.textSecondary;
    } else if (table.hasTimer &&
        table.timeRemaining! <= const Duration(minutes: 5)) {
      // Last five minutes: worth noticing without being alarming.
      colour = AppColors.warning;
    } else {
      colour = AppColors.textPrimary;
    }

    return Text(
      text,
      style: TextStyle(
        fontSize: widget.fontSize,
        fontWeight: FontWeight.bold,
        // Tabular figures stop the row shuffling as digits change width.
        fontFeatures: const [FontFeature.tabularFigures()],
        color: colour,
      ),
    );
  }
}
