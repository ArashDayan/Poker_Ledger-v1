import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../core/localization/app_localizations.dart';
import '../../core/localization/enum_labels.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/currency_formatter.dart';
import '../../models/enums.dart';
import '../../models/financial_event.dart';
import '../../providers/session_provider.dart';
import '../../services/chip_tracking_service.dart';
import '../../services/deposit_to_chips.dart';
import '../../services/financial_capture.dart';
import '../../services/financial_ledger_service.dart';
import '../../services/rebate_service.dart';
import '../../services/session_service.dart';
import '../../services/hive_service.dart';
import '../../services/wallet_service.dart';
import '../../services/sound_service.dart';
import '../../models/chip_movement.dart';
import '../../widgets/cashout_flow.dart';
import '../../widgets/chip_flow.dart';
import '../../widgets/financial_funding_sheet.dart';
import '../../widgets/rebate_grant_sheet.dart';
import '../../widgets/signature_pad.dart';

/// Player Account: derived Outstanding Balance plus history.
///
/// Step 4 Deposit (internal type: front money):
///   Accept Deposit, Use Deposit for Chips, Return Deposit.
/// Use Deposit for Chips is one explicit action — never inferred from
/// a Buy-in. Settlement stays Step 5. Discount/rebate stays Step 6.
///
/// Every amount goes through [CurrencyFormatter.format] so Privacy Mode
/// cannot leak a figure here.
class PlayerAccountScreen extends StatefulWidget {
  final String personId;
  final String? displayName;
  final AppCurrency? sessionCurrency;
  final String? sessionId;

  const PlayerAccountScreen({
    super.key,
    required this.personId,
    this.displayName,
    this.sessionCurrency,
    this.sessionId,
  });

  @override
  State<PlayerAccountScreen> createState() => _PlayerAccountScreenState();
}

class _PlayerAccountScreenState extends State<PlayerAccountScreen> {
  @override
  Widget build(BuildContext context) {
    // Rebuild when the session ledger or financial box notifies — do not
    // wait for a route-return setState.
    try {
      context.watch<SessionProvider>();
    } catch (_) {}
    final account = FinancialLedgerService.accountFor(widget.personId);
    // Phase 3: the wallet is the single lifetime view (E8) — deposit,
    // credit, the person-scoped chip holding and the seating reference,
    // all derived, never stored.
    final wallet = WalletService.walletFor(widget.personId);
    final name = widget.displayName ?? account.displayName;

    return Scaffold(
      appBar: AppBar(title: Text(tr('player_account'))),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: [
          Text(
            name,
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 4),
          Text(
            tr('financial_account_chip_note'),
            style: const TextStyle(
                fontSize: 12, color: AppColors.textSecondary, height: 1.35),
          ),
          const SizedBox(height: 16),
          if (!account.hasHistory)
            _notRecordedCard()
          else
            ...account.balances.map(_balanceCard),
          if (wallet.hasActivity) ...[
            const SizedBox(height: 10),
            _walletCard(wallet),
          ],
          if (_sessionChipNote != null) ...[
            const SizedBox(height: 10),
            _sessionChipNote!,
          ],
          if (_discountSnapshot != null) ...[
            const SizedBox(height: 10),
            _discountCard(_discountSnapshot!),
          ],
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _acceptDeposit,
            icon: const Icon(Icons.savings_outlined, size: 18),
            label: Text(tr('accept_deposit')),
          ),
          if (_hasDeposit) ...[
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _useDepositForChips,
              icon: const Icon(Icons.casino_outlined, size: 18),
              label: Text(tr('use_deposit_for_chips')),
            ),
            const SizedBox(height: 8),
            // Phase 5 — marker (wallet draw): funded only by the
            // available deposit, player signature required, no seat
            // or table involved.
            OutlinedButton.icon(
              onPressed: _issueMarker,
              icon: const Icon(Icons.draw_outlined, size: 18),
              label: Text(tr('issue_marker')),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _returnDeposit,
              icon: const Icon(Icons.north_east, size: 18),
              label: Text(tr('return_deposit')),
            ),
          ],
          // Phase 7 — cage redemption (person level): the person's
          // counted chips return to the Bank and their own cash
          // returns to them as cash. Available whenever the person
          // holds chips (after a table cash-out or wallet issuance).
          if (_chipsInHand > 0) ...[
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _redeemAtCage,
              icon: const Icon(Icons.account_balance_wallet_outlined, size: 18),
              label: Text(tr('redeem_at_cage')),
            ),
          ],
          if (widget.sessionId != null && widget.sessionId!.isNotEmpty) ...[
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _reviewDiscount,
              icon: const Icon(Icons.percent, size: 18),
              label: Text(tr('review_discount')),
            ),
          ],
          if (account.balances.any((b) => b.playerOwes)) ...[
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _repayCredit,
              icon: const Icon(Icons.south_west, size: 18),
              label: Text(tr('record_credit_repaid')),
            ),
          ],
          if (account.hasHistory) ...[
            const SizedBox(height: 22),
            Row(
              children: [
                Container(width: 3, height: 13, color: AppColors.gold),
                const SizedBox(width: 9),
                Text(
                  tr('financial_history'),
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.2,
                    color: AppColors.textSecondary,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            if (account.events.isEmpty)
              Text(tr('no_financial_events'),
                  style: const TextStyle(color: AppColors.textSecondary))
            else
              ...account.events.map(_eventRow),
          ],
        ],
      ),
    );
  }

  /// Chip-ledger cash-out for this session vs Financial Ledger. Never
  /// added into Outstanding Balance.
  Widget? get _sessionChipNote {
    final sessionId = widget.sessionId;
    if (sessionId == null || sessionId.isEmpty) return null;
    final seated = DepositToChips.seatedPlayer(sessionId, widget.personId);
    if (seated == null) return null;
    final chipOut =
        SessionService.playerTotalCashOut(sessionId, seated.id);
    final chipIn = SessionService.playerTotalIn(sessionId, seated.id);
    final fin = FinancialLedgerService.snapshotForSession(
      sessionId,
      currency: _actionCurrency,
      personId: widget.personId,
    );
    if (chipIn <= 0 && chipOut <= 0 && !fin.recorded) return null;
    final fmt = CurrencyFormatter(_actionCurrency);
    final unfundedChipOut = chipOut > 0 && fin.cashOutForChipsMinor == 0;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surfaceElevated,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.divider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(tr('session_chip_books'),
              style: const TextStyle(
                  fontSize: 11,
                  letterSpacing: 1.1,
                  color: AppColors.textSecondary)),
          const SizedBox(height: 6),
          Text(
            '${tr('settle_buy_in')}/${tr('settle_rebuy')}: ${fmt.format(chipIn)}'
            ' · ${tr('settle_cash_out')}: ${fmt.format(chipOut)}',
            style: const TextStyle(fontSize: 13),
          ),
          const SizedBox(height: 4),
          Text(
            '${tr('settle_cash_in_for_chips')}: ${fmt.format(fin.cashInForChips)}'
            ' · ${tr('settle_cash_out_for_chips')}: ${fmt.format(fin.cashOutForChips)}',
            style: const TextStyle(
                fontSize: 12.5, color: AppColors.textSecondary),
          ),
          if (unfundedChipOut) ...[
            const SizedBox(height: 6),
            Text(tr('chip_cashout_not_on_financial'),
                style: const TextStyle(
                    fontSize: 12, color: AppColors.warning, height: 1.35)),
          ],
        ],
      ),
    );
  }

  RebateSnapshot? get _discountSnapshot {
    final sessionId = widget.sessionId;
    if (sessionId == null || sessionId.isEmpty) return null;
    final snap = RebateService.snapshot(
      sessionId: sessionId,
      personId: widget.personId,
      currency: _actionCurrency,
    );
    return snap.hasActivity ? snap : null;
  }

  Future<void> _reviewDiscount() async {
    final sessionId = widget.sessionId;
    if (sessionId == null) return;
    String? playerId;
    try {
      playerId = DepositToChips.seatedPlayer(sessionId, widget.personId)?.id;
    } catch (_) {}
    var bustRealized = false;
    if (playerId != null) {
      bustRealized = SessionService.hasCashedOut(sessionId, playerId) &&
          SessionService.playerTotalCashOut(sessionId, playerId) == 0;
    }
    await askRebateGrant(
      context,
      sessionId: sessionId,
      personId: widget.personId,
      currency: _actionCurrency,
      playerId: playerId,
      bustRealized: bustRealized,
    );
    if (mounted) setState(() {});
  }

  Widget _discountCard(RebateSnapshot snap) {
    final fmt = CurrencyFormatter(snap.currency);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppColors.surfaceElevated,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.divider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(tr('rebate_title'),
              style: const TextStyle(
                  fontSize: 11,
                  letterSpacing: 1.1,
                  color: AppColors.textSecondary)),
          const SizedBox(height: 8),
          if (snap.cycleIndex > 0)
            _discRow(tr('rebate_cycle'), '${snap.cycleIndex}'),
          _discRow(tr('rebate_own_cash_in'), fmt.format(snap.playerCashIn)),
          _discRow(tr('rebate_original_loss'), fmt.format(snap.originalLoss)),
          _discRow(tr('rebate_granted'), fmt.format(snap.granted)),
          _discRow(tr('rebate_lost_in_play'), fmt.format(snap.lostInPlay)),
          _discRow(tr('rebate_clawback'), fmt.format(snap.clawback)),
          _discRow(tr('rebate_waived'), fmt.format(snap.waived)),
          if (snap.remainingLossMinor > 0 || snap.cycleOpen)
            _discRow(tr('rebate_remaining_loss'), fmt.format(snap.remainingLoss)),
          if (snap.exposedMinor > 0)
            _discRow(tr('rebate_exposed'), fmt.format(snap.exposed)),
          _discRow(tr('rebate_paid_out'), fmt.format(snap.paidOut)),
          _discRow(tr('rebate_actual_paid'), fmt.format(snap.actualCashPaid)),
          _discRow(tr('rebate_house_retained'), fmt.format(snap.houseRetained)),
          if (snap.closeReason != null && snap.closeReason!.isNotEmpty)
            _discRow(tr('rebate_cycle_closed'), _closeReasonLabel(snap.closeReason!)),
        ],
      ),
    );
  }

  Widget _discRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(label,
                style: const TextStyle(
                    fontSize: 12.5, color: AppColors.textSecondary)),
          ),
          Text(value, style: const TextStyle(fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }

  AppCurrency get _actionCurrency {
    if (widget.sessionCurrency != null) return widget.sessionCurrency!;
    final account = FinancialLedgerService.accountFor(widget.personId);
    if (account.balances.isNotEmpty) return account.balances.first.currency;
    return AppCurrency.usd;
  }

  /// Phase 7 — the person's physical chip holding (person-scoped,
  /// Phase 2a). Nonzero after a table cash-out or a wallet issuance.
  double get _chipsInHand =>
      WalletService.walletFor(widget.personId).chipsInHand;

  /// Phase 7 — CAGE REDEMPTION (person level): the person's counted
  /// chips return to the Bank and their own cash returns to them as
  /// cash. The count is authoritative (E9); the marker gate nets (E2);
  /// the Discount cycle closes here (existing engine, parity).
  Future<void> _redeemAtCage() async {
    final wallet = WalletService.walletFor(widget.personId);
    if (wallet.chipsInHand <= 0) return;

    String? sessionId = widget.sessionId;
    AppCurrency currency = _actionCurrency;
    try {
      final provider = context.read<SessionProvider>();
      sessionId ??= provider.current?.id;
      currency = provider.current?.currency ?? currency;
    } catch (_) {}
    final fmt = CurrencyFormatter(currency);

    // 1. The count (authoritative) + the host signature.
    final amountCtrl = TextEditingController(
        text: wallet.chipsInHand.toStringAsFixed(0));
    var signature = '';
    final confirmed = await showModalBottomSheet<bool>(
      context: context,
      isScrollable: true,
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: 16,
          bottom: MediaQuery.of(ctx).viewInsets.bottom + 16,
        ),
        child: StatefulBuilder(
          builder: (ctx, setSheet) => SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(tr('redeem_at_cage'),
                    style: const TextStyle(
                        fontSize: 18, fontWeight: FontWeight.bold)),
                const SizedBox(height: 6),
                Text(tr('redeem_hint'),
                    style: const TextStyle(
                        fontSize: 12.5,
                        color: AppColors.textSecondary,
                        height: 1.35)),
                const SizedBox(height: 8),
                TextField(
                  controller: amountCtrl,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  decoration: InputDecoration(
                    labelText: tr('amount'),
                    prefixText: fmt.symbol == r'$' ? r'$ ' : null,
                    suffixText: fmt.symbol == r'$' ? null : fmt.symbol,
                  ),
                ),
                const SizedBox(height: 14),
                Text(tr('host_signature'),
                    style: const TextStyle(
                        fontSize: 12, color: AppColors.textSecondary)),
                const SizedBox(height: 8),
                SignaturePad(
                    onChanged: (sig) => setSheet(() => signature = sig)),
                const SizedBox(height: 14),
                ElevatedButton(
                  onPressed: signature.isEmpty
                      ? null
                      : () => Navigator.pop(ctx, true),
                  child: Text(tr('confirm')),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: Text(tr('cancel')),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (confirmed != true || !mounted) return;
    final amount = double.tryParse(amountCtrl.text.replaceAll(',', ''));
    if (amount == null || amount < 0 || signature.isEmpty) return;

    // 2. How the person's cash comes back (existing funding sheet).
    final funding = await askChipCashOutFunding(
        context, formatter: fmt, amount: amount);
    if (funding == null || !mounted) return;

    // 3. The counted chips, from the person's person-scoped holding.
    // Skip / dismiss records no chip composition (money still records).
    Map<String, int>? dist;
    try {
      if (context.read<ChipBankProvider>().chips.isNotEmpty) {
        dist = await ChipFlow.ask(
          context,
          amount: amount,
          currency: currency,
          source: ChipLocation.player(widget.personId),
        );
      }
    } catch (_) {}
    if (!mounted) return;

    // 4. The redemption (marker gate, chips -> bank, cash -> person,
    //    Discount cycle close).
    final ok = await performCageRedemption(
      context,
      player: null, // person-level: no seat involved
      personId: widget.personId,
      sessionId: (sessionId != null && sessionId.isNotEmpty) ? sessionId : null,
      currency: currency,
      amount: amount,
      funding: funding,
      hostSignatureBase64: signature,
      composition: (dist == null || dist.isEmpty) ? null : dist,
    );
    if (ok && mounted) setState(() {});
  }

  double _depositMajor(AppCurrency currency) =>
      FinancialLedgerService.depositHeldMajor(widget.personId, currency);

  bool get _hasDeposit {
    final account = FinancialLedgerService.accountFor(widget.personId);
    final currencies = <AppCurrency>{_actionCurrency};
    for (final b in account.balances) {
      currencies.add(b.currency);
    }
    return currencies.any((c) => _depositMajor(c) > 0);
  }

  AppCurrency get _depositCurrency {
    final preferred = _actionCurrency;
    if (_depositMajor(preferred) > 0) return preferred;
    final account = FinancialLedgerService.accountFor(widget.personId);
    for (final b in account.balances) {
      if (_depositMajor(b.currency) > 0) return b.currency;
    }
    return preferred;
  }

  Future<void> _acceptDeposit() async {
    final currency = _actionCurrency;
    final amount = await _askAmount(
      title: tr('accept_deposit'),
      hint: tr('deposit_in_hint'),
      currency: currency,
    );
    if (amount == null) return;
    try {
      await FinancialCapture.recordFrontMoneyIn(
        personId: widget.personId,
        currency: currency,
        amount: amount,
        sessionId: widget.sessionId,
      );
      if (mounted) setState(() {});
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  Future<void> _returnDeposit() async {
    final currency = _depositCurrency;
    final held = _depositMajor(currency);
    if (held <= 0) return;
    final amount = await _askAmount(
      title: tr('return_deposit'),
      hint: tr('deposit_out_hint'),
      currency: currency,
      initial: held,
    );
    if (amount == null) return;
    try {
      await FinancialCapture.recordFrontMoneyOut(
        personId: widget.personId,
        currency: currency,
        amount: amount,
        sessionId: widget.sessionId,
      );
      if (mounted) setState(() {});
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  Future<void> _useDepositForChips() async {
    final currency = _depositCurrency;
    final held = _depositMajor(currency);
    if (held <= 0) return;

    String? sessionId = widget.sessionId;
    try {
      final provider = context.read<SessionProvider>();
      sessionId ??= provider.current?.id;
    } catch (_) {}
    final hasSession = sessionId != null && sessionId.isNotEmpty;

    final player =
        hasSession ? DepositToChips.seatedPlayer(sessionId, widget.personId) : null;
    if (player == null) {
      // Phase 4 — seat-free wallet issuance: the cage issues chips
      // from the deposit draw straight into the PERSON's holding.
      // No seat and no session required (session-optional, C-1). The
      // banker amount + signature, then the bank-anchored composition.
      final choice = await _askConvert(currency: currency, initial: held);
      if (choice == null) return;
      final dist = await ChipFlow.ask(
          context, amount: choice.amount, currency: currency);
      if (dist == null || dist.isEmpty || !mounted) return;
      try {
        await DepositToChips.issueToWallet(
          personId: widget.personId,
          currency: currency,
          amount: choice.amount,
          composition: dist,
          hostSignatureBase64: choice.signature,
          sessionId: hasSession ? sessionId : null,
        );
        AppSounds.play(AppSounds.forTransaction(TransactionType.buyIn));
        if (mounted) setState(() {});
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text('$e')));
        }
      }
      return;
    }

    // Seated: the existing path — a table buy-in funded from the
    // deposit (behavior unchanged; Phase 6 owns participation).
    final choice = await _askConvert(currency: currency, initial: held);
    if (choice == null) return;

    final dist = ChipFlow.appliesTo(TransactionType.buyIn)
        ? await ChipFlow.ask(context,
            amount: choice.amount, currency: currency)
        : null;
    if (!mounted) return;

    try {
      final result = await DepositToChips.convert(
        personId: widget.personId,
        sessionId: sessionId,
        playerId: player.id,
        currency: currency,
        amount: choice.amount,
        hostSignatureBase64: choice.signature,
      );
      if (mounted) {
        // Phase 2a: issued chips enter the person's holding.
        await ChipFlow.apply(
          context,
          distribution: dist,
          type: result.chipTransaction.type,
          sessionId: sessionId,
          transactionId: result.chipTransaction.id,
          holderRefId: ChipTrackingService.holderRef(
              playerId: player.id, personId: player.personId),
        );
      }
      AppSounds.play(AppSounds.forTransaction(result.chipTransaction.type));
      if (mounted) setState(() {});
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  /// Phase 5 — marker (wallet draw): amount + the PLAYER's signature,
  /// then the bank-anchored composition, then the seat-free draw.
  /// Funded only by the available deposit; no seat, no table, no
  /// participation.
  Future<void> _issueMarker() async {
    final currency = _depositCurrency;
    final held = _depositMajor(currency);
    if (held <= 0) return;

    String? sessionId = widget.sessionId;
    try {
      final provider = context.read<SessionProvider>();
      sessionId ??= provider.current?.id;
    } catch (_) {}
    final hasSession = sessionId != null && sessionId.isNotEmpty;

    final choice = await _askMarker(currency: currency, initial: held);
    if (choice == null) return;
    final dist = await ChipFlow.ask(
        context, amount: choice.amount, currency: currency);
    if (dist == null || dist.isEmpty || !mounted) return;
    try {
      await DepositToChips.issueMarker(
        personId: widget.personId,
        currency: currency,
        amount: choice.amount,
        composition: dist,
        playerSignatureBase64: choice.signature,
        sessionId: hasSession ? sessionId : null,
      );
      AppSounds.play(AppSounds.forTransaction(TransactionType.buyIn));
      if (mounted) setState(() {});
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  /// Marker amount + the player's signature (existing rule: a marker
  /// is credit plus a signature — this is the player's, not the
  /// banker's).
  Future<_ConvertChoice?> _askMarker({
    required AppCurrency currency,
    required double initial,
  }) async {
    final fmt = CurrencyFormatter(currency);
    final ctrl = TextEditingController(
      text: initial.toStringAsFixed(currency == AppCurrency.usd ? 2 : 0),
    );
    var signature = '';
    final confirmed = await showModalBottomSheet<bool>(
      context: context,
      isScrollable: true,
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: 16,
          bottom: MediaQuery.of(ctx).viewInsets.bottom + 16,
        ),
        child: StatefulBuilder(
          builder: (ctx, setSheet) => SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(tr('issue_marker'),
                    style: const TextStyle(
                        fontSize: 18, fontWeight: FontWeight.bold)),
                const SizedBox(height: 6),
                Text(tr('marker_draw_hint'),
                    style: const TextStyle(
                        fontSize: 12.5,
                        color: AppColors.textSecondary,
                        height: 1.35)),
                const SizedBox(height: 8),
                Text(
                  '${tr('remaining_deposit')}: ${fmt.format(initial)}',
                  style: const TextStyle(
                      fontSize: 13, color: AppColors.textSecondary),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: ctrl,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  decoration: InputDecoration(
                    labelText: tr('amount'),
                    prefixText: fmt.symbol == r'$' ? r'$ ' : null,
                    suffixText: fmt.symbol == r'$' ? null : fmt.symbol,
                  ),
                ),
                const SizedBox(height: 14),
                Text(tr('marker_player_sign_hint'),
                    style: const TextStyle(
                        fontSize: 12, color: AppColors.textSecondary)),
                const SizedBox(height: 8),
                SignaturePad(
                    onChanged: (sig) => setSheet(() => signature = sig)),
                const SizedBox(height: 14),
                ElevatedButton(
                  onPressed: signature.isEmpty
                      ? null
                      : () => Navigator.pop(ctx, true),
                  child: Text(tr('confirm')),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: Text(tr('cancel')),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (confirmed != true || !mounted) return null;
    final amount = double.tryParse(ctrl.text.replaceAll(',', ''));
    if (amount == null || amount <= 0 || signature.isEmpty) return null;
    return _ConvertChoice(amount, signature);
  }

  Future<_ConvertChoice?> _askConvert({
    required AppCurrency currency,
    required double initial,
  }) async {
    final fmt = CurrencyFormatter(currency);
    final ctrl = TextEditingController(
      text: initial.toStringAsFixed(currency == AppCurrency.usd ? 2 : 0),
    );
    var signature = '';
    final confirmed = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: 16,
          bottom: MediaQuery.of(ctx).viewInsets.bottom + 16,
        ),
        child: StatefulBuilder(
          builder: (ctx, setSheet) => SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(tr('use_deposit_for_chips'),
                    style: const TextStyle(
                        fontSize: 18, fontWeight: FontWeight.bold)),
                const SizedBox(height: 6),
                Text(tr('deposit_use_chips_hint'),
                    style: const TextStyle(
                        fontSize: 12.5,
                        color: AppColors.textSecondary,
                        height: 1.35)),
                const SizedBox(height: 8),
                Text(
                  '${tr('remaining_deposit')}: ${fmt.format(initial)}',
                  style: const TextStyle(
                      fontSize: 13, color: AppColors.textSecondary),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: ctrl,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  decoration: InputDecoration(
                    labelText: tr('amount'),
                    prefixText: fmt.symbol == r'$' ? r'$ ' : null,
                    suffixText: fmt.symbol == r'$' ? null : fmt.symbol,
                  ),
                ),
                const SizedBox(height: 14),
                Text(tr('deposit_sign_hint'),
                    style: const TextStyle(
                        fontSize: 12, color: AppColors.textSecondary)),
                const SizedBox(height: 8),
                SignaturePad(
                    onChanged: (sig) => setSheet(() => signature = sig)),
                const SizedBox(height: 14),
                ElevatedButton(
                  onPressed: signature.isEmpty
                      ? null
                      : () => Navigator.pop(ctx, true),
                  child: Text(tr('confirm')),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: Text(tr('cancel')),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (confirmed != true || !mounted) return null;
    final amount = double.tryParse(ctrl.text.replaceAll(',', ''));
    if (amount == null || amount <= 0 || signature.isEmpty) return null;
    return _ConvertChoice(amount, signature);
  }

  Future<double?> _askAmount({
    required String title,
    required String hint,
    required AppCurrency currency,
    double? initial,
  }) async {
    final fmt = CurrencyFormatter(currency);
    final ctrl = TextEditingController(
      text: initial == null
          ? ''
          : initial.toStringAsFixed(currency == AppCurrency.usd ? 2 : 0),
    );
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(hint,
                style: const TextStyle(
                    fontSize: 12.5, color: AppColors.textSecondary)),
            const SizedBox(height: 12),
            TextField(
              controller: ctrl,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(
                labelText: tr('amount'),
                prefixText: fmt.symbol == r'$' ? r'$ ' : null,
                suffixText: fmt.symbol == r'$' ? null : fmt.symbol,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(tr('cancel'))),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(tr('confirm'))),
        ],
      ),
    );
    if (confirmed != true || !mounted) return null;
    final amount = double.tryParse(ctrl.text.replaceAll(',', ''));
    if (amount == null || amount <= 0) return null;
    return amount;
  }

  Future<void> _repayCredit() async {
    final account = FinancialLedgerService.accountFor(widget.personId);
    final owing = account.balances.where((b) => b.playerOwes).toList();
    if (owing.isEmpty) return;
    final balance = owing.first;
    final currency = widget.sessionCurrency ?? balance.currency;
    final fmt = CurrencyFormatter(currency);
    final ctrl = TextEditingController(
      text: balance.amountMajor
          .toStringAsFixed(currency == AppCurrency.usd ? 2 : 0),
    );
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('record_credit_repaid')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(tr('credit_repaid_hint'),
                style: const TextStyle(
                    fontSize: 12.5, color: AppColors.textSecondary)),
            const SizedBox(height: 12),
            TextField(
              controller: ctrl,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(
                labelText: tr('amount'),
                prefixText: fmt.symbol == r'$' ? r'$ ' : null,
                suffixText: fmt.symbol == r'$' ? null : fmt.symbol,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(tr('cancel'))),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(tr('confirm'))),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final amount = double.tryParse(ctrl.text.replaceAll(',', ''));
    if (amount == null || amount <= 0) return;
    try {
      await FinancialLedgerService.record(
        personId: widget.personId,
        currency: currency,
        type: FinancialEventType.creditRepaid,
        amount: amount,
        sessionId: widget.sessionId,
      );
      if (mounted) setState(() {});
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  Widget _notRecordedCard() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppColors.surfaceElevated,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.divider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(tr('outstanding_balance'),
              style: const TextStyle(
                  fontSize: 11,
                  letterSpacing: 1.1,
                  color: AppColors.textSecondary)),
          const SizedBox(height: 8),
          Text(tr('not_recorded'),
              style: const TextStyle(
                  fontSize: 26, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Text(tr('not_recorded_hint'),
              style: const TextStyle(
                  fontSize: 12.5, color: AppColors.textSecondary, height: 1.35)),
        ],
      ),
    );
  }

  /// Phase 3 — the wallet strip: the person's physical chip holding
  /// (person-scoped, Phase 2a) plus the per-currency figures the
  /// wallet derives for the marker rule (W-2) and open credit.
  /// Informational only — no action is taken from this card.
  /// The table name for a commitment (session tables live in the
  /// session record; degrades to the id).
  String _tableName(String sessionId, String tableId) {
    try {
      final s = HiveService.sessions.get(sessionId);
      for (final t in s?.tables ?? const <Map>[]) {
        if (t['id'] == tableId) return (t['name'] as String? ?? tableId);
      }
    } catch (_) {}
    return tableId;
  }

  Widget _walletCard(WalletPosition wallet) {
    final chipsFmt = CurrencyFormatter(
        wallet.currencies.isNotEmpty
            ? wallet.currencies.first.currency
            : AppCurrency.usd);
    final rows = <Widget>[
      Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(tr('wallet_chips_in_hand'),
              style: const TextStyle(
                  fontSize: 12.5, color: AppColors.textSecondary)),
          Text(chipsFmt.format(wallet.chipsInHand),
              style: const TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.bold,
                  color: AppColors.gold)),
        ],
      ),
      // Phase 6: open table commitments (derived from participations —
      // lifecycle reference only, no money on the card).
      if (wallet.openParticipationCount > 0)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(tr('wallet_open_commitments'),
                  style: const TextStyle(
                      fontSize: 12.5, color: AppColors.textSecondary)),
              Text(
                wallet.openParticipations
                    .map((p) => _tableName(p.sessionId, p.tableId))
                    .join(' · '),
                style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                    color: AppColors.accentGreen),
              ),
            ],
          ),
        ),
    ];
    for (final p in wallet.currencies) {
      final fmt = CurrencyFormatter(p.currency);
      if (p.depositHeld > 0) {
        rows.add(
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(tr('wallet_available_marker'),
                    style: const TextStyle(
                        fontSize: 12.5,
                        color: AppColors.textSecondary)),
                Text(fmt.format(p.availableMarkerBalance),
                    style: const TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.bold,
                        color: AppColors.gold)),
              ],
            ),
          ),
        );
      }
      if (p.creditOutstanding > 0) {
        rows.add(
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(tr('wallet_credit_outstanding'),
                    style: const TextStyle(
                        fontSize: 12.5,
                        color: AppColors.textSecondary)),
                Text(fmt.format(p.creditOutstanding),
                    style: const TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.bold,
                        color: AppColors.danger)),
              ],
            ),
          ),
        );
      }
    }
    if (rows.length == 1 && wallet.chipsInHand <= 0) {
      // No wallet figure worth showing.
      return const SizedBox.shrink();
    }
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surfaceElevated,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.divider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: rows,
      ),
    );
  }

  Widget _balanceCard(OutstandingBalance b) {
    final fmt = CurrencyFormatter(b.currency);
    final deposit = _depositMajor(b.currency);
    final Color color;
    final String caption;
    final String figure;
    if (b.isNotRecorded) {
      color = AppColors.textSecondary;
      caption = tr('not_recorded');
      figure = tr('not_recorded');
    } else if (b.isSettled) {
      color = AppColors.accentGreen;
      caption = tr('financial_settled');
      figure = fmt.format(0);
    } else if (b.playerOwes) {
      color = AppColors.danger;
      caption = tr('player_owes_banker');
      figure = fmt.format(b.amountMajor);
    } else {
      color = AppColors.gold;
      caption = tr('banker_holds_money');
      figure = fmt.format(b.amountMajor.abs());
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          gradient: AppColors.heroGradient,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.divider),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${tr('outstanding_balance')} · ${_currencyLabel(b.currency)}',
              style: const TextStyle(
                  fontSize: 11,
                  letterSpacing: 1.1,
                  color: AppColors.textSecondary),
            ),
            const SizedBox(height: 8),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: AlignmentDirectional.centerStart,
              child: Text(figure,
                  style: TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.bold,
                      color: color)),
            ),
            const SizedBox(height: 4),
            Text(caption,
                style: TextStyle(fontSize: 12.5, color: color)),
            if (deposit > 0) ...[
              const SizedBox(height: 8),
              Text(
                '${tr('remaining_deposit')}: ${fmt.format(deposit)}',
                style: const TextStyle(
                    fontSize: 12.5, color: AppColors.gold),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _eventRow(FinancialEvent e) {
    final fmt = CurrencyFormatter(e.currency);
    final contribution = FinancialLedgerService.contributionOf(e);
    final isReversal = e.isReversal;
    final muted = isReversal || contribution == 0 && !e.isReversal &&
        (e.type == FinancialEventType.cashInForChips ||
            e.type == FinancialEventType.cashOutForChips);
    final amountText = contribution == 0
        ? fmt.format(e.amountMajor)
        : '${contribution > 0 ? '+' : '−'}${fmt.format(e.amountMajor)}';
    final amountColor = contribution > 0
        ? AppColors.danger
        : contribution < 0
            ? AppColors.gold
            : AppColors.textSecondary;

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 12),
        decoration: BoxDecoration(
          color: AppColors.surfaceElevated,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.divider),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    isReversal
                        ? '${tr('fin_reversal_of')} ${e.localizedTypeLabel}'
                        : e.localizedTypeLabel,
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 13.5,
                      decoration:
                          isReversal ? TextDecoration.lineThrough : null,
                      color: muted
                          ? AppColors.textSecondary
                          : AppColors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    DateFormat.yMMMd().add_jm().format(e.occurredAt),
                    style: const TextStyle(
                        fontSize: 11, color: AppColors.textSecondary),
                  ),
                  if (e.paymentMethod != null) ...[
                    const SizedBox(height: 2),
                    Text(e.paymentMethod!.localizedLabel,
                        style: const TextStyle(
                            fontSize: 11, color: AppColors.textSecondary)),
                  ],
                  if (e.reason != null && e.reason!.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(e.reason!,
                        style: const TextStyle(
                            fontSize: 11, color: AppColors.textSecondary)),
                  ],
                  if (e.note != null && e.note!.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(e.note!,
                        style: const TextStyle(
                            fontSize: 11, color: AppColors.textSecondary)),
                  ],
                  if (e.linkedTransactionId != null) ...[
                    const SizedBox(height: 2),
                    Text(tr('audit_linked_tx'),
                        style: const TextStyle(
                            fontSize: 10.5, color: AppColors.textSecondary)),
                  ],
                  if (e.isBackdated || isReversal)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Wrap(
                        spacing: 6,
                        children: [
                          if (e.isBackdated) _badge(tr('backdated')),
                          if (isReversal) _badge(tr('reversed_event')),
                        ],
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(amountText,
                    style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 13.5,
                        color: amountColor)),
                const SizedBox(height: 2),
                Text(_currencyLabel(e.currency),
                    style: const TextStyle(
                        fontSize: 9.5, color: AppColors.textSecondary)),
                if (e.type == FinancialEventType.rebateGranted &&
                    !e.isReversal)
                  TextButton(
                    onPressed: () async {
                      await RebateService.reverseGrant(e.id);
                      if (mounted) setState(() {});
                    },
                    child: Text(tr('reverse_rebate_grant'),
                        style: const TextStyle(fontSize: 11)),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _badge(String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: AppColors.warning.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: AppColors.warning.withValues(alpha: 0.5)),
      ),
      child: Text(label,
          style: const TextStyle(
              fontSize: 9.5,
              fontWeight: FontWeight.bold,
              letterSpacing: 0.4,
              color: AppColors.warning)),
    );
  }

  String _currencyLabel(AppCurrency currency) =>
      currency == AppCurrency.usd ? 'USD' : tr('toman');

  String _closeReasonLabel(String reason) {
    switch (reason) {
      case RebateRecoveryKind.lostInPlay:
        return tr('rebate_close_lost_in_play');
      case RebateRecoveryKind.override:
        return tr('rebate_close_override');
      case RebateRecoveryKind.clawback:
        return tr('rebate_close_reconciled');
      default:
        return reason;
    }
  }
}

class _ConvertChoice {
  final double amount;
  final String signature;
  const _ConvertChoice(this.amount, this.signature);
}
