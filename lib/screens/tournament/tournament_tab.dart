
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/localization/app_localizations.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/currency_formatter.dart';
import '../../models/player.dart';
import '../../providers/session_provider.dart';
import '../../services/tournament_service.dart';
import 'blind_structure_screen.dart';
import 'payout_editor_screen.dart';

/// The tournament director's console: blind clock, prize pool, entries
/// and eliminations, all on one screen.
///
/// Shown INSTEAD of the cash-game Dashboard when a session is a
/// tournament. Cash-game screens are never rendered for a tournament and
/// vice versa, so neither mode can accidentally drive the other's logic.
class TournamentTab extends StatelessWidget {
  final VoidCallback onViewPlayers;
  const TournamentTab({super.key, required this.onViewPlayers});

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<SessionProvider>();
    final session = provider.current!;
    final fmt = CurrencyFormatter(session.currency);

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
      children: [
        _BlindClock(),
        const SizedBox(height: 14),
        _prizeCard(context, provider, fmt),
        const SizedBox(height: 14),
        _structureRow(context, provider),
        const SizedBox(height: 20),
        _sectionHeader(tr('rankings'),
            '${provider.activePlayers.length} ${tr('still_in')}'),
        const SizedBox(height: 10),
        _playersCard(context, provider, fmt),
      ],
    );
  }

  Widget _sectionHeader(String title, String trailing) => Row(
        children: [
          Container(width: 3, height: 13, color: AppColors.gold),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              title.toUpperCase(),
              style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.bold,
                letterSpacing: 1.2,
                color: AppColors.textSecondary,
              ),
            ),
          ),
          Text(trailing,
              style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  color: AppColors.gold)),
        ],
      );

  Widget _prizeCard(
      BuildContext context, SessionProvider provider, CurrencyFormatter fmt) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: AppColors.heroGradient,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.gold.withValues(alpha: 0.3)),
      ),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(tr('prize_pool').toUpperCase(),
                  style: const TextStyle(
                      fontSize: 10,
                      letterSpacing: 1.1,
                      color: AppColors.textSecondary)),
              InkWell(
                onTap: () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => const PayoutEditorScreen())),
                child: Row(
                  children: [
                    Text(tr('payouts'),
                        style: const TextStyle(
                            fontSize: 11, color: AppColors.gold)),
                    const SizedBox(width: 3),
                    const Icon(Icons.chevron_right,
                        size: 15, color: AppColors.gold),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              fmt.format(provider.prizePool),
              style: const TextStyle(
                fontSize: 32,
                fontWeight: FontWeight.bold,
                color: AppColors.gold,
              ),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              _stat(tr('entries'), '${provider.entryCount}'),
              _stat(tr('house_fee'), fmt.format(provider.houseFee)),
              _stat(tr('unpaid'), fmt.format(provider.remainingPrizePool)),
            ],
          ),
          const SizedBox(height: 12),
          const Divider(height: 1),
          const SizedBox(height: 10),
          ...provider.payoutTable.map((spot) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  children: [
                    SizedBox(
                      width: 26,
                      child: Text(
                        _ordinal(spot.position),
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          color: spot.position == 1
                              ? AppColors.gold
                              : AppColors.textSecondary,
                        ),
                      ),
                    ),
                    Expanded(
                      child: Text(
                        spot.player?.name ?? '—',
                        style: TextStyle(
                          fontSize: 12.5,
                          color: spot.player == null
                              ? AppColors.textSecondary
                              : AppColors.textPrimary,
                          fontWeight: spot.player == null
                              ? FontWeight.normal
                              : FontWeight.bold,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Text('${spot.percentage.toStringAsFixed(0)}%',
                        style: const TextStyle(
                            fontSize: 11, color: AppColors.textSecondary)),
                    const SizedBox(width: 10),
                    Text(fmt.format(spot.amount),
                        style: const TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.bold,
                            color: AppColors.gold)),
                  ],
                ),
              )),
        ],
      ),
    );
  }

  Widget _stat(String label, String value) => Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label,
                style: const TextStyle(
                    fontSize: 10, color: AppColors.textSecondary)),
            const SizedBox(height: 2),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: AlignmentDirectional.centerStart,
              child: Text(value,
                  style: const TextStyle(
                      fontSize: 14, fontWeight: FontWeight.bold)),
            ),
          ],
        ),
      );

  Widget _structureRow(BuildContext context, SessionProvider provider) {
    return OutlinedButton.icon(
      onPressed: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const BlindStructureScreen()),
      ),
      icon: const Icon(Icons.list_alt_outlined, size: 18),
      label: Text(tr('blind_structure')),
    );
  }

  Widget _playersCard(
      BuildContext context, SessionProvider provider, CurrencyFormatter fmt) {
    final active = provider.activePlayers;
    final out = provider.eliminatedPlayers;

    if (active.isEmpty && out.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(22),
        decoration: BoxDecoration(
          color: AppColors.surfaceElevated,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.divider),
        ),
        child: Column(
          children: [
            Text(tr('no_players_yet'),
                style: const TextStyle(color: AppColors.textSecondary)),
            const SizedBox(height: 12),
            ElevatedButton.icon(
              onPressed: onViewPlayers,
              icon: const Icon(Icons.person_add),
              label: Text(tr('add_player')),
            ),
          ],
        ),
      );
    }

    return Column(
      children: [
        ...active.map((p) => _playerRow(context, provider, p, fmt, null)),
        if (out.isNotEmpty) ...[
          const SizedBox(height: 14),
          _sectionHeader(tr('eliminated'), '${out.length}'),
          const SizedBox(height: 8),
          ...out.map((p) =>
              _playerRow(context, provider, p, fmt, p.finishPosition)),
        ],
      ],
    );
  }

  Widget _playerRow(BuildContext context, SessionProvider provider, Player p,
      CurrencyFormatter fmt, int? position) {
    final eliminated = position != null;
    final prize = eliminated
        ? TournamentService.prizeForPosition(provider.current!, position)
        : 0.0;

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
      decoration: BoxDecoration(
        color: AppColors.surfaceElevated,
        borderRadius: BorderRadius.circular(13),
        border: Border.all(
          color: eliminated
              ? AppColors.divider
              : AppColors.accentGreen.withValues(alpha: 0.4),
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 30,
            height: 30,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: eliminated
                  ? AppColors.divider.withValues(alpha: 0.4)
                  : AppColors.accentGreen.withValues(alpha: 0.16),
              border: Border.all(
                color: position == 1
                    ? AppColors.gold
                    : (eliminated ? AppColors.divider : AppColors.accentGreen),
              ),
            ),
            child: Text(
              eliminated ? '$position' : '·',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.bold,
                color: position == 1
                    ? AppColors.gold
                    : (eliminated
                        ? AppColors.textSecondary
                        : AppColors.accentGreen),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  p.name,
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 13.5,
                    color: eliminated
                        ? AppColors.textSecondary
                        : AppColors.textPrimary,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  eliminated
                      ? '${tr('seat')} ${p.seatNumber} · ${_ordinal(position)}'
                          '${prize > 0 ? ' · ${fmt.format(prize)}' : ''}'
                      : '${tr('seat')} ${p.seatNumber} · ${tr('still_in')}',
                  style: const TextStyle(
                      fontSize: 11, color: AppColors.textSecondary),
                ),
              ],
            ),
          ),
          if (eliminated)
            TextButton(
              onPressed: () => provider.reinstatePlayer(p),
              child: Text(tr('undo'), style: const TextStyle(fontSize: 12)),
            )
          else
            OutlinedButton(
              onPressed: () => _confirmEliminate(context, provider, p),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size(0, 34),
                padding: const EdgeInsets.symmetric(horizontal: 12),
                foregroundColor: AppColors.danger,
                side: BorderSide(color: AppColors.danger.withValues(alpha: 0.6)),
              ),
              child: Text(tr('eliminate'),
                  style: const TextStyle(fontSize: 12)),
            ),
        ],
      ),
    );
  }

  Future<void> _confirmEliminate(
      BuildContext context, SessionProvider provider, Player p) async {
    final remaining = provider.activePlayers.length;
    final position = remaining < 1 ? 1 : remaining;
    final fmt = CurrencyFormatter(provider.current!.currency);
    final prize =
        TournamentService.prizeForPosition(provider.current!, position);

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('eliminate')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${p.name} — ${_ordinal(position)}'),
            const SizedBox(height: 8),
            Text(
              prize > 0
                  ? '${tr('finishes_in_the_money')} ${fmt.format(prize)}'
                  : tr('finishes_outside_money'),
              style: TextStyle(
                fontSize: 12,
                color: prize > 0 ? AppColors.gold : AppColors.textSecondary,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              tr('eliminate_hint'),
              style: const TextStyle(
                  fontSize: 11, color: AppColors.textSecondary),
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
    if (ok == true) {
      await provider.eliminatePlayer(p);
      // When only the champion is left, close the tournament out rather
      // than making the banker "eliminate" the winner.
      await provider.finaliseWinner();
    }
  }

  static String _ordinal(int n) {
    if (n >= 11 && n <= 13) return '${n}th';
    switch (n % 10) {
      case 1:
        return '${n}st';
      case 2:
        return '${n}nd';
      case 3:
        return '${n}rd';
      default:
        return '${n}th';
    }
  }
}

/// The blind clock: big countdown, current and next blinds, transport
/// controls. Deliberately the largest thing on the screen — during a
/// tournament this is what everyone at the table looks at.
class _BlindClock extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final provider = context.watch<SessionProvider>();
    final session = provider.current!;
    final level = provider.currentBlindLevel;
    final next = provider.nextBlindLevel;
    final left = provider.blindTimeRemaining;
    final running = provider.blindTimerRunning;
    final levels = provider.blindLevels;
    final index = session.currentBlindIndex;

    final urgent = left <= const Duration(minutes: 1);
    final warning = left <= const Duration(minutes: 5);
    final clockColor = urgent
        ? AppColors.danger
        : (warning ? AppColors.warning : AppColors.textPrimary);

    final total = (level?.minutes ?? 1) * 60;
    final progress =
        total <= 0 ? 0.0 : (1 - left.inSeconds / total).clamp(0.0, 1.0);

    return Container(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [AppColors.feltGreen, AppColors.surface],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppColors.gold.withValues(alpha: 0.28)),
      ),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: (level?.isBreak ?? false)
                      ? AppColors.warning.withValues(alpha: 0.16)
                      : AppColors.accentGreen.withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: (level?.isBreak ?? false)
                        ? AppColors.warning
                        : AppColors.accentGreen,
                  ),
                ),
                child: Text(
                  (level?.isBreak ?? false)
                      ? tr('break_')
                      : '${tr('level')} ${index + 1}',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    color: (level?.isBreak ?? false)
                        ? AppColors.warning
                        : AppColors.accentGreen,
                  ),
                ),
              ),
              Text('${index + 1} / ${levels.length}',
                  style: const TextStyle(
                      fontSize: 11, color: AppColors.textSecondary)),
            ],
          ),
          const SizedBox(height: 10),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              _fmtClock(left),
              style: TextStyle(
                fontSize: 58,
                fontWeight: FontWeight.bold,
                height: 1.0,
                letterSpacing: 1,
                color: clockColor,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: progress,
              minHeight: 5,
              backgroundColor: AppColors.background.withValues(alpha: 0.5),
              valueColor: AlwaysStoppedAnimation(
                urgent ? AppColors.danger : AppColors.gold,
              ),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            (level?.isBreak ?? false)
                ? tr('break_')
                : level?.blindsText ?? '—',
            style: const TextStyle(
              fontSize: 19,
              fontWeight: FontWeight.bold,
              color: AppColors.gold,
            ),
          ),
          if (next != null) ...[
            const SizedBox(height: 3),
            Text(
              '${tr('next')}: ${next.isBreak ? tr('break_') : next.blindsText}',
              style: const TextStyle(
                  fontSize: 11.5, color: AppColors.textSecondary),
            ),
          ],
          const SizedBox(height: 14),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _ctrl(Icons.skip_previous, tr('previous_level'),
                  provider.previousBlind),
              const SizedBox(width: 10),
              _ctrl(Icons.replay, tr('reset'), provider.resetBlindLevel),
              const SizedBox(width: 14),
              // Primary control, sized up: this is tapped constantly.
              SizedBox(
                width: 62,
                height: 62,
                child: ElevatedButton(
                  onPressed: running
                      ? provider.pauseBlindTimer
                      : provider.startBlindTimer,
                  style: ElevatedButton.styleFrom(
                    shape: const CircleBorder(),
                    padding: EdgeInsets.zero,
                    backgroundColor:
                        running ? AppColors.warning : AppColors.accentGreen,
                  ),
                  child: Icon(running ? Icons.pause : Icons.play_arrow,
                      size: 30, color: Colors.black),
                ),
              ),
              const SizedBox(width: 14),
              _ctrl(Icons.skip_next, tr('next_level'), provider.nextBlind),
            ],
          ),
        ],
      ),
    );
  }

  Widget _ctrl(IconData icon, String tooltip, VoidCallback onTap) =>
      IconButton.filledTonal(
        onPressed: onTap,
        icon: Icon(icon, size: 20),
        tooltip: tooltip,
        style: IconButton.styleFrom(
          backgroundColor: AppColors.surfaceElevated,
          foregroundColor: AppColors.textPrimary,
        ),
      );

  static String _fmtClock(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    final h = d.inHours;
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }
}
