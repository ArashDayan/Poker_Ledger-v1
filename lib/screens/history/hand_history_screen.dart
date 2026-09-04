import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/localization/app_localizations.dart';
import '../../core/localization/enum_labels.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/currency_formatter.dart';
import '../../models/enums.dart';
import '../../models/hand.dart';
import '../../providers/session_provider.dart';
import '../../services/hand_service.dart';
import '../../services/table_service.dart';
import '../../widgets/confirm_action_dialog.dart';
import '../../widgets/dual_verification_sheet.dart';

/// Per-session / per-table completed-hand list. Not a bottom tab.
class HandHistoryScreen extends StatefulWidget {
  final String sessionId;
  final String? initialTableId;
  final String? highlightHandId;

  const HandHistoryScreen({
    super.key,
    required this.sessionId,
    this.initialTableId,
    this.highlightHandId,
  });

  @override
  State<HandHistoryScreen> createState() => _HandHistoryScreenState();
}

class _HandHistoryScreenState extends State<HandHistoryScreen> {
  String? _tableFilter;
  bool _showVoided = false;

  @override
  void initState() {
    super.initState();
    _tableFilter = widget.initialTableId;
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<SessionProvider>();
    final session = provider.current;
    if (session == null) {
      return Scaffold(
        appBar: AppBar(title: Text(tr('hand_history'))),
        body: const SizedBox.shrink(),
      );
    }
    final fmt = CurrencyFormatter(session.currency);
    final tables = TableService.tablesFor(session);
    final multi = tables.length > 1;
    var hands = _tableFilter == null
        ? HandService.forSession(session.id, includeVoided: _showVoided)
        : HandService.forTable(session.id, _tableFilter!,
            includeVoided: _showVoided);
    hands = hands.reversed.toList();

    String tableName(String id) =>
        tables.firstWhere((t) => t.id == id, orElse: () => tables.first).name;

    final ended = session.status == SessionStatus.ended;

    return Scaffold(
      appBar: AppBar(title: Text(tr('hand_history'))),
      body: Column(
        children: [
          if (multi)
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
                  for (final t in tables)
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
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: FilterChip(
                label: Text(tr('show_voided')),
                selected: _showVoided,
                onSelected: (v) => setState(() => _showVoided = v),
              ),
            ),
          ),
          Expanded(
            child: hands.isEmpty
                ? Center(
                    child: Text(tr('no_hands_yet'),
                        style:
                            const TextStyle(color: AppColors.textSecondary)))
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                    itemCount: hands.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 8),
                    itemBuilder: (ctx, i) {
                      final h = hands[i];
                      final highlight = h.id == widget.highlightHandId;
                      return _HandCard(
                        hand: h,
                        formatter: fmt,
                        tableName: multi ? tableName(h.tableId) : null,
                        highlight: highlight,
                        readOnly: ended,
                        onVoid: ended
                            ? null
                            : () async {
                                final secondVerifier =
                                    await collectSecondVerifierIfRequired(
                                  context,
                                  amount: h.rakeAmount > h.houseWinAmount
                                      ? h.rakeAmount
                                      : h.houseWinAmount,
                                  currency: fmt.currency,
                                  operationLabel: tr('void_hand'),
                                );
                                if (secondVerifier == null) return;
                                final ok = await confirmSensitiveAction(
                                  context,
                                  title: tr('void_hand'),
                                  message: tr('void_hand_confirm'),
                                );
                                if (!ok || !context.mounted) return;
                                try {
                                  await provider.voidHand(
                                    h.id,
                                    secondVerifierName: secondVerifier
                                            .isRequired
                                        ? secondVerifier.name
                                        : null,
                                    secondVerifierSignature:
                                        secondVerifier.isRequired
                                            ? secondVerifier.signature
                                            : null,
                                  );
                                  if (context.mounted) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(
                                          content: Text(tr('hand_voided_snack'))),
                                    );
                                  }
                                } catch (e) {
                                  if (context.mounted) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                        SnackBar(content: Text('$e')));
                                  }
                                }
                              },
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _HandCard extends StatelessWidget {
  final Hand hand;
  final CurrencyFormatter formatter;
  final String? tableName;
  final bool highlight;
  final bool readOnly;
  final VoidCallback? onVoid;

  const _HandCard({
    required this.hand,
    required this.formatter,
    this.tableName,
    this.highlight = false,
    this.readOnly = false,
    this.onVoid,
  });

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: hand.isVoided ? 0.55 : 1,
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        decoration: BoxDecoration(
          color: AppColors.surfaceElevated,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: highlight ? AppColors.gold : AppColors.divider,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '${tr('hand_number')} #${hand.handNumber}'
                    ' · ${hand.kind.localizedLabel}'
                    '${tableName == null ? '' : ' · $tableName'}',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
                if (hand.isVoided)
                  Text(tr('hand_voided'),
                      style: const TextStyle(
                          fontSize: 10, color: AppColors.danger)),
                if (!hand.isVoided && !readOnly && onVoid != null)
                  IconButton(
                    tooltip: tr('void_hand'),
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.undo, size: 18),
                    onPressed: onVoid,
                  ),
              ],
            ),
            Text(
              hand.completedAt.toString().substring(0, 16),
              style: const TextStyle(
                  fontSize: 11, color: AppColors.textSecondary),
            ),
            const SizedBox(height: 6),
            for (final r in hand.results)
              Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${tr('seat')} ${r.seatNumber} · ${r.nameSnapshot}',
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12.5),
                      ),
                    ),
                    Text(
                      '${r.chipChange >= 0 ? '+' : ''}${formatter.format(r.chipChange)}',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: r.isWinner
                            ? AppColors.accentGreen
                            : (r.isLoser
                                ? AppColors.danger
                                : AppColors.textSecondary),
                      ),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 6),
            Text(
              '${tr('hand_pot')} ${formatter.format(hand.potAmount)}'
              '  ·  ${tr('hand_rake')} ${formatter.format(hand.rakeAmount)}'
              '  ·  ${tr('hand_house_win')} ${formatter.format(hand.houseWinAmount)}',
              style: const TextStyle(
                  fontSize: 11.5, color: AppColors.textSecondary),
            ),
            if (hand.note != null && hand.note!.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(hand.note!,
                  style: const TextStyle(
                      fontSize: 11.5, fontStyle: FontStyle.italic)),
            ],
          ],
        ),
      ),
    );
  }
}
