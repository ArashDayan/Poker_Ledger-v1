import 'dart:convert';
import '../../core/localization/app_localizations.dart';
import '../../core/localization/enum_labels.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/currency_formatter.dart';
import '../../core/utils/validators.dart';
import '../../models/enums.dart';
import '../../models/player.dart';
import '../../models/transaction.dart';
import '../../providers/session_provider.dart';
import '../../services/session_service.dart';
import '../../widgets/chip_composition_editor.dart';
import '../../widgets/chip_flow.dart';
import '../../widgets/confirm_action_dialog.dart';
import '../../widgets/signature_compare_sheet.dart';
import '../../widgets/signature_pad.dart';

/// The full, searchable, filterable audit log — every buy-in, rebuy,
/// cash-out, rake collection and cash drop, voided or not. Every
/// transaction is editable, voidable, and (with confirmation) deletable
/// from here; nothing is ever silently lost.
class HistoryTab extends StatefulWidget {
  const HistoryTab({super.key});

  @override
  State<HistoryTab> createState() => _HistoryTabState();
}

class _HistoryTabState extends State<HistoryTab> {
  TransactionType? _filter;
  String _query = '';
  bool _showVoided = false;
  /// When set, the timeline shows only this player's actions.
  String? _playerFilter;

  /// When set, the timeline shows only transactions from this table.
  /// Null means "All Tables".
  String? _tableFilter;

  IconData _iconFor(TransactionType type) {
    switch (type) {
      case TransactionType.buyIn:
        return Icons.arrow_downward;
      case TransactionType.rebuy:
        return Icons.refresh;
      case TransactionType.cashOut:
        return Icons.arrow_upward;
      case TransactionType.rakeCollection:
        return Icons.percent;
      case TransactionType.cashDrop:
        return Icons.lock_outline;
      case TransactionType.transferOut:
        return Icons.logout;
      case TransactionType.transferIn:
        return Icons.login;
      case TransactionType.dealerTips:
        return Icons.volunteer_activism;
    }
  }

  Color _colorFor(TransactionType type) => type.isInflow ? AppColors.accentGreen : AppColors.danger;

  Future<void> _editTransaction(LedgerTransaction tx, CurrencyFormatter fmt) async {
    final provider = context.read<SessionProvider>();
    final amountCtrl = TextEditingController(text: tx.amount.toStringAsFixed(0));
    final noteCtrl = TextEditingController(text: tx.note ?? '');
    String signature = '';
    bool savingEdit = false;

    final confirmed = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(
          left: 16, right: 16, top: 16, bottom: MediaQuery.of(ctx).viewInsets.bottom + 16,
        ),
        child: StatefulBuilder(
          builder: (ctx, setSheetState) => SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('${tr('edit')} ${tx.type.localizedLabel}', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                const SizedBox(height: 12),
                TextField(
                  controller: amountCtrl,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  autofocus: true,
                  style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
                  decoration: InputDecoration(
                    labelText: tr('amount'),
                    prefixText: fmt.symbol == '\$' ? '\$ ' : null,
                    suffixText: fmt.symbol == '\$' ? null : fmt.symbol,
                  ),
                ),
                if (tx.type == TransactionType.cashOut)
                  Padding(
                    padding: EdgeInsets.only(top: 6),
                    child: Text(tr('zero_valid_bustout'),
                        style: TextStyle(fontSize: 11, color: AppColors.textSecondary)),
                  ),
                const SizedBox(height: 12),
                TextField(controller: noteCtrl, decoration: InputDecoration(labelText: tr('note'))),
                if (tx.requiresSignature) ...[
                  const SizedBox(height: 16),
                  Text(tr('resign_to_confirm'),
                      style: TextStyle(fontSize: 12, color: AppColors.textSecondary)),
                  const SizedBox(height: 8),
                  SignaturePad(onChanged: (sig) => signature = sig),
                ],
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: savingEdit ? null : () => Navigator.pop(ctx, false),
                        child: Text(tr('cancel')),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: ElevatedButton(
                        onPressed: savingEdit
                            ? null
                            : () async {
                          final amount = double.tryParse(amountCtrl.text.replaceAll(',', ''));
                          final err = tx.type == TransactionType.cashOut
                              ? Validators.cashOutAmount(amountCtrl.text)
                              : Validators.positiveAmount(amountCtrl.text);
                          if (err != null || amount == null) {
                            ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(content: Text(err ?? 'Invalid amount')));
                            return;
                          }
                          if (tx.requiresSignature && signature.isEmpty) {
                            ScaffoldMessenger.of(ctx)
                                .showSnackBar(SnackBar(content: Text(tr('signature_required_edit'))));
                            return;
                          }
                          setSheetState(() => savingEdit = true);
                          try {
                            await provider.updateTransaction(
                              transactionId: tx.id,
                              amount: amount,
                              note: noteCtrl.text.trim().isEmpty ? null : noteCtrl.text.trim(),
                              hostSignatureBase64: signature.isEmpty ? null : signature,
                            );
                            if (ctx.mounted) Navigator.pop(ctx, true);
                          } catch (e) {
                            ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(content: Text('$e')));
                            setSheetState(() => savingEdit = false);
                          }
                        },
                        child: savingEdit
                            ? const SizedBox(
                                height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))
                            : Text(tr('save')),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (confirmed == true && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('transaction_updated'))));
    }
  }

  /// Opens the physical chip breakdown for a money transaction.
  ///
  /// Entirely separate from [_editTransaction], which edits the MONEY.
  /// This one cannot change the amount, and the money editor cannot
  /// change the chips — keeping them apart means a banker correcting a
  /// denomination can never accidentally move the ledger.
  Future<void> _editChips(LedgerTransaction tx) async {
    final session = context.read<SessionProvider>().current;
    if (session == null) return;
    await showChipCompositionEditor(
      context,
      transaction: tx,
      currency: session.currency,
      tableId: tx.tableId,
    );
    if (mounted) setState(() {});
  }

  Future<void> _voidOrRestore(LedgerTransaction tx) async {
    final provider = context.read<SessionProvider>();
    if (tx.isVoided) {
      await provider.unvoidTransactionById(tx.id);
      return;
    }
    final confirmed = await confirmSensitiveAction(
      context,
      title: tr('void_transaction'),
      message: tr('void_tx_message'),
    );
    if (confirmed) await provider.voidTransactionById(tx.id);
  }

  Future<void> _delete(LedgerTransaction tx) async {
    final provider = context.read<SessionProvider>();
    final confirmed = await confirmSensitiveAction(
      context,
      title: tr('delete_transaction'),
      message: tr('delete_tx_message'),
      confirmLabel: tr('delete'),
      isDestructive: true,
    );
    if (confirmed) await provider.deleteTransaction(tx.id);
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<SessionProvider>();
    final session = provider.current!;
    final fmt = CurrencyFormatter(session.currency);
    final players = provider.players;
    // Resolve table names once per build rather than per row.
    final multi = provider.isMultiTable;
    final allTables = provider.tables;
    final firstTableId = allTables.isEmpty ? null : allTables.first.id;
    String? tableNameFor(LedgerTransaction t) {
      if (!multi || firstTableId == null) return null;
      final id = t.tableId ?? firstTableId;
      return allTables
          .firstWhere((x) => x.id == id, orElse: () => allTables.first)
          .name;
    }

    var txs = SessionService.transactionsFor(session.id, includeVoided: _showVoided).reversed.toList();

    if (_filter != null) {
      txs = txs.where((t) => t.type == _filter).toList();
    }
    // Player filter: table-level rows (rake, cash drop) have no playerId
    // and are correctly excluded when one player is selected.
    if (_playerFilter != null) {
      txs = txs.where((t) => t.playerId == _playerFilter).toList();
    }
    // Table filter. Transactions recorded before multi-table support
    // have a null tableId, which means "the first table" — so they are
    // included when the first table is selected rather than vanishing.
    if (_tableFilter != null) {
      final tables = provider.tables;
      final isFirst = tables.isNotEmpty && tables.first.id == _tableFilter;
      txs = txs
          .where((t) =>
              t.tableId == _tableFilter || (isFirst && t.tableId == null))
          .toList();
    }
    if (_query.isNotEmpty) {
      txs = txs.where((t) {
        final name = t.playerId == null
            ? ''
            : players.firstWhere((p) => p.id == t.playerId, orElse: () => players.first).name;
        return name.toLowerCase().contains(_query.toLowerCase()) ||
            (t.note ?? '').toLowerCase().contains(_query.toLowerCase());
      }).toList();
    }

    // ---- Per-table totals for the SELECTED transaction type ---------
    //
    // The existing rake aggregation, generalised. The calculation is
    // unchanged in every respect: it still folds the amounts of rows
    // ALREADY in `txs`, so it inherits every active filter (type,
    // player, table, search) and can never disagree with the list the
    // banker is looking at. Nothing is recalculated from rake rules,
    // and SessionService remains the single source of truth for every
    // session-level figure on the Dashboard.
    //
    // Table attribution follows the project's existing rule verbatim
    // (SessionService.transactionsForTable / the table filter above):
    // a null tableId means "the first table", which is what everything
    // recorded before multi-table support stored. No new fallback is
    // invented here.
    //
    // WHICH TYPES GET A SUMMARY, AND WHY.
    // Only types whose rows carry a table-attributable amount that the
    // existing model already defines. buyIn / rebuy / cashOut /
    // rakeCollection all do. Deliberately excluded:
    //
    //   * cashDrop    — money leaving the float for the safe. It is a
    //                   session-level movement, not a table's takings,
    //                   and the Dashboard already reports it separately.
    //   * transferOut/In — the two legs of a table-to-table move. They
    //                   net to zero across tables by construction, so a
    //                   "total" would be a meaningless zero and a
    //                   per-table figure would double-count money that
    //                   never entered or left the session.
    //
    // "Showed" is not a transaction type in this model, and "Voided" is
    // a boolean flag with its own separate chip — neither is a tab, so
    // neither is touched here.
    const summarisableTypes = {
      TransactionType.buyIn,
      TransactionType.rebuy,
      TransactionType.cashOut,
      TransactionType.rakeCollection,
      // Dealer tips are table-attributable money out, exactly like rake,
      // so they summarise the same way.
      TransactionType.dealerTips,
    };

    final summaryType =
        (_filter != null && summarisableTypes.contains(_filter))
            ? _filter
            : null;

    var summaryRows = const <LedgerTransaction>[];
    var summaryTotals = const <MapEntry<String, double>>[];
    var summaryShownTotal = 0.0;

    if (summaryType != null) {
      summaryRows = txs.where((t) => t.type == summaryType).toList();
      final byTable = <String, double>{};
      for (final t in summaryRows) {
        final id = t.tableId ?? firstTableId;
        if (id == null) continue;
        byTable[id] = (byTable[id] ?? 0) + t.amount;
      }
      // Ordered by the session's own table order so the summary reads
      // the same way as the filter chips above it. Tables with no
      // activity are omitted rather than shown as a misleading zero.
      summaryTotals = [
        for (final t in allTables)
          if ((byTable[t.id] ?? 0) != 0) MapEntry(t.name, byTable[t.id]!),
      ];
      summaryShownTotal =
          summaryRows.fold<double>(0, (sum, t) => sum + t.amount);
    }

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: TextField(
            decoration: InputDecoration(
              prefixIcon: Icon(Icons.search),
              hintText: tr('search_by_player_or_note'),
            ),
            onChanged: (v) => setState(() => _query = v),
          ),
        ),
        // Table filter — only shown once a session actually has more
        // than one table, so a normal single-table game keeps the
        // timeline it always had.
        if (provider.isMultiTable)
          SizedBox(
            height: 40,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              children: [
                Padding(
                  padding: const EdgeInsetsDirectional.only(end: 8),
                  child: ChoiceChip(
                    label: Text(tr('all_tables'),
                        style: const TextStyle(fontSize: 12)),
                    selected: _tableFilter == null,
                    onSelected: (_) => setState(() => _tableFilter = null),
                  ),
                ),
                for (final t in provider.tables)
                  Padding(
                    padding: const EdgeInsetsDirectional.only(end: 8),
                    child: ChoiceChip(
                      label:
                          Text(t.name, style: const TextStyle(fontSize: 12)),
                      selected: _tableFilter == t.id,
                      onSelected: (_) =>
                          setState(() => _tableFilter = t.id),
                    ),
                  ),
              ],
            ),
          ),
        // Player filter — the banker's most common question is "show me
        // just this player", so it gets its own row above the type chips.
        if (players.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Row(
              children: [
                Icon(Icons.person_search_outlined,
                    size: 18,
                    color: _playerFilter == null
                        ? AppColors.textSecondary
                        : AppColors.gold),
                const SizedBox(width: 10),
                Expanded(
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<String?>(
                      isExpanded: true,
                      value: _playerFilter,
                      hint: Text(tr('all_players'),
                          style: const TextStyle(fontSize: 13)),
                      items: [
                        DropdownMenuItem<String?>(
                          value: null,
                          child: Text(tr('all_players'),
                              style: const TextStyle(fontSize: 13)),
                        ),
                        ...players.map((p) => DropdownMenuItem<String?>(
                              value: p.id,
                              child: Text(
                                '${tr('seat')} ${p.seatNumber} · ${p.name}',
                                style: const TextStyle(fontSize: 13),
                                overflow: TextOverflow.ellipsis,
                              ),
                            )),
                      ],
                      onChanged: (v) => setState(() => _playerFilter = v),
                    ),
                  ),
                ),
                if (_playerFilter != null)
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.close, size: 17),
                    tooltip: tr('all_players'),
                    onPressed: () => setState(() => _playerFilter = null),
                  ),
              ],
            ),
          ),
        SizedBox(
          height: 44,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            children: [
              _filterChip(null, tr('filter_all')),
              for (final t in TransactionType.values) _filterChip(t, t.localizedLabel),
              const SizedBox(width: 8),
              FilterChip(
                label: Text(tr('show_voided')),
                selected: _showVoided,
                onSelected: (v) => setState(() => _showVoided = v),
              ),
            ],
          ),
        ),
        // Summary for the SELECTED transaction type only.
        //
        // Previously this was rendered whenever the visible rows
        // happened to contain any rake, which meant it also appeared
        // under "All" — turning the combined timeline into a
        // rake-flavoured view. It now belongs to its tab: "All" shows
        // the plain combined list, and at most one summary is ever on
        // screen.
        if (summaryType != null && summaryRows.isNotEmpty)
          _TypeSummary(
            type: summaryType,
            perTable: summaryTotals,
            shownTotal: summaryShownTotal,
            fmt: fmt,
            // With one table there is nothing to break down — a single
            // total line answers the question completely.
            showBreakdown: multi && summaryTotals.isNotEmpty,
          ),
        const SizedBox(height: 8),
        Expanded(
          child: txs.isEmpty
              ? Center(
                  child: Text(tr('no_transactions_match'), style: TextStyle(color: AppColors.textSecondary)),
                )
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  itemCount: txs.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 8),
                  itemBuilder: (ctx, i) {
                    final tx = txs[i];
                    // Null for table-level rows (rake, cash drop) — those
                    // have no player and therefore nothing to compare.
                    final matches =
                        players.where((p) => p.id == tx.playerId).toList();
                    final player = (tx.playerId == null || matches.isEmpty)
                        ? null
                        : matches.first;
                    final playerName = player?.name ?? 'Table';
                    return _TransactionTile(
                      tx: tx,
                      player: player,
                      formatter: fmt,
                      icon: _iconFor(tx.type),
                      color: _colorFor(tx.type),
                      playerName: playerName,
                      tableName: tableNameFor(tx),
                      onEdit: () => _editTransaction(tx, fmt),
                      onEditChips: () => _editChips(tx),
                      onVoidOrRestore: () => _voidOrRestore(tx),
                      onDelete: () => _delete(tx),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _filterChip(TransactionType? type, String label) {
    final selected = _filter == type;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: ChoiceChip(
        label: Text(label),
        selected: selected,
        onSelected: (_) => setState(() => _filter = type),
      ),
    );
  }
}

class _TransactionTile extends StatelessWidget {
  final LedgerTransaction tx;
  final Player? player;
  final CurrencyFormatter formatter;
  final IconData icon;
  final Color color;
  final String playerName;

  /// Table this transaction happened at, or null on a single-table
  /// session.
  final String? tableName;
  final VoidCallback onEdit;

  /// Opens the chip-composition editor. Only offered for the transaction
  /// types that physically move chips.
  final VoidCallback onEditChips;
  final VoidCallback onVoidOrRestore;
  final VoidCallback onDelete;

  const _TransactionTile({
    required this.tx,
    required this.player,
    required this.formatter,
    required this.icon,
    required this.color,
    required this.playerName,
    required this.tableName,
    required this.onEdit,
    required this.onEditChips,
    required this.onVoidOrRestore,
    required this.onDelete,
  });

  /// Whether this row can be checked against a stored specimen — i.e. it
  /// belongs to a player and actually carries a signature.
  bool get _canCompare =>
      player != null && tx.hostSignatureBase64 != null && tx.hostSignatureBase64!.isNotEmpty;

  void _showSignature(BuildContext context) {
    if (tx.hostSignatureBase64 == null || tx.hostSignatureBase64!.isEmpty) return;
    // When we know who signed, go straight to the side-by-side comparison
    // against their sample — that is what a banker actually wants when
    // they tap a signature during a dispute.
    if (player != null) {
      showSignatureComparison(
        context,
        player: player!,
        transaction: tx,
        formatter: formatter,
      );
      return;
    }
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(tr('host_signature')),
        content: Image.memory(base64Decode(tx.hostSignatureBase64!)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Opacity(
        opacity: tx.isVoided ? 0.5 : 1,
        child: ListTile(
          leading: CircleAvatar(
            backgroundColor: color.withValues(alpha: 0.15),
            child: Icon(icon, color: color, size: 20),
          ),
          title: Row(
            children: [
              Flexible(child: Text('${tx.type.localizedLabel} · $playerName', overflow: TextOverflow.ellipsis)),
              if (tx.isVoided) ...[
                const SizedBox(width: 6),
                Text(tr('voided'), style: TextStyle(fontSize: 10, color: AppColors.danger)),
              ],
              if (tx.isEdited) ...[
                const SizedBox(width: 6),
                Text(tr('edited'), style: TextStyle(fontSize: 10, color: AppColors.warning)),
              ],
            ],
          ),
          subtitle: Text(
            '${tx.timestamp.toString().substring(0, 16)}'
            // Table is shown only on a multi-table session, where it is
            // information; on one table it would just be noise.
            '${tableName != null ? " · $tableName" : ""}'
            '${tx.note != null ? "\n${tx.note}" : ""}',
          ),
          isThreeLine: tx.note != null,
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    '${tx.type.isInflow ? '+' : '-'}${formatter.format(tx.amount)}',
                    style: TextStyle(color: color, fontWeight: FontWeight.bold),
                  ),
                  if (tx.hostSignatureBase64 != null)
                    GestureDetector(
                      onTap: () => _showSignature(context),
                      child: Text(
                        _canCompare ? tr('verify_signature') : tr('view_signature'),
                        style: TextStyle(
                          fontSize: 10,
                          color: _canCompare ? AppColors.gold : AppColors.textSecondary,
                        ),
                      ),
                    ),
                ],
              ),
              PopupMenuButton<String>(
                onSelected: (v) {
                  if (v == 'verify') _showSignature(context);
                  if (v == 'edit') onEdit();
                  if (v == 'chips') onEditChips();
                  if (v == 'void') onVoidOrRestore();
                  if (v == 'delete') onDelete();
                },
                itemBuilder: (ctx) => [
                  if (_canCompare)
                    PopupMenuItem(
                        value: 'verify', child: Text(tr('verify_signature'))),
                  PopupMenuItem(value: 'edit', child: Text(tr('edit'))),
                  // Cash drop never involves chips, so offering the
                  // editor there would be a dead end.
                  //
                  // Hidden on a VOIDED row as well. A void has already
                  // reversed every chip leg, so the editor would open
                  // blank and then re-issue chips against a transaction
                  // that has no money effect — leaving a player holding
                  // chips for a buy-in that officially never happened,
                  // and silently blocking a later Restore (which skips
                  // when it finds movements already in force). Restore
                  // it first, then correct the composition.
                  if (ChipFlow.appliesTo(tx.type) && !tx.isVoided)
                    PopupMenuItem(
                        value: 'chips',
                        child: Text(tr('edit_chip_composition'))),
                  PopupMenuItem(value: 'void', child: Text(tx.isVoided ? 'Restore' : 'Void')),
                  PopupMenuItem(value: 'delete', child: Text(tr('delete_permanently'))),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Per-table totals for the transaction type currently selected in the
/// timeline.
///
/// Display only. Every figure here is a fold over transactions that are
/// ALREADY on screen — nothing is recalculated from rake rules, buy-in
/// limits or settlement, and the Dashboard's session-wide totals remain
/// authoritative.
///
/// This is the original rake summary, generalised: same container, same
/// layout, same colour treatment. Only the accent colour, icon and
/// heading vary by type, so a banker who knows the rake view already
/// knows this one.
class _TypeSummary extends StatelessWidget {
  final TransactionType type;

  /// Table name -> total, in the session's own table order.
  /// Only tables that actually produced activity appear.
  final List<MapEntry<String, double>> perTable;

  /// Total across everything currently shown. With no filters applied
  /// this equals the session figure for this type; with a filter active
  /// it is the total of what the banker can see, which is what they are
  /// asking about.
  final double shownTotal;

  final CurrencyFormatter fmt;
  final bool showBreakdown;

  const _TypeSummary({
    required this.type,
    required this.perTable,
    required this.shownTotal,
    required this.fmt,
    required this.showBreakdown,
  });

  /// Rake keeps gold — the colour it has always had, so that view is
  /// visually unchanged. The others borrow the ledger's existing
  /// money language: green for cash in, red for cash out.
  Color get _accent {
    switch (type) {
      case TransactionType.rakeCollection:
        return AppColors.gold;
      case TransactionType.cashOut:
        return AppColors.danger;
      // Amber: money that left the table but is not house income.
      case TransactionType.dealerTips:
        return AppColors.warning;
      default:
        return AppColors.accentGreen;
    }
  }

  IconData get _icon {
    switch (type) {
      case TransactionType.rakeCollection:
        return Icons.percent;
      case TransactionType.buyIn:
        return Icons.arrow_downward;
      case TransactionType.rebuy:
        return Icons.refresh;
      case TransactionType.cashOut:
        return Icons.arrow_upward;
      case TransactionType.dealerTips:
        return Icons.volunteer_activism;
      default:
        return Icons.summarize_outlined;
    }
  }

  /// Rake reuses its existing localised string so that view is
  /// byte-identical to before. The others are labelled from the type's
  /// own label, which is already localised at the enum.
  String get _totalLabel => type == TransactionType.rakeCollection
      ? tr('total_rake')
      : '${tr('total_prefix')} ${type.localizedLabel}';

  @override
  Widget build(BuildContext context) {
    final accent = _accent;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 4, 16, 0),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: accent.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (showBreakdown) ...[
            for (final entry in perTable)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(
                  children: [
                    Icon(_icon, size: 13, color: accent),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        entry.key,
                        style: const TextStyle(
                            fontSize: 12.5, color: AppColors.textPrimary),
                      ),
                    ),
                    Text(
                      fmt.format(entry.value),
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.bold,
                        color: accent,
                      ),
                    ),
                  ],
                ),
              ),
            const Divider(height: 12),
          ],
          Row(
            children: [
              if (!showBreakdown) ...[
                Icon(_icon, size: 13, color: accent),
                const SizedBox(width: 8),
              ],
              Expanded(
                child: Text(
                  _totalLabel,
                  style: const TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.bold,
                    color: AppColors.textPrimary,
                  ),
                ),
              ),
              Text(
                fmt.format(shownTotal),
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                  color: accent,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
