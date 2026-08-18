import 'package:flutter/material.dart';
import '../../core/localization/app_localizations.dart';
import 'package:provider/provider.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/currency_formatter.dart';
import '../../models/enums.dart';
import '../../models/session.dart';
import '../../services/hive_service.dart';
import '../../providers/settings_provider.dart';
import '../../services/session_service.dart';
import '../../widgets/poker_chip_logo.dart';
import '../../widgets/polish.dart';
import '../new_session/new_session_screen.dart';
import '../player_history/players_directory_screen.dart';
import '../reports/reports_hub_screen.dart';
import '../chip_bank/chip_bank_screen.dart';
import '../reports/reports_screen.dart';
import '../session_shell/session_shell_screen.dart';
import '../settings/settings_screen.dart';

/// The home screen — the first thing a banker sees when they open the app
/// at the start of a night.
///
/// Deliberately built as a single scrolling surface with a large brand
/// hero at the top: this screen is not where the game is run, so it can
/// afford to look like a product rather than a form. The chip mark is
/// given real room (it is the app's identity, and it reads as a casino
/// chip only at size), sitting on a soft felt vignette, with the night's
/// headline numbers underneath so a returning host sees their standing
/// before they see a list.
class SessionListScreen extends StatefulWidget {
  const SessionListScreen({super.key});

  @override
  State<SessionListScreen> createState() => _SessionListScreenState();
}

class _SessionListScreenState extends State<SessionListScreen> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    // Session writes (new night, end session) notify this provider so
    // the home list is not stuck until the banker pops a route.
    context.watch<SessionProvider>();
    final all = HiveService.sessions.values.toList()
      ..sort((a, b) => b.dateTime.compareTo(a.dateTime));

    final matches = _query.isEmpty
        ? all
        : all
            .where((s) =>
                s.name.toLowerCase().contains(_query.toLowerCase()) ||
                s.location.toLowerCase().contains(_query.toLowerCase()))
            .toList();

    // A session that has ended must disappear from Active Sessions —
    // these two lists are strictly partitioned by status, not just
    // visually distinguished within one combined list.
    final activeSessions =
        matches.where((s) => s.status != SessionStatus.ended).toList();
    final pastSessions =
        matches.where((s) => s.status == SessionStatus.ended).toList();

    return Scaffold(
      backgroundColor: AppColors.background,
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: AppColors.accentGreen,
        foregroundColor: Colors.black,
        onPressed: () async {
          await Navigator.of(context)
              .push(MaterialPageRoute(builder: (_) => const NewSessionScreen()));
          if (mounted) setState(() {});
        },
        icon: const Icon(Icons.add),
        label: Text(tr('new_session'),
            style: const TextStyle(fontWeight: FontWeight.bold)),
      ),
      body: SafeArea(
        bottom: false,
        child: CustomScrollView(
          slivers: [
            SliverToBoxAdapter(child: _buildHero(all, activeSessions.length)),
            SliverToBoxAdapter(child: _buildSearch()),
            if (activeSessions.isEmpty && pastSessions.isEmpty)
              SliverFillRemaining(hasScrollBody: false, child: _buildEmpty())
            else ...[
              if (activeSessions.isNotEmpty) ...[
                _header(tr('active_sessions'), activeSessions.length),
                _list(activeSessions),
              ],
              if (pastSessions.isNotEmpty) ...[
                _header(tr('past_sessions'), pastSessions.length),
                _list(pastSessions),
              ],
              const SliverToBoxAdapter(child: SizedBox(height: 96)),
            ],
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------- hero

  Widget _buildHero(List<PokerSession> all, int activeCount) {
    final totalRake = all.fold<double>(0, (sum, s) => sum + SessionService.hostProfit(s.id));
    // Headline figures are only meaningful when every session shares a
    // currency; mixing Toman and USD into one total would be a lie. Fall
    // back to the most recent session's currency and only show the total
    // when it is unambiguous.
    final currencies = all.map((s) => s.currency).toSet();
    final showTotals = all.isNotEmpty && currencies.length == 1;
    final fmt = CurrencyFormatter(all.isEmpty ? AppCurrency.usd : all.first.currency);
    // Watched, so toggling the eye rebuilds this card immediately and
    // the choice survives a restart via the settings box.
    final showRake = context.watch<SettingsProvider>().showCumulativeRake;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 26),
      decoration: BoxDecoration(
        gradient: const RadialGradient(
          center: Alignment(0, -0.55),
          radius: 1.15,
          colors: [
            AppColors.feltDeep,
            AppColors.background,
          ],
          stops: [0.0, 0.95],
        ),
        border: Border(bottom: BorderSide(color: AppColors.gold.withValues(alpha: 0.22))),
      ),
      child: Column(
        children: [
          // Settings tucked to the corner so it never competes with the
          // brand mark for attention.
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              Builder(builder: (ctx) {
                final settings = ctx.watch<SettingsProvider>();
                return IconButton(
                  tooltip: settings.privacyMode
                      ? 'Show amounts'
                      : 'Hide amounts (privacy mode)',
                  icon: Icon(
                    settings.privacyMode
                        ? Icons.visibility_off_outlined
                        : Icons.visibility_outlined,
                    color: settings.privacyMode
                        ? AppColors.gold
                        : AppColors.textSecondary,
                  ),
                  onPressed: () =>
                      ctx.read<SettingsProvider>().togglePrivacyMode(),
                );
              }),
              IconButton(
                tooltip: tr('reports'),
                icon: const Icon(Icons.assessment_outlined,
                    color: AppColors.textSecondary),
                onPressed: () async {
                  await Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => const ReportsHubScreen()));
                  if (mounted) setState(() {});
                },
              ),
              IconButton(
                tooltip: tr('players'),
                icon: const Icon(Icons.people_outline,
                    color: AppColors.textSecondary),
                onPressed: () async {
                  await Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => const PlayersDirectoryScreen()));
                  if (mounted) setState(() {});
                },
              ),
              IconButton(
                tooltip: tr('chip_bank'),
                icon: const Icon(Icons.album_outlined,
                    color: AppColors.textSecondary),
                onPressed: () async {
                  await Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => const ChipBankScreen()));
                  if (mounted) setState(() {});
                },
              ),
              IconButton(
                tooltip: tr('settings'),
                icon: const Icon(Icons.settings_outlined,
                    color: AppColors.textSecondary),
                onPressed: () async {
                  await Navigator.of(context)
                      .push(MaterialPageRoute(builder: (_) => const SettingsScreen()));
                  if (mounted) setState(() {});
                },
              ),
            ],
          ),
          const SizedBox(height: 2),
          // The mark, given real presence. Sized off the screen width so
          // it stays balanced on both a small phone and a tablet.
          LayoutBuilder(
            builder: (ctx, c) {
              final logoSize = (c.maxWidth * 0.52).clamp(140.0, 210.0);
              return PokerChipLogo(size: logoSize);
            },
          ),
          const SizedBox(height: 16),
          ShaderMask(
            shaderCallback: (rect) => const LinearGradient(
              colors: [Color(0xFFFFF3C4), Color(0xFFD4AF37), Color(0xFFB8922C)],
            ).createShader(rect),
            child: const Text(
              'POKER LEDGER',
              style: TextStyle(
                fontSize: 25,
                fontWeight: FontWeight.w800,
                letterSpacing: 5,
                color: Colors.white,
              ),
            ),
          ),
          const SizedBox(height: 7),
          const GoldDivider(width: 130),
          const SizedBox(height: 9),
          Text(
            tr('tagline'),
            style: TextStyle(
              fontSize: 12,
              letterSpacing: 0.4,
              color: AppColors.textSecondary.withValues(alpha: 0.95),
            ),
          ),
          const SizedBox(height: 20),
          Row(
            children: [
              _heroStat(
                label: tr('active'),
                value: '$activeCount',
                color: activeCount > 0 ? AppColors.accentGreen : AppColors.textSecondary,
                icon: Icons.play_circle_outline,
              ),
              const SizedBox(width: 10),
              _heroStat(
                label: tr('sessions'),
                value: '${all.length}',
                color: AppColors.textPrimary,
                icon: Icons.history_toggle_off,
              ),
              const SizedBox(width: 10),
              // Total Rake is the one figure a guest is most likely to
              // read over the banker's shoulder, so it gets its own
              // show/hide. Display only: `totalRake` above is still the
              // existing SessionService.hostProfit fold, computed and
              // unchanged either way — only the rendered string differs.
              _heroStat(
                label: tr('total_rake_label'),
                value: !showRake
                    ? CurrencyFormatter.maskedText
                    : (showTotals ? fmt.format(totalRake) : '—'),
                color: AppColors.gold,
                icon: Icons.savings_outlined,
                isHidden: !showRake,
                onToggleVisibility: () =>
                    context.read<SettingsProvider>().toggleCumulativeRake(),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _heroStat({
    required String label,
    required String value,
    required Color color,
    required IconData icon,
    /// When supplied, the tile becomes tappable and shows an eye
    /// affordance beside its label. Only the Total Rake tile uses this;
    /// the others are unchanged.
    VoidCallback? onToggleVisibility,
    bool isHidden = false,
  }) {
    final tile = Container(
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 10),
      decoration: BoxDecoration(
        color: AppColors.surface.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.divider),
      ),
      child: Column(
        children: [
          Icon(icon, size: 16, color: color.withValues(alpha: 0.85)),
          const SizedBox(height: 6),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              value,
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: color),
            ),
          ),
          const SizedBox(height: 3),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Text(
                  label.toUpperCase(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 9,
                    letterSpacing: 0.9,
                    color: AppColors.textSecondary,
                  ),
                ),
              ),
              if (onToggleVisibility != null) ...[
                const SizedBox(width: 4),
                Icon(
                  isHidden
                      ? Icons.visibility_off_outlined
                      : Icons.visibility_outlined,
                  size: 11,
                  color: AppColors.textSecondary,
                ),
              ],
            ],
          ),
        ],
      ),
    );

    return Expanded(
      child: onToggleVisibility == null
          ? tile
          : InkWell(
              borderRadius: BorderRadius.circular(14),
              onTap: onToggleVisibility,
              child: tile,
            ),
    );
  }

  // -------------------------------------------------------------- pieces

  Widget _buildSearch() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 6),
      child: TextField(
        decoration: InputDecoration(
          prefixIcon: const Icon(Icons.search, size: 20),
          hintText: tr('search_sessions'),
          filled: true,
          fillColor: AppColors.surface,
          contentPadding: const EdgeInsets.symmetric(vertical: 4),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: const BorderSide(color: AppColors.divider),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: const BorderSide(color: AppColors.divider),
          ),
        ),
        onChanged: (v) => setState(() => _query = v),
      ),
    );
  }

  Widget _buildEmpty() => EmptyState(
        icon: Icons.style_outlined,
        title: tr('no_sessions_yet'),
        message: tr('no_sessions_hint'),
      );

  SliverToBoxAdapter _header(String title, int count) {
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 20, 18, 10),
        child: Row(
          children: [
            Container(width: 3, height: 13, color: AppColors.gold),
            const SizedBox(width: 9),
            Text(
              title.toUpperCase(),
              style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.bold,
                letterSpacing: 1.3,
                color: AppColors.textSecondary,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              '$count',
              style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.bold,
                color: AppColors.gold,
              ),
            ),
          ],
        ),
      ),
    );
  }

  SliverList _list(List<PokerSession> sessions) {
    return SliverList(
      delegate: SliverChildBuilderDelegate(
        (ctx, i) => Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
          child: _SessionTile(
            session: sessions[i],
            onReturn: () {
              if (mounted) setState(() {});
            },
          ),
        ),
        childCount: sessions.length,
      ),
    );
  }
}

class _SessionTile extends StatelessWidget {
  final PokerSession session;
  final VoidCallback onReturn;
  const _SessionTile({required this.session, required this.onReturn});

  @override
  Widget build(BuildContext context) {
    final fmt = CurrencyFormatter(session.currency);
    final isEnded = session.status == SessionStatus.ended;
    final onBreak = session.status == SessionStatus.onBreak;
    final profit = SessionService.hostProfit(session.id);
    final playerCount = SessionService.playersFor(session.id).length;

    final accent = isEnded
        ? AppColors.textSecondary
        : (onBreak ? AppColors.warning : AppColors.accentGreen);

    return Container(
      decoration: BoxDecoration(
        color: AppColors.surfaceElevated,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isEnded ? AppColors.divider : accent.withValues(alpha: 0.45),
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () async {
            await Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => isEnded
                    ? ReportsScreen(sessionId: session.id)
                    : SessionShellScreen(sessionId: session.id),
              ),
            );
            onReturn();
          },
          child: IntrinsicHeight(
            child: Row(
              children: [
                // Status spine — status readable at a glance from the
                // edge of the card, before reading any text.
                Container(width: 4, color: accent),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
                    child: Row(
                      children: [
                        Container(
                          height: 42,
                          width: 42,
                          decoration: BoxDecoration(
                            color: accent.withValues(alpha: isEnded ? 0.12 : 0.18),
                            shape: BoxShape.circle,
                            border: Border.all(color: accent.withValues(alpha: 0.5)),
                          ),
                          child: Icon(
                            isEnded
                                ? Icons.check
                                : (onBreak ? Icons.pause : Icons.play_arrow),
                            color: accent,
                            size: 20,
                          ),
                        ),
                        const SizedBox(width: 13),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                session.name,
                                style: const TextStyle(
                                    fontWeight: FontWeight.bold, fontSize: 15),
                                overflow: TextOverflow.ellipsis,
                              ),
                              const SizedBox(height: 4),
                              Text(
                                '${session.location} · '
                                '${session.dateTime.toString().substring(0, 16)}',
                                style: const TextStyle(
                                    fontSize: 11.5, color: AppColors.textSecondary),
                                overflow: TextOverflow.ellipsis,
                              ),
                              const SizedBox(height: 5),
                              Row(
                                children: [
                                  _pill(
                                    isEnded
                                        ? 'ENDED'
                                        : (onBreak ? 'ON BREAK' : 'ACTIVE'),
                                    accent,
                                  ),
                                  const SizedBox(width: 6),
                                  _pill('Table ${session.tableNumber}',
                                      AppColors.textSecondary),
                                  if (playerCount > 0) ...[
                                    const SizedBox(width: 6),
                                    _pill('$playerCount seated',
                                        AppColors.textSecondary),
                                  ],
                                ],
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(
                              fmt.format(profit),
                              style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                  color: AppColors.gold,
                                  fontSize: 14),
                            ),
                            const SizedBox(height: 2),
                            Text(tr('rake').toUpperCase(),
                                style: TextStyle(
                                    fontSize: 8.5,
                                    letterSpacing: 0.8,
                                    color: AppColors.textSecondary)),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _pill(String text, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: color.withValues(alpha: 0.4)),
        ),
        child: Text(
          text,
          style: TextStyle(fontSize: 9, fontWeight: FontWeight.bold, color: color),
        ),
      );
}
