import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/localization/app_localizations.dart';
import '../core/theme/app_theme.dart';
import '../core/utils/currency_formatter.dart';
import '../models/chip_movement.dart';
import '../models/enums.dart';
import '../models/player.dart';
import '../providers/chip_bank_provider.dart';
import '../services/chip_tracking_service.dart';
import 'chip_picker_list.dart';

/// Colouring up / breaking down: a player swaps denominations with the
/// Bank at exactly equal value.
///
/// NO MONEY LEG, BY DESIGN
/// Nothing about the player's financial position changes — they hold the
/// same value before and after, just in different physical chips. So this
/// creates no [LedgerTransaction], touches no player balance, and cannot
/// reach the settlement engine. It writes two chip movements and nothing
/// else.
///
/// WHY EXACT EQUALITY IS ENFORCED HERE AND NOT MERELY WARNED ABOUT
/// A buy-in whose chip breakdown is slightly off is still anchored by its
/// money amount — the ledger remains correct and the chip count can be
/// corrected later. An exchange has no such anchor. If the two sides do
/// not match, the difference is chips created or destroyed out of thin
/// air, and there is no record anywhere that would reveal it. So the
/// confirm button stays disabled until the totals agree, and the service
/// throws as a second line of defence.
Future<bool> showChipExchangeSheet(
  BuildContext context, {
  required List<Player> players,
  required AppCurrency currency,
  required String sessionId,
  Player? initialPlayer,
}) async {
  final result = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _ChipExchangeSheet(
      players: players,
      currency: currency,
      sessionId: sessionId,
      initialPlayer: initialPlayer,
    ),
  );
  return result ?? false;
}

class _ChipExchangeSheet extends StatefulWidget {
  final List<Player> players;
  final AppCurrency currency;
  final String sessionId;
  final Player? initialPlayer;

  const _ChipExchangeSheet({
    required this.players,
    required this.currency,
    required this.sessionId,
    this.initialPlayer,
  });

  @override
  State<_ChipExchangeSheet> createState() => _ChipExchangeSheetState();
}

class _ChipExchangeSheetState extends State<_ChipExchangeSheet> {
  Player? _player;

  /// Chips the player hands TO the bank.
  final Map<String, int> _given = {};

  /// Chips the player receives FROM the bank.
  final Map<String, int> _received = {};

  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _player = widget.initialPlayer ??
        (widget.players.length == 1 ? widget.players.first : null);
  }

  /// Plain lookup rather than `firstOrNull`, which lives in
  /// package:collection and is not a dependency of this project.
  Player? _byId(String? id) {
    if (id == null) return null;
    for (final p in widget.players) {
      if (p.id == id) return p;
    }
    return null;
  }

  double get _givenValue => ChipTrackingService.valueOf(_given);
  double get _receivedValue => ChipTrackingService.valueOf(_received);

  bool get _balanced =>
      _givenValue > 0 && (_givenValue - _receivedValue).abs() < 0.005;

  /// The bank must actually hold what it is being asked to hand back.
  /// Unlike a buy-in this is a hard gate: an exchange the bank cannot
  /// physically perform is not a warning, it simply did not happen.
  bool get _bankCanCover {
    for (final e in _received.entries) {
      if (e.value > ChipTrackingService.quantityAt(ChipLocation.bank, e.key)) {
        return false;
      }
    }
    return true;
  }

  /// Likewise the player must hold the chips they are handing over.
  bool get _playerCanCover {
    final p = _player;
    if (p == null) return false;
    for (final e in _given.entries) {
      final held = ChipTrackingService.quantityAt(
          ChipLocation.player(p.id), e.key);
      if (e.value > held) return false;
    }
    return true;
  }

  bool get _canConfirm =>
      _player != null &&
      _balanced &&
      _bankCanCover &&
      _playerCanCover &&
      !_saving;

  Future<void> _confirm() async {
    final p = _player;
    if (p == null) return;
    setState(() => _saving = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ChipTrackingService.recordExchange(
        counterparty: ChipLocation.player(p.id),
        chipsIn: _given,
        chipsOut: _received,
        sessionId: widget.sessionId,
      );
      if (!mounted) return;
      context.read<ChipBankProvider>().refresh();
      messenger.showSnackBar(
        SnackBar(content: Text(tr('exchange_recorded'))),
      );
      Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      messenger.showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<ChipBankProvider>();
    final chips = provider.chips;
    final fmt = CurrencyFormatter(widget.currency);
    final p = _player;

    // Live availability on each side, recomputed every build so the
    // numbers track any movement recorded while this sheet is open.
    final playerAvailable = <String, int>{};
    final bankAvailable = <String, int>{};
    for (final c in chips) {
      bankAvailable[c.id] =
          ChipTrackingService.quantityAt(ChipLocation.bank, c.id);
      playerAvailable[c.id] = p == null
          ? 0
          : ChipTrackingService.quantityAt(ChipLocation.player(p.id), c.id);
    }

    return DraggableScrollableSheet(
      initialChildSize: 0.9,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      expand: false,
      builder: (context, scrollController) => Container(
        decoration: const BoxDecoration(
          color: AppColors.background,
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 12, 4),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          tr('chip_exchange'),
                          style: const TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.bold,
                            color: AppColors.textPrimary,
                          ),
                        ),
                        Text(
                          tr('chip_exchange_desc'),
                          style: const TextStyle(
                              fontSize: 11, color: AppColors.textSecondary),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, size: 20),
                    onPressed: () => Navigator.pop(context, false),
                  ),
                ],
              ),
            ),

            Expanded(
              child: ListView(
                controller: scrollController,
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
                children: [
                  // --- Player ------------------------------------
                  Text(tr('select_player'),
                      style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          color: AppColors.textSecondary)),
                  const SizedBox(height: 6),
                  DropdownButtonFormField<String>(
                    value: p?.id,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      isDense: true,
                      contentPadding:
                          EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                    ),
                    hint: Text(tr('choose_player')),
                    items: [
                      for (final pl in widget.players)
                        DropdownMenuItem(
                          value: pl.id,
                          child: Text('${tr('seat')} ${pl.seatNumber} · ${pl.name}',
                              overflow: TextOverflow.ellipsis),
                        ),
                    ],
                    onChanged: _saving
                        ? null
                        : (id) => setState(() {
                              _player = _byId(id);
                              // Selections belong to the previous player;
                              // carrying them over would let a banker
                              // hand over chips someone else holds.
                              _given.clear();
                              _received.clear();
                            }),
                  ),

                  const SizedBox(height: 18),

                  // --- Given to bank -----------------------------
                  _SideHeader(
                    icon: Icons.arrow_upward,
                    colour: AppColors.danger,
                    title: tr('chips_given_to_bank'),
                    subtitle: p == null
                        ? tr('choose_player_first')
                        : '${p.name} → ${tr('bank')}',
                    total: fmt.formatRaw(_givenValue),
                  ),
                  const SizedBox(height: 8),
                  if (p != null)
                    ChipPickerList(
                      chips: chips,
                      fmt: fmt,
                      selection: _given,
                      available: playerAvailable,
                      availableLabel: tr('player_holds'),
                      hideUnavailable: true,
                      onChanged: (id, q) => setState(() {
                        if (q <= 0) {
                          _given.remove(id);
                        } else {
                          _given[id] = q;
                        }
                      }),
                    ),

                  const SizedBox(height: 18),

                  // --- Received from bank ------------------------
                  _SideHeader(
                    icon: Icons.arrow_downward,
                    colour: AppColors.accentGreen,
                    title: tr('chips_received_from_bank'),
                    subtitle: p == null
                        ? tr('choose_player_first')
                        : '${tr('bank')} → ${p.name}',
                    total: fmt.formatRaw(_receivedValue),
                  ),
                  const SizedBox(height: 8),
                  if (p != null)
                    ChipPickerList(
                      chips: chips,
                      fmt: fmt,
                      selection: _received,
                      available: bankAvailable,
                      availableLabel: tr('in_bank'),
                      onChanged: (id, q) => setState(() {
                        if (q <= 0) {
                          _received.remove(id);
                        } else {
                          _received[id] = q;
                        }
                      }),
                    ),
                ],
              ),
            ),

            _ExchangeFooter(
              fmt: fmt,
              given: _givenValue,
              received: _receivedValue,
              balanced: _balanced,
              bankCanCover: _bankCanCover,
              playerCanCover: _playerCanCover,
              hasPlayer: p != null,
              saving: _saving,
              canConfirm: _canConfirm,
              onCancel: () => Navigator.pop(context, false),
              onConfirm: _confirm,
            ),
          ],
        ),
      ),
    );
  }
}

class _SideHeader extends StatelessWidget {
  final IconData icon;
  final Color colour;
  final String title;
  final String subtitle;
  final String total;

  const _SideHeader({
    required this.icon,
    required this.colour,
    required this.title,
    required this.subtitle,
    required this.total,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 17, color: colour),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title,
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                      color: colour)),
              Text(subtitle,
                  style: const TextStyle(
                      fontSize: 10.5, color: AppColors.textSecondary)),
            ],
          ),
        ),
        Text(total,
            style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.bold,
                color: AppColors.textPrimary)),
      ],
    );
  }
}

class _ExchangeFooter extends StatelessWidget {
  final CurrencyFormatter fmt;
  final double given;
  final double received;
  final bool balanced;
  final bool bankCanCover;
  final bool playerCanCover;
  final bool hasPlayer;
  final bool saving;
  final bool canConfirm;
  final VoidCallback onCancel;
  final VoidCallback onConfirm;

  const _ExchangeFooter({
    required this.fmt,
    required this.given,
    required this.received,
    required this.balanced,
    required this.bankCanCover,
    required this.playerCanCover,
    required this.hasPlayer,
    required this.saving,
    required this.canConfirm,
    required this.onCancel,
    required this.onConfirm,
  });

  /// The single most important number on this sheet: anything other than
  /// zero means chips would be invented or destroyed.
  double get _difference => received - given;

  String? get _blocker {
    if (!hasPlayer) return tr('choose_player_first');
    if (given <= 0 && received <= 0) return tr('exchange_empty');
    if (!balanced) return tr('exchange_must_balance');
    if (!playerCanCover) return tr('player_lacks_chips');
    if (!bankCanCover) return tr('bank_cannot_cover');
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final blocker = _blocker;

    return Container(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
      decoration: const BoxDecoration(
        color: AppColors.background,
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(tr('given'),
                        style: const TextStyle(
                            fontSize: 10.5,
                            color: AppColors.textSecondary)),
                    Text(fmt.formatRaw(given),
                        style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.bold,
                            color: AppColors.textPrimary)),
                  ],
                ),
              ),
              Icon(
                balanced ? Icons.check_circle_outline : Icons.sync_problem,
                size: 22,
                color: balanced ? AppColors.accentGreen : AppColors.danger,
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(tr('received'),
                        style: const TextStyle(
                            fontSize: 10.5,
                            color: AppColors.textSecondary)),
                    Text(fmt.formatRaw(received),
                        style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.bold,
                            color: AppColors.textPrimary)),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 7),
            decoration: BoxDecoration(
              color: (balanced ? AppColors.accentGreen : AppColors.danger)
                  .withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              balanced
                  ? tr('exchange_balanced')
                  : '${tr('difference')}: ${fmt.formatRaw(_difference)}',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.bold,
                color:
                    balanced ? AppColors.accentGreen : AppColors.danger,
              ),
            ),
          ),
          if (blocker != null) ...[
            const SizedBox(height: 6),
            Text(
              blocker,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 11, color: AppColors.warning),
            ),
          ],
          const SizedBox(height: 6),
          Text(
            tr('exchange_no_money_note'),
            textAlign: TextAlign.center,
            style: const TextStyle(
                fontSize: 10.5, color: AppColors.textSecondary),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: saving ? null : onCancel,
                  child: Text(tr('cancel')),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                flex: 2,
                child: SizedBox(
                  height: 46,
                  child: ElevatedButton.icon(
                    onPressed: canConfirm ? onConfirm : null,
                    icon: saving
                        ? const SizedBox(
                            height: 16,
                            width: 16,
                            child:
                                CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.swap_horiz),
                    label: Text(tr('confirm_exchange')),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
