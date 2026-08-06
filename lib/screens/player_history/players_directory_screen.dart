import 'package:flutter/material.dart';
import '../../core/localization/app_localizations.dart';

import '../../core/theme/app_theme.dart';
import '../../core/utils/currency_formatter.dart';
import '../../services/player_history_service.dart';
import 'player_history_screen.dart';

/// Every player the host has ever seated, across all sessions — the
/// "regulars book". Tapping one opens their full cross-session history.
///
/// Read-only aggregation over existing data; nothing here touches the
/// ledger.
class PlayersDirectoryScreen extends StatefulWidget {
  const PlayersDirectoryScreen({super.key});

  @override
  State<PlayersDirectoryScreen> createState() => _PlayersDirectoryScreenState();
}

enum _Sort { recent, name, sessions, profit }

class _PlayersDirectoryScreenState extends State<PlayersDirectoryScreen> {
  String _query = '';
  _Sort _sort = _Sort.recent;

  List<PlayerCareer> _sorted(List<PlayerCareer> careers) {
    final list = [...careers];
    switch (_sort) {
      case _Sort.recent:
        list.sort((a, b) {
          final al = a.lastPlayed, bl = b.lastPlayed;
          if (al == null || bl == null) return a.name.compareTo(b.name);
          return bl.compareTo(al);
        });
        break;
      case _Sort.name:
        list.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
        break;
      case _Sort.sessions:
        list.sort((a, b) => b.sessionsPlayed.compareTo(a.sessionsPlayed));
        break;
      case _Sort.profit:
        // Players with mixed currencies sort last: their lifetime total
        // isn't a comparable number.
        list.sort((a, b) {
          if (a.hasConsistentCurrency != b.hasConsistentCurrency) {
            return a.hasConsistentCurrency ? -1 : 1;
          }
          return b.netResult.compareTo(a.netResult);
        });
        break;
    }
    return list;
  }

  @override
  Widget build(BuildContext context) {
    final careers = _sorted(PlayerHistoryService.search(_query));

    return Scaffold(
      appBar: AppBar(title: Text(tr('players'))),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: TextField(
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search, size: 20),
                hintText: tr('search_players'),
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
          ),
          SizedBox(
            height: 40,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              children: [
                _sortChip('Recent', _Sort.recent),
                _sortChip('Name', _Sort.name),
                _sortChip('Sessions', _Sort.sessions),
                _sortChip('Profit', _Sort.profit),
              ],
            ),
          ),
          const SizedBox(height: 4),
          Expanded(
            child: careers.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(28),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.people_outline,
                              size: 38, color: AppColors.gold.withValues(alpha: 0.6)),
                          const SizedBox(height: 12),
                          Text(
                            _query.isEmpty
                                ? 'No players yet. Seat someone in a session '
                                    'and they will appear here.'
                                : 'No players match “$_query”.',
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                                color: AppColors.textSecondary, fontSize: 13),
                          ),
                        ],
                      ),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                    itemCount: careers.length,
                    itemBuilder: (ctx, i) => _careerTile(careers[i]),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _sortChip(String label, _Sort value) {
    final selected = _sort == value;
    return Padding(
      padding: const EdgeInsetsDirectional.only(end: 8),
      child: ChoiceChip(
        label: Text(label, style: const TextStyle(fontSize: 12)),
        selected: selected,
        onSelected: (_) => setState(() => _sort = value),
        selectedColor: AppColors.gold.withValues(alpha: 0.18),
        labelStyle: TextStyle(
          color: selected ? AppColors.gold : AppColors.textSecondary,
          fontWeight: selected ? FontWeight.bold : FontWeight.normal,
        ),
      ),
    );
  }

  Widget _careerTile(PlayerCareer c) {
    final fmt = CurrencyFormatter(c.currency);
    final mixed = !c.hasConsistentCurrency;
    final net = c.netResult;
    final up = net >= 0;

    return Padding(
      padding: const EdgeInsets.only(bottom: 9),
      child: Material(
        color: AppColors.surfaceElevated,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => PlayerHistoryScreen(playerName: c.name),
            ),
          ),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: AppColors.divider),
            ),
            child: Row(
              children: [
                CircleAvatar(
                  radius: 19,
                  backgroundColor: AppColors.feltGreen,
                  child: Text(
                    c.name.isNotEmpty ? c.name[0].toUpperCase() : '?',
                    style: const TextStyle(
                        fontWeight: FontWeight.bold, fontSize: 14),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(c.name,
                          style: const TextStyle(
                              fontWeight: FontWeight.bold, fontSize: 14),
                          overflow: TextOverflow.ellipsis),
                      const SizedBox(height: 3),
                      Text(
                        '${c.sessionsPlayed} session${c.sessionsPlayed == 1 ? '' : 's'}'
                        '${c.lastPlayed != null ? ' · last ${c.lastPlayed.toString().substring(0, 10)}' : ''}',
                        style: const TextStyle(
                            fontSize: 11, color: AppColors.textSecondary),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      mixed ? '—' : '${up ? '+' : ''}${fmt.format(net)}',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 13.5,
                        color: mixed
                            ? AppColors.textSecondary
                            : (up ? AppColors.accentGreen : AppColors.danger),
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(tr('lifetime'),
                        style: TextStyle(
                            fontSize: 8.5,
                            letterSpacing: 0.7,
                            color: AppColors.textSecondary)),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
