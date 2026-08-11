import 'package:flutter/material.dart';
import '../core/localization/app_localizations.dart';
import 'package:provider/provider.dart';

import '../core/theme/app_theme.dart';
import '../core/utils/currency_formatter.dart';
import '../models/player.dart';
import '../models/session.dart';
import '../providers/session_provider.dart';
import '../services/table_service.dart';
import 'table_timer_display.dart';

/// Horizontal table switcher shown above the seating screens.
///
/// Hidden entirely while a session has only one table, so a normal
/// single-table home game looks and behaves exactly as it did before
/// multi-table support existed — the feature only appears once the host
/// actually opens a second table.
class TableSelectorBar extends StatelessWidget {
  const TableSelectorBar({super.key});

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<SessionProvider>();
    final session = provider.current;
    if (session == null) return const SizedBox.shrink();

    final summaries = provider.tableSummaries;
    if (summaries.length <= 1) return const SizedBox.shrink();

    final fmt = CurrencyFormatter(session.currency);
    final activeId = provider.activeTableId;

    return Container(
      height: 62,
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: AppColors.divider)),
      ),
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        itemCount: summaries.length,
        itemBuilder: (ctx, i) {
          final s = summaries[i];
          final selected = s.table.id == activeId;
          return Padding(
            padding: const EdgeInsetsDirectional.only(end: 8),
            child: Material(
              color: selected
                  ? AppColors.accentGreen.withValues(alpha: 0.16)
                  : AppColors.surface,
              borderRadius: BorderRadius.circular(12),
              child: InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: () => provider.setActiveTable(s.table.id),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: selected
                          ? AppColors.accentGreen
                          : AppColors.divider,
                    ),
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(mainAxisSize: MainAxisSize.min, children: [
                        // Status dot, so the banker can see at a glance
                        // which tables are still running.
                        Container(
                          width: 6,
                          height: 6,
                          margin: const EdgeInsetsDirectional.only(end: 5),
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: s.table.status.isClosed
                                ? AppColors.danger
                                : (s.table.status.isPaused
                                    ? AppColors.warning
                                    : AppColors.accentGreen),
                          ),
                        ),
                      Text(
                        s.table.name,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                          color: selected
                              ? AppColors.accentGreen
                              : AppColors.textPrimary,
                        ),
                      ),
                      ]),
                      const SizedBox(height: 2),
                      Text(
                        '${s.playerCount}/${s.table.seatCount} seated · '
                        '${fmt.format(s.moneyInPlay)}',
                        style: const TextStyle(
                            fontSize: 10, color: AppColors.textSecondary),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Add / rename / resize / remove tables, and see the whole floor at a
/// glance. Reached from the session AppBar's "More" menu.
Future<void> showTableManagerSheet(BuildContext context) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => _TableManagerSheet(),
  );
}

class _TableManagerSheet extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final provider = context.watch<SessionProvider>();
    final session = provider.current;
    if (session == null) return const SizedBox.shrink();

    final fmt = CurrencyFormatter(session.currency);
    final summaries = provider.tableSummaries;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 18, 18, 22),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Icon(Icons.table_bar_outlined,
                      size: 20, color: AppColors.gold),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(tr('tables'),
                        style: TextStyle(
                            fontSize: 17, fontWeight: FontWeight.bold)),
                  ),
                  Text('${summaries.length}',
                      style: const TextStyle(
                          color: AppColors.gold, fontWeight: FontWeight.bold)),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                tr('tables_seating_note'),
                style: TextStyle(fontSize: 11, color: AppColors.textSecondary),
              ),
              const SizedBox(height: 16),
              ...summaries.map((s) => _tableRow(context, provider, s, fmt)),
              const SizedBox(height: 10),
              OutlinedButton.icon(
                onPressed: () => _addTableDialog(context, provider),
                icon: const Icon(Icons.add, size: 18),
                label: Text(tr('add_table')),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _tableRow(BuildContext context, SessionProvider provider,
      TableSummary s, CurrencyFormatter fmt) {
    final blocker = provider.tableRemovalBlocker(s.table.id);
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
      decoration: BoxDecoration(
        color: AppColors.surfaceElevated,
        borderRadius: BorderRadius.circular(13),
        border: Border.all(color: AppColors.divider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(s.table.name,
                    style: const TextStyle(
                        fontWeight: FontWeight.bold, fontSize: 14)),
              ),
              IconButton(
                tooltip: tr('rename'),
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.edit_outlined,
                    size: 17, color: AppColors.textSecondary),
                onPressed: () => _renameDialog(context, provider, s),
              ),
              IconButton(
                tooltip: blocker ?? 'Remove table',
                visualDensity: VisualDensity.compact,
                icon: Icon(Icons.delete_outline,
                    size: 17,
                    color: blocker == null
                        ? AppColors.danger
                        : AppColors.divider),
                onPressed: blocker != null
                    ? () => ScaffoldMessenger.of(context)
                        .showSnackBar(SnackBar(content: Text(blocker)))
                    : () => provider.removeTable(s.table.id),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            '${s.playerCount} of ${s.table.seatCount} seats · '
            'in play ${fmt.format(s.moneyInPlay)}',
            style: const TextStyle(fontSize: 11, color: AppColors.textSecondary),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Text(tr('seats'),
                  style: TextStyle(fontSize: 11, color: AppColors.textSecondary)),
              const SizedBox(width: 8),
              ...[6, 8, 9, 10].map((n) {
                final selected = s.table.seatCount == n;
                return Padding(
                  padding: const EdgeInsetsDirectional.only(end: 6),
                  child: ChoiceChip(
                    label: Text('$n', style: const TextStyle(fontSize: 11)),
                    selected: selected,
                    visualDensity: VisualDensity.compact,
                    onSelected: (_) =>
                        provider.setTableSeatCountFor(s.table.id, n),
                  ),
                );
              }),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _addTableDialog(
      BuildContext context, SessionProvider provider) async {
    final ctrl = TextEditingController();
    var seats = 9;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: Text(tr('add_table')),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: ctrl,
                autofocus: true,
                decoration: InputDecoration(
                  labelText: tr('table_name'),
                  hintText: tr('eg_table_2'),
                ),
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  Text(tr('seats'),
                      style: TextStyle(color: AppColors.textSecondary)),
                  const SizedBox(width: 10),
                  ...[6, 8, 9, 10].map((n) => Padding(
                        padding: const EdgeInsetsDirectional.only(end: 6),
                        child: ChoiceChip(
                          label: Text('$n'),
                          selected: seats == n,
                          onSelected: (_) => setLocal(() => seats = n),
                        ),
                      )),
                ],
              ),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text(tr('cancel'))),
            ElevatedButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: Text(tr('add'))),
          ],
        ),
      ),
    );
    if (ok == true) {
      await provider.addTable(name: ctrl.text, seatCount: seats);
    }
  }

  Future<void> _renameDialog(
      BuildContext context, SessionProvider provider, TableSummary s) async {
    final ctrl = TextEditingController(text: s.table.name);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('rename_table')),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: InputDecoration(labelText: tr('table_name')),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(tr('cancel'))),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(tr('save'))),
        ],
      ),
    );
    if (ok == true && ctrl.text.trim().isNotEmpty) {
      await provider.renameTable(s.table.id, ctrl.text);
    }
  }
}

/// Asks how much money the player physically carries to the new table.
///
/// Returns the amount, or null if the banker cancelled — which aborts the
/// move entirely, so seating and accounting can never disagree.
///
/// DELIBERATELY EMPTY, WITH NO SUGGESTION AND NO LIMIT.
/// The app does not track how many chips are in front of a player, and
/// must not pretend to. Buy-ins, rebuys and the chip log all describe
/// money that passed through the house — none of them can see chips won
/// from or lost to another player. Prefilling any of those figures would
/// invite the banker to accept a number that is simply wrong.
///
/// So the field starts blank, the banker counts the stack, and whatever
/// they type is recorded verbatim.
Future<double?> _askTransferAmount(
  BuildContext context, {
  required Player player,
  required PokerTable from,
  required PokerTable to,
}) async {
  final ctrl = TextEditingController();

  return showModalBottomSheet<double>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => Padding(
      padding: EdgeInsets.only(
        left: 18,
        right: 18,
        top: 18,
        bottom: MediaQuery.of(ctx).viewInsets.bottom + 20,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('${tr('money_moving_with')} ${player.name}',
              style: const TextStyle(
                  fontSize: 16, fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          Text(
            '${from.name} → ${to.name}. ${tr('transfer_table_note')}',
            style: const TextStyle(
                fontSize: 11, color: AppColors.textSecondary),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: ctrl,
            autofocus: true,
            keyboardType:
                const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
              labelText: tr('transfer_amount_label'),
              helperText: tr('transfer_amount_helper'),
              prefixIcon: const Icon(Icons.swap_horiz),
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: Text(tr('cancel')),
                ),
              ),
              const SizedBox(width: 10),
              // A dry seat change is legitimate — a player who has
              // already cashed out, or is simply being reseated.
              Expanded(
                child: OutlinedButton(
                  onPressed: () => Navigator.pop(ctx, 0.0),
                  child: Text(tr('no_money')),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                flex: 2,
                child: ElevatedButton(
                  onPressed: () {
                    // The ONLY validation: it must be a real,
                    // non-negative number. No cap, no comparison against
                    // any derived balance — whatever the banker counted
                    // is what gets recorded.
                    final v =
                        double.tryParse(ctrl.text.trim().replaceAll(',', ''));
                    if (v == null || v < 0) {
                      ScaffoldMessenger.of(ctx).showSnackBar(
                        SnackBar(
                            content: Text(tr('enter_valid_amount'))),
                      );
                      return;
                    }
                    Navigator.pop(ctx, v);
                  },
                  child: Text(tr('confirm')),
                ),
              ),
            ],
          ),
        ],
      ),
    ),
  );
}

/// Moves one player to another table, choosing a free seat.
Future<void> showMovePlayerSheet(BuildContext context, Player player) {
  return showModalBottomSheet(
    context: context,
    builder: (ctx) {
      final provider = ctx.watch<SessionProvider>();
      final session = provider.current!;
      final tables = provider.tables;
      final currentTable = TableService.tableForPlayer(session, player);

      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 18, 18, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('${tr('move_player_title')} ${player.name}',
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              Text(
                '${currentTable.name} · ${tr('seat')} ${player.seatNumber}. ${tr('move_player_note')}',
                style: const TextStyle(
                    fontSize: 11, color: AppColors.textSecondary),
              ),
              const SizedBox(height: 14),
              ...tables.where((t) => t.id != currentTable.id).map((t) {
                final free = TableService.firstFreeSeat(session, t.id);
                final count = TableService.playerCountAt(session, t.id);
                return ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.table_bar_outlined,
                      color: AppColors.accentGreen),
                  title: Text(t.name),
                  subtitle: Text(free == null
                      ? '${tr('full')} ($count/${t.seatCount})'
                      : '${tr('seat')} $free ${tr('free')} · $count/${t.seatCount} ${tr('seated')}'),
                  enabled: free != null,
                  onTap: free == null
                      ? null
                      : () async {
                          // Ask how much money travels with the player
                          // BEFORE moving them. Cancelling here aborts
                          // the whole move, so a banker can never move a
                          // player and then abandon the accounting.
                          final amount = await _askTransferAmount(
                            ctx,
                            player: player,
                            from: currentTable,
                            to: t,
                          );
                          if (amount == null) return;
                          try {
                            await provider.movePlayerToTable(player, t.id,
                                seat: free, amount: amount);
                            if (ctx.mounted) Navigator.pop(ctx);
                          } catch (e) {
                            if (ctx.mounted) {
                              ScaffoldMessenger.of(ctx).showSnackBar(
                                  SnackBar(content: Text('$e')));
                            }
                          }
                        },
                );
              }),
              if (tables.length <= 1)
                Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: Text(
                    tr('only_one_table_note'),
                    style: TextStyle(
                        fontSize: 12, color: AppColors.textSecondary),
                  ),
                ),
            ],
          ),
        ),
      );
    },
  );
}

/// Per-table status strip: shows whether the table is active, paused or
/// closed, and gives the banker the controls to change it.
///
/// Closing a table here NEVER ends the session — that is deliberately
/// only possible from End Session on the dashboard.
class TableStatusBar extends StatelessWidget {
  final PokerTable table;
  const TableStatusBar({super.key, required this.table});

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<SessionProvider>();
    final status = table.status;

    final Color colour = status.isClosed
        ? AppColors.danger
        : (status.isPaused ? AppColors.warning : AppColors.accentGreen);
    final String label = status.isClosed
        ? tr('closed')
        : (status.isPaused ? tr('paused') : tr('active'));

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 8, 8, 8),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: AppColors.divider)),
      ),
      child: Row(
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: colour, shape: BoxShape.circle),
          ),
          const SizedBox(width: 8),
          Text(
            '${table.name} · $label',
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.bold,
              color: colour,
            ),
          ),
          const SizedBox(width: 10),
          // Independent play clock for THIS table. Tables open at
          // different times through the night, so each keeps its own
          // elapsed time rather than sharing the session clock.
          if (!status.isClosed) ...[
            Icon(
              table.timerRunning
                  ? Icons.timer_outlined
                  : Icons.timer_off_outlined,
              size: 14,
              color: table.timerRunning
                  ? AppColors.accentGreen
                  : AppColors.textSecondary,
            ),
            const SizedBox(width: 4),
            // Live-refreshing clock. Only THIS widget repaints each
            // second; the felt and seats beside it are left alone.
            TableTimerDisplay(table: table),
            // Duration picker: 60 / 90 / 120 / custom, per table.
            IconButton(
              tooltip: tr('set_duration'),
              visualDensity: VisualDensity.compact,
              icon: Icon(
                Icons.timelapse_outlined,
                size: 18,
                color: table.hasTimer
                    ? AppColors.gold
                    : AppColors.textSecondary,
              ),
              onPressed: () => showTableDurationSheet(context, table),
            ),
            IconButton(
              tooltip: table.timerRunning ? tr('pause') : tr('start_timer'),
              visualDensity: VisualDensity.compact,
              icon: Icon(
                table.timerRunning
                    ? Icons.pause_circle_outline
                    : Icons.play_circle_outline,
                size: 20,
                color: table.isFinished
                    ? AppColors.divider
                    : (table.timerRunning
                        ? AppColors.warning
                        : AppColors.accentGreen),
              ),
              // A finished countdown cannot be resumed into negative
              // time; the banker resets or re-sets the duration.
              onPressed: table.isFinished
                  ? null
                  : () => table.timerRunning
                      ? provider.pauseTableTimer(table.id)
                      : provider.startTableTimer(table.id),
            ),
            // Stop: back to zero, keeping the chosen duration.
            IconButton(
              tooltip: tr('stop_timer'),
              visualDensity: VisualDensity.compact,
              icon: Icon(
                Icons.stop_circle_outlined,
                size: 20,
                color: (table.timerRunning ||
                        table.elapsed > Duration.zero ||
                        table.isFinished)
                    ? AppColors.danger
                    : AppColors.divider,
              ),
              onPressed: (table.timerRunning ||
                      table.elapsed > Duration.zero ||
                      table.isFinished)
                  ? () => provider.stopTableTimer(table.id)
                  : null,
            ),
            if (table.isFinished)
              Container(
                margin: const EdgeInsetsDirectional.only(start: 2),
                padding:
                    const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(
                  color: AppColors.danger.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: AppColors.danger),
                ),
                child: Text(
                  tr('timer_finished'),
                  style: const TextStyle(
                    fontSize: 9.5,
                    fontWeight: FontWeight.bold,
                    color: AppColors.danger,
                  ),
                ),
              ),
          ],
          const Spacer(),
          if (status.isClosed)
            TextButton.icon(
              onPressed: () => provider.reopenTable(table.id),
              icon: const Icon(Icons.lock_open_outlined, size: 16),
              label: Text(tr('reopen'), style: const TextStyle(fontSize: 12)),
            )
          else ...[
            IconButton(
              tooltip: status.isPaused ? tr('resume') : tr('pause'),
              visualDensity: VisualDensity.compact,
              icon: Icon(
                status.isPaused
                    ? Icons.play_arrow_outlined
                    : Icons.pause_outlined,
                size: 19,
                color: AppColors.warning,
              ),
              onPressed: () => status.isPaused
                  ? provider.resumeTable(table.id)
                  : provider.pauseTable(table.id),
            ),
            IconButton(
              tooltip: tr('close_table'),
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.do_not_disturb_on_outlined,
                  size: 19, color: AppColors.danger),
              onPressed: () => _confirmClose(context, provider),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _confirmClose(
      BuildContext context, SessionProvider provider) async {
    // A table with unsettled players can't be closed — closing it would
    // strand their money. Tell the banker exactly who is blocking it.
    final blocker = provider.tableCloseBlocker(table.id);
    if (blocker != null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(blocker)));
      return;
    }

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('close_table')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${tr('close_table_confirm')} ${table.name}?'),
            const SizedBox(height: 10),
            Text(
              tr('close_table_note'),
              style: const TextStyle(
                  fontSize: 11.5, color: AppColors.textSecondary),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(tr('cancel'))),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.danger),
            child: Text(tr('close_table')),
          ),
        ],
      ),
    );
    if (ok == true) await provider.closeTable(table.id);
  }
}

/// Per-table countdown duration picker: 60 / 90 / 120 minutes, a custom
/// value, or none.
///
/// Purely a timer control — it never touches the table's Active/Paused/
/// Closed status, which stays an independent concept.
Future<void> showTableDurationSheet(
    BuildContext context, PokerTable table) async {
  final provider = context.read<SessionProvider>();
  final customCtrl = TextEditingController(
    text: (table.hasTimer && !const [60, 90, 120].contains(table.plannedMinutes))
        ? table.plannedMinutes.toString()
        : '',
  );

  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (ctx) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
      child: Container(
        padding: const EdgeInsets.fromLTRB(20, 14, 20, 24),
        decoration: const BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 38,
                height: 4,
                decoration: BoxDecoration(
                  color: AppColors.divider,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              '${table.name} · ${tr('set_duration')}',
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: AppColors.textPrimary,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              tr('table_duration_desc'),
              style: const TextStyle(
                  fontSize: 11.5, color: AppColors.textSecondary),
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final mins in const [60, 90, 120])
                  ChoiceChip(
                    label: Text('$mins ${tr('minutes')}'),
                    selected: table.plannedMinutes == mins,
                    selectedColor: AppColors.gold.withOpacity(0.25),
                    onSelected: (_) {
                      provider.setTableTimerDuration(table.id, mins);
                      Navigator.pop(ctx);
                    },
                  ),
                ChoiceChip(
                  label: Text(tr('no_timer')),
                  selected: !table.hasTimer,
                  selectedColor: AppColors.divider,
                  onSelected: (_) {
                    provider.setTableTimerDuration(table.id, null);
                    Navigator.pop(ctx);
                  },
                ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: customCtrl,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      labelText: tr('custom_minutes'),
                      isDense: true,
                      border: const OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                ElevatedButton(
                  onPressed: () {
                    final mins = int.tryParse(customCtrl.text.trim());
                    if (mins == null || mins <= 0) return;
                    provider.setTableTimerDuration(table.id, mins);
                    Navigator.pop(ctx);
                  },
                  child: Text(tr('save')),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
  customCtrl.dispose();
}
