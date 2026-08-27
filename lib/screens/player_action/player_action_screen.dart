import 'package:flutter/material.dart';
import '../../core/localization/app_localizations.dart';
import '../../core/localization/enum_labels.dart';
import 'package:provider/provider.dart';
import '../../core/player_result_visual.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/currency_formatter.dart';
import '../../core/utils/validators.dart';
import '../../models/enums.dart';
import '../../models/player.dart';
import '../../providers/session_provider.dart';
import '../../services/financial_capture_flow.dart';
import '../../services/session_service.dart';
import '../../services/session_settlement_view.dart';
import '../../services/sound_service.dart';
import '../../models/chip_movement.dart';
import '../../providers/chip_bank_provider.dart';
import '../../services/chip_tracking_service.dart';
import '../../widgets/cashout_flow.dart';
import '../../widgets/chip_distribution_sheet.dart';
import '../../widgets/discount_review_entry.dart';
import '../../widgets/player_chip_holdings.dart';
import '../../widgets/signature_compare_sheet.dart';
import '../../widgets/signature_pad.dart';
import '../house_rules/house_rules_screen.dart';
import '../player_account/player_account_screen.dart';
import '../player_history/player_history_screen.dart';
import 'player_ledger_screen.dart';

/// The screen a host uses live at the table: pick the action, enter the
/// amount, capture a signature, confirm.
///
/// IMPORTANT: Cash-out amount is intentionally NOT capped by this
/// player's own buy-in/rebuy total. A player can buy in for 2,000, win
/// the session, and cash out for 5,000 — that is correct poker
/// accounting. Settlement is verified only at the session level (see
/// SessionService.checkBalance), never per player.
class PlayerActionScreen extends StatefulWidget {
  final Player player;
  final TransactionType initialType;

  const PlayerActionScreen({
    super.key,
    required this.player,
    this.initialType = TransactionType.buyIn,
  });

  @override
  State<PlayerActionScreen> createState() => _PlayerActionScreenState();
}

class _PlayerActionScreenState extends State<PlayerActionScreen> {
  final _formKey = GlobalKey<FormState>();
  final _amount = TextEditingController();
  final _note = TextEditingController();
  late TransactionType _type;
  String _signature = '';
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    _type = widget.initialType;
    _prefillAmount();
  }

  /// Pre-fills the amount field: last amount used for THIS player and
  /// transaction type, falling back to the session's default entry fee —
  /// the banker only has to change it when it's actually different.
  void _prefillAmount() {
    if (_amount.text.isNotEmpty) return;
    if (_type == TransactionType.cashOut) return; // never guess a payout
    final provider = context.read<SessionProvider>();
    final fee = provider.lastAmountFor(widget.player.id, _type);
    if (fee != null && fee > 0) {
      _amount.text = fee.toStringAsFixed(0);
    }
  }

  /// Buy-in/rebuy house-rule checks are advisory: they warn the host with
  /// a clear reason, a way to jump straight to the rule that triggered it,
  /// and require one extra confirmation tap to proceed — but never
  /// silently block a transaction the host insists on.
  Future<bool> _confirmHouseRuleOverride(String reason) async {
    final proceed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('house_rule_notice')),
        content: Text(reason),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(ctx, false);
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const HouseRulesScreen()),
              );
            },
            child: Text(tr('view_rule')),
          ),
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('cancel'))),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr('proceed_anyway')),
          ),
        ],
      ),
    );
    return proceed ?? false;
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    if (_signature.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr('host_signature_required_tx'))),
      );
      return;
    }

    final provider = context.read<SessionProvider>();
    final session = provider.current!;
    final amount = double.parse(_amount.text.replaceAll(',', ''));

    // Advisory house-rule checks — buy-in/rebuy only. Cash-out is never
    // gated by any player-level figure.
    if (_type == TransactionType.buyIn || _type == TransactionType.rebuy) {
      try {
        SessionService.assertWithinBuyInCap(session, widget.player.id, amount);
      } on HouseRuleViolation catch (e) {
        final proceed = await _confirmHouseRuleOverride(e.message);
        if (!proceed) return;
      }
    }
    if (_type == TransactionType.rebuy && !SessionService.canRebuy(session, widget.player.id)) {
      final proceed = await _confirmHouseRuleOverride(
        tr('rebuy_not_eligible_note'),
      );
      if (!proceed) return;
    }

    // Phase 7: a seated cash-out is the TABLE CASH-OUT — the table
    // level. The counted chips STAY the person's physical holding
    // (no cash comes back, no chip movement), so there is no funding
    // question and no chip composition step. A $0 count is a bust and
    // closes any open Discount cycle (parity). The cage redemption is
    // the separate person-level operation (player account).
    if (_type == TransactionType.cashOut) {
      setState(() => _submitting = true);
      try {
        final ok = await performTableCashOut(
          context,
          player: provider.livePlayer(widget.player),
          sessionId: session.id,
          amount: amount,
          hostSignatureBase64: _signature,
        );
        if (!ok) return;
        AppSounds.play(AppSounds.forTransaction(TransactionType.cashOut));
        if (mounted) Navigator.of(context).pop();
      } finally {
        if (mounted) setState(() => _submitting = false);
      }
      return;
    }

    final funding = await collectRequiredFunding(
      context,
      chipType: _type,
      amount: amount,
      currency: session.currency,
    );
    if (!funding.shouldCommit || !mounted) return;

    // OPTIONAL physical chip step. Skip / dismiss records no chips.
    Map<String, int>? distribution;
    if (_chipTrackingApplies && context.read<ChipBankProvider>().chips.isNotEmpty) {
      distribution = await _askChipDistribution(session.currency, amount);
      if (distribution != null && distribution.isEmpty) distribution = null;
    }
    if (!mounted) return;

    setState(() => _submitting = true);
    try {
      final tx = await provider.recordTransaction(
        playerId: widget.player.id,
        type: _type,
        amount: amount,
        hostSignatureBase64: _signature,
        note: _note.text.trim().isEmpty ? null : _note.text.trim(),
      );

      // Physical chips are recorded SEPARATELY, after the money is safely
      // stored. A failure here is logged to the banker but can never roll
      // back or corrupt the financial record.
      if (distribution != null && distribution.isNotEmpty) {
        try {
          // Phase 2a: chips belong to the PERSON (personId), or to the
          // seat row for a legacy unlinked seat — resolved once here.
          final holder = ChipTrackingService.holderRef(
              playerId: widget.player.id, personId: widget.player.personId);
          await context.read<ChipBankProvider>().recordDistribution(
                distribution: distribution,
                from: _chipsLeaveBank
                    ? ChipLocation.bank
                    : ChipLocation.player(holder),
                to: _chipsLeaveBank
                    ? ChipLocation.player(holder)
                    : ChipLocation.bank,
                reason: _chipReason,
                sessionId: session.id,
                transactionId: tx.id,
              );
        } catch (e) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('$e')),
            );
          }
        }
      }

      if (mounted) {
        await applyCollectedFunding(
          context,
          player: provider.livePlayer(widget.player),
          chipType: _type,
          amount: amount,
          currency: session.currency,
          sessionId: session.id,
          transactionId: tx.id,
          funding: funding,
        );
      }

      AppSounds.play(AppSounds.forTransaction(_type));
      if (!mounted) return;
      Navigator.of(context).pop();
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  /// Chip tracking only makes sense for movements that physically hand
  /// chips across the table. A Phase 7 table cash-out records NO chip
  /// movement — the counted chips stay the person's physical holding
  /// (the person redeems at the cage as a separate operation).
  bool get _chipTrackingApplies =>
      _type == TransactionType.buyIn ||
      _type == TransactionType.rebuy;

  /// Buy-ins and rebuys take chips OUT of the bank; a cash-out brings
  /// them back in.
  bool get _chipsLeaveBank => _type != TransactionType.cashOut;

  ChipMovementReason get _chipReason {
    switch (_type) {
      case TransactionType.rebuy:
        return ChipMovementReason.rebuy;
      case TransactionType.cashOut:
        return ChipMovementReason.cashOut;
      default:
        return ChipMovementReason.buyIn;
    }
  }

  /// Shows the distribution sheet and, on a value mismatch, asks the
  /// banker to confirm. Returns the chosen distribution, an empty map to
  /// skip, or null if dismissed.
  Future<Map<String, int>?> _askChipDistribution(
      AppCurrency currency, double amount) async {
    // Direction-correct composition (Phase 2b): a CASH-OUT takes chips
    // FROM the person's (person-scoped) holding — suggested from and
    // validated against that holding, never against bank inventory.
    // Buy-in / rebuy take chips FROM the bank (source stays null).
    final source = _type == TransactionType.cashOut
        ? ChipLocation.player(ChipTrackingService.holderRef(
            playerId: widget.player.id, personId: widget.player.personId))
        : null;
    final result = await showModalBottomSheet<Map<String, int>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => ChipDistributionSheet(
        targetAmount: amount,
        currency: currency,
        source: source,
      ),
    );
    if (result == null || result.isEmpty) return result;

    final chipValue = ChipTrackingService.valueOf(result);
    if ((chipValue - amount).abs() < 0.005) return result;

    if (!mounted) return null;
    final fmt = CurrencyFormatter(currency);
    final proceed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('chip_mismatch_title')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(tr('chip_mismatch_body')),
            const SizedBox(height: 12),
            Text('${tr('target_amount')}: ${fmt.formatRaw(amount)}'),
            Text('${tr('chip_total')}: ${fmt.formatRaw(chipValue)}'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(tr('cancel')),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr('record_anyway')),
          ),
        ],
      ),
    );
    // Declining the warning drops the chip step only — the money entry
    // continues untouched.
    return proceed == true ? result : <String, int>{};
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<SessionProvider>();
    final session = provider.current!;
    // Re-read the player every build so a rename, reseat or table move
    // made elsewhere shows here immediately, instead of this screen
    // rendering the snapshot it was pushed with.
    final player = provider.livePlayer(widget.player);
    final fmt = CurrencyFormatter(session.currency);
    final books = PlayerSettlementRow.load(session.id, session.currency, player);
    final netResult = books.chipProfitLoss;
    final cashedOut = SessionService.hasCashedOut(session.id, player.id);
    final resultVisual = PlayerResultVisuals.of(
      occupied: true,
      hasCashedOut: cashedOut,
      profitLoss: netResult,
    );
    final rebuysUsed = SessionService.rebuyCountForPlayer(session.id, player.id);

    return Scaffold(
      appBar: AppBar(
        title: Text('${tr('seat')} ${player.seatNumber} · ${player.name}'),
        actions: [
          IconButton(
            tooltip: tr('complete_ledger'),
            icon: const Icon(Icons.receipt_long_outlined),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => PlayerLedgerScreen(player: player),
              ),
            ),
          ),
          if (player.personId != null && player.personId!.isNotEmpty)
            IconButton(
              tooltip: tr('player_account'),
              icon: const Icon(Icons.account_balance_wallet_outlined),
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => PlayerAccountScreen(
                    personId: player.personId!,
                    displayName: player.name,
                    sessionCurrency: session.currency,
                    sessionId: session.id,
                  ),
                ),
              ),
            ),
          IconButton(
            tooltip: tr('player_history'),
            icon: const Icon(Icons.history),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) =>
                    PlayerHistoryScreen(
                        playerName: player.name, personId: player.personId),
              ),
            ),
          ),
        ],
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: AppColors.surfaceElevated,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _infoRow(tr('report_purchases'), fmt.format(books.buyIn + books.rebuy)),
                  if (books.reentry > 0) ...[
                    const SizedBox(height: 6),
                    _infoRow(tr('report_reentry'), fmt.format(books.reentry)),
                  ],
                  const SizedBox(height: 6),
                  _infoRow(tr('report_table_cash_outs'), fmt.format(books.tableCashOut)),
                  const SizedBox(height: 6),
                  _infoRow(tr('report_session_cash_out'), fmt.format(books.sessionCashOut)),
                  if (player.personId != null && player.personId!.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    _infoRow(tr('report_cage_cash'), fmt.format(books.cageCashOut)),
                  ],
                  const Divider(height: 20),
                  _infoRow(
                    tr('profit_loss'),
                    '${netResult >= 0 ? '+' : ''}${fmt.format(netResult)}',
                    valueColor: PlayerResultVisuals.amountColor(resultVisual),
                  ),
                  if (rebuysUsed > 0 || session.currentLevel > 1) ...[
                    const SizedBox(height: 6),
                    Text(
                      '${tr('rebuy')}: $rebuysUsed · ${tr('level_label')} ${session.currentLevel}',
                      style: const TextStyle(fontSize: 12, color: AppColors.textSecondary),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 12),

            // Physical chips in front of this player, shown next to (never
            // instead of) the money figures above. The two legitimately
            // differ once players start winning chips from each other.
            PlayerChipHoldings(
              // Phase 2a: person-scoped holding (seat ref only for a
              // legacy unlinked seat).
              playerId: ChipTrackingService.holderRef(
                  playerId: player.id, personId: player.personId),
              sessionId: session.id,
              currency: session.currency,
            ),
            const SizedBox(height: 10),
            DiscountReviewTile(
              sessionId: session.id,
              currency: session.currency,
              player: player,
            ),
            const SizedBox(height: 12),

            // The player's specimen signature, so the host can eyeball it
            // against anything they've signed for tonight without leaving
            // this screen.
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: AppColors.surfaceElevated,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: AppColors.divider),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.draw_outlined, size: 16, color: AppColors.gold),
                      const SizedBox(width: 7),
                      Expanded(
                        child: Text(tr('sample_signature_on_file'),
                            style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold)),
                      ),
                      if (player.sampleSignatureAt != null)
                        Text(
                          player.sampleSignatureAt.toString().substring(0, 10),
                          style: const TextStyle(
                              fontSize: 10.5, color: AppColors.textSecondary),
                        ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  SignatureImage(
                    base64Png: player.sampleSignatureBase64,
                    height: 88,
                    emptyLabel: tr('no_sample_signature'),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    player.hasSampleSignature
                        ? tr('comparison_note')
                        : tr('sample_signature_hint'),
                    style: const TextStyle(fontSize: 10.5, color: AppColors.textSecondary),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            SegmentedButton<TransactionType>(
              segments: [
                ButtonSegment(value: TransactionType.buyIn, label: Text(tr('buy_in'))),
                ButtonSegment(value: TransactionType.rebuy, label: Text(tr('rebuy'))),
                ButtonSegment(value: TransactionType.cashOut, label: Text(tr('table_cash_out'))),
              ],
              selected: {_type},
              onSelectionChanged: (s) => setState(() {
                _type = s.first;
                _amount.clear();
                _prefillAmount();
              }),
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _amount,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
              decoration: InputDecoration(
                labelText: tr('amount'),
                prefixText: fmt.symbol == '\$' ? '\$ ' : null,
                suffixText: fmt.symbol == '\$' ? null : fmt.symbol,
              ),
              // Cash-out allows 0 (busting out is valid poker behavior).
              // Every other type requires a positive amount.
              validator: _type == TransactionType.cashOut
                  ? Validators.cashOutAmount
                  : Validators.positiveAmount,
              autofocus: true,
            ),
            if (_type == TransactionType.cashOut)
              Padding(
                padding: EdgeInsets.only(top: 6),
                child: Text(
                  tr('actual_payout_note'),
                  style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
                ),
              ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _note,
              decoration: InputDecoration(labelText: tr('note_optional')),
            ),
            const SizedBox(height: 20),
            SignaturePad(onChanged: (sig) => setState(() => _signature = sig)),
            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: _submitting ? null : _submit,
              child: _submitting
                  ? const SizedBox(
                      height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))
                  : Text('${tr('confirm')} ${_type.localizedLabel}'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _infoRow(String label, String value, {Color? valueColor}) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: const TextStyle(color: AppColors.textSecondary)),
        Text(value,
            style: TextStyle(
                fontWeight: FontWeight.bold, fontSize: 16, color: valueColor)),
      ],
    );
  }
}
