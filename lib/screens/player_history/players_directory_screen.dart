import 'package:flutter/material.dart';
import '../../core/localization/app_localizations.dart';
import '../../core/localization/enum_labels.dart';

import '../../core/theme/app_theme.dart';
import '../../core/utils/currency_formatter.dart';
import '../../models/enums.dart';
import '../../services/player_history_service.dart';
import '../../services/player_identity_service.dart';
import '../../services/player_registry_service.dart';
import '../../widgets/identity_link_sheet.dart';
import '../../widgets/player_type_badge.dart';
import '../player_account/player_account_screen.dart';
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

  /// Null = "All". Filtering is a pure view concern: it narrows what is
  /// listed and never writes to a player.
  PlayerTag? _typeFilter;

  /// Shows only blacklisted people, so the banker can review the bar
  /// list without scrolling the whole directory.
  bool _blacklistedOnly = false;

  List<PlayerCareer> _filtered(List<PlayerCareer> careers) {
    return careers.where((c) {
      if (_blacklistedOnly &&
          !PlayerRegistryService.statusForPersonId(c.personId, c.name)
              .isBlacklisted) {
        return false;
      }
      if (_typeFilter == null) return true;
      return PlayerRegistryService.tagForPersonId(c.personId, c.name) ==
          _typeFilter;
    }).toList();
  }

  /// Player-management actions, reached from the row's overflow menu.
  ///
  /// Everything here writes ONLY person-level attributes via
  /// [PlayerRegistryService]. No Player row, session or transaction is
  /// touched, so history, lifetime figures, accounting and settlement
  /// are untouched by design.

  /// Lets the banker set (or clear) the classification.
  ///
  /// Re-tapping the current type clears it, so "unclassified" stays a
  /// reachable state rather than a one-way door into a category.
  Future<void> _changeType(PlayerCareer c) async {
    final current = PlayerRegistryService.tagForPersonId(c.personId, c.name);

    await showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 16, 18, 2),
              child: Text(tr('player_type'),
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.bold)),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 0, 18, 12),
              child: Text(
                '${c.name} · ${tr('player_type_classification_note')}',
                style: const TextStyle(
                    fontSize: 11, color: AppColors.textSecondary),
              ),
            ),
            const Divider(height: 1),
            for (final t in PlayerTag.values)
              ListTile(
                leading: Icon(t.icon, color: t.color),
                title: Text(t.localizedLabel),
                trailing: current == t
                    ? const Icon(Icons.check, color: AppColors.accentGreen)
                    : null,
                onTap: () async {
                  Navigator.pop(ctx);
                  await PlayerRegistryService.setTagForPerson(
                      c.personId, c.name, current == t ? null : t);
                  if (mounted) setState(() {});
                },
              ),
            const SizedBox(height: 6),
          ],
        ),
      ),
    );
  }

  /// Registers a NEW person with no session and no seat.
  ///
  /// Pre-seat registration: the identity is created (or linked through
  /// confirm-on-suggest when the name already exists) and immediately
  /// appears in the directory, where its account — deposits, credit,
  /// markers — can be used before the person ever takes a seat.
  Future<void> _registerPerson() async {
    final nameCtrl = TextEditingController();
    final noteCtrl = TextEditingController();

    final created = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: 16,
          bottom: MediaQuery.of(ctx).viewInsets.bottom + 16,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(tr('register_person_title'),
                style: const TextStyle(
                    fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Text(tr('register_person_hint'),
                style: const TextStyle(
                    fontSize: 12, color: AppColors.textSecondary)),
            const SizedBox(height: 12),
            TextField(
              controller: nameCtrl,
              autofocus: true,
              decoration: InputDecoration(labelText: tr('name')),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: noteCtrl,
              decoration:
                  InputDecoration(labelText: tr('player_note_optional')),
            ),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: () async {
                final name = nameCtrl.text.trim();
                if (name.isEmpty) return;

                final suggestions = PlayerIdentityService.suggest(name);
                String? personId;
                if (suggestions.isEmpty) {
                  personId = (await PlayerIdentityService.createNew(name))
                      ?.id;
                } else {
                  // A name match is only a suggestion — confirm before
                  /// linking, never auto-merge. Cancel aborts.
                  final result = await confirmIdentityLink(
                    ctx,
                    typedName: name,
                    suggestions: suggestions,
                  );
                  if (result.isCancel) return;
                  if (result.isLink) personId = result.personId;
                  if (personId == null) {
                    personId = (await PlayerIdentityService.createNew(name))
                        ?.id;
                  }
                }
                if (personId == null) return;
                if (noteCtrl.text.trim().isNotEmpty) {
                  final identity = PlayerIdentityService.byId(personId);
                  if (identity != null) {
                    identity.note = noteCtrl.text.trim();
                    await identity.save();
                  }
                }
                Navigator.pop(ctx, true);
              },
              child: Text(tr('register_player')),
            ),
          ],
        ),
      ),
    );
    if (created == true && mounted) setState(() {});
  }

  /// Bars a player from future seating. Confirmed first, because it
  /// changes how every later Add Player behaves for this person.
  Future<void> _blacklist(PlayerCareer c) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('blacklist_player_q')),
        content: Text(
          '${c.name} ${tr('blacklist_warning_body')}\n\n'
          '${tr('blacklist_warning_history')}',
          style: const TextStyle(fontSize: 13),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(tr('cancel'))),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.danger),
            child: Text(tr('blacklist')),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await PlayerRegistryService.blacklist(c.name, personId: c.personId);
    if (mounted) setState(() {});
  }

  /// Returns a player to Active. Historical data is untouched.
  Future<void> _unblacklist(PlayerCareer c) async {
    await PlayerRegistryService.unblacklist(c.name, personId: c.personId);
    if (mounted) setState(() {});
  }

  List<PlayerCareer> _sorted(List<PlayerCareer> list) {
    list.sort((a, b) {
      switch (_sort) {
        case _Sort.name:
          return a.name.toLowerCase().compareTo(b.name.toLowerCase());
        case _Sort.sessions:
          return b.sessionsPlayed.compareTo(a.sessionsPlayed);
        case _Sort.profit:
          return b.netResult.compareTo(a.netResult);
        case _Sort.recent:
          final aLast = a.lastPlayed;
          final bLast = b.lastPlayed;
          if (aLast == null && bLast == null) {
            return a.name.toLowerCase().compareTo(b.name.toLowerCase());
          }
          if (aLast == null) return 1;
          if (bLast == null) return -1;
          return bLast.compareTo(aLast);
      }
    });
    return list;
  }

  @override
  Widget build(BuildContext context) {
    final careers = _sorted(_filtered(PlayerHistoryService.searchBank(_query)));

    return Scaffold(
      appBar: AppBar(
        title: Text(tr('players')),
        actions: [
          IconButton(
            tooltip: tr('register_person_title'),
            icon: const Icon(Icons.person_add_alt_outlined),
            onPressed: _registerPerson,
          ),
        ],
      ),
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
                _sortChip(tr('sort_recent'), _Sort.recent),
                _sortChip(tr('sort_name'), _Sort.name),
                _sortChip(tr('sort_sessions'), _Sort.sessions),
                _sortChip(tr('sort_profit'), _Sort.profit),
              ],
            ),
          ),
          // Player Type filter. A separate row from the sort chips so
          // the two controls are not confused for one another — sorting
          // reorders, filtering narrows.
          SizedBox(
            height: 40,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              children: [
                _typeChip(tr('filter_all'), null),
                for (final t in PlayerTag.values) _typeChip(t.localizedLabel, t),
                Padding(
                  padding: const EdgeInsetsDirectional.only(end: 8),
                  child: FilterChip(
                    avatar: Icon(Icons.block,
                        size: 14,
                        color: _blacklistedOnly
                            ? AppColors.danger
                            : AppColors.textSecondary),
                    label: Text(tr('blacklisted'),
                        style: TextStyle(fontSize: 12)),
                    selected: _blacklistedOnly,
                    onSelected: (v) =>
                        setState(() => _blacklistedOnly = v),
                    selectedColor: AppColors.danger.withValues(alpha: 0.18),
                    labelStyle: TextStyle(
                      color: _blacklistedOnly
                          ? AppColors.danger
                          : AppColors.textSecondary,
                      fontWeight: _blacklistedOnly
                          ? FontWeight.bold
                          : FontWeight.normal,
                    ),
                  ),
                ),
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

  /// One Player Type filter chip. `null` is the "All" option.
  Widget _typeChip(String label, PlayerTag? value) {
    final selected = _typeFilter == value;
    final c = value?.color ?? AppColors.gold;
    return Padding(
      padding: const EdgeInsetsDirectional.only(end: 8),
      child: ChoiceChip(
        avatar: value == null
            ? null
            : Icon(value.icon,
                size: 14, color: selected ? c : AppColors.textSecondary),
        label: Text(label, style: const TextStyle(fontSize: 12)),
        selected: selected,
        onSelected: (_) => setState(
            () => _typeFilter = _typeFilter == value ? null : value),
        selectedColor: c.withValues(alpha: 0.18),
        labelStyle: TextStyle(
          color: selected ? c : AppColors.textSecondary,
          fontWeight: selected ? FontWeight.bold : FontWeight.normal,
        ),
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
    final tag = PlayerRegistryService.tagForPersonId(c.personId, c.name);
    final blacklisted =
        PlayerRegistryService.statusForPersonId(c.personId, c.name)
            .isBlacklisted;

    return Padding(
      padding: const EdgeInsets.only(bottom: 9),
      child: Material(
        color: AppColors.surfaceElevated,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => PlayerHistoryScreen(
              playerName: c.name,
              personId: c.personId,
            ),
            ),
          ),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: blacklisted
                    ? AppColors.danger.withValues(alpha: 0.55)
                    : AppColors.divider,
              ),
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
                      Row(
                        children: [
                          Flexible(
                            child: Text(c.name,
                                style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 14),
                                overflow: TextOverflow.ellipsis),
                          ),
                          if (tag != null) ...[
                            const SizedBox(width: 6),
                            PlayerTypeBadge(tag: tag),
                          ],
                          if (blacklisted) ...[
                            const SizedBox(width: 5),
                            const BlacklistBadge(iconOnly: true),
                          ],
                        ],
                      ),
                      const SizedBox(height: 3),
                      Text(
                        c.hasPersistentIdentity
                            ? '${c.sessionsPlayed} session${c.sessionsPlayed == 1 ? '' : 's'}'
                                '${c.lastPlayed != null ? ' · last ${c.lastPlayed.toString().substring(0, 10)}' : ''}'
                                ' · …${_idTail(c.personId!)}'
                            : '${tr('identity_legacy_group')}'
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
                // Explicit management menu.
                //
                // Replaces the previous long-press, which worked but was
                // invisible — nothing on screen told the banker the
                // gesture existed. Tapping the row still opens the
                // player's history, so the primary navigation is
                // unchanged; this only surfaces the actions that were
                // already there.
                //
                // Items are built from the player's CURRENT state, so
                // Blacklist and Unblacklist are never offered together.
                PopupMenuButton<String>(
                  tooltip: tr('manage_player'),
                  icon: const Icon(Icons.more_vert,
                      size: 18, color: AppColors.textSecondary),
                  padding: EdgeInsets.zero,
                  onSelected: (v) {
                    switch (v) {
                      case 'type':
                        _changeType(c);
                        break;
                      case 'account':
                        if (c.hasPersistentIdentity && mounted) {
                          Navigator.of(context).push(MaterialPageRoute(
                            builder: (_) => PlayerAccountScreen(
                              personId: c.personId!,
                              displayName: c.name,
                            ),
                          ));
                        }
                        break;
                      case 'blacklist':
                        _blacklist(c);
                        break;
                      case 'unblacklist':
                        _unblacklist(c);
                        break;
                    }
                  },
                  itemBuilder: (_) => [
                    if (c.hasPersistentIdentity)
                      PopupMenuItem(
                        value: 'account',
                        child: Row(
                          children: [
                            const Icon(Icons.account_balance_wallet_outlined,
                                size: 18, color: AppColors.gold),
                            const SizedBox(width: 10),
                            Text(tr('view_financial_account')),
                          ],
                        ),
                      ),
                    PopupMenuItem(
                      value: 'type',
                      child: Row(
                        children: [
                          Icon(tag?.icon ?? Icons.label_outline,
                              size: 18, color: tag?.color ?? AppColors.gold),
                          const SizedBox(width: 10),
                          Text(tr('change_player_type')),
                        ],
                      ),
                    ),
                    if (blacklisted)
                      PopupMenuItem(
                        value: 'unblacklist',
                        child: Row(
                          children: [
                            const Icon(Icons.check_circle_outline,
                                size: 18, color: AppColors.accentGreen),
                            const SizedBox(width: 10),
                            Text(tr('unblacklist')),
                          ],
                        ),
                      )
                    else
                      PopupMenuItem(
                        value: 'blacklist',
                        child: Row(
                          children: [
                            const Icon(Icons.block,
                                size: 18, color: AppColors.danger),
                            const SizedBox(width: 10),
                            Text(tr('blacklist')),
                          ],
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
  }

  String _idTail(String id) =>
      id.length >= 4 ? id.substring(id.length - 4) : id;
}
