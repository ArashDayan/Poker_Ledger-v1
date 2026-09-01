import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/localization/app_localizations.dart';
import '../core/theme/app_theme.dart';
import '../models/player.dart';
import '../models/player_identity.dart';
import '../providers/session_provider.dart';
import '../services/player_identity_service.dart';
import '../services/player_registry_service.dart';
import '../services/seating_service.dart';
import '../services/table_service.dart';
import 'player_type_badge.dart';

enum _SeatStep { table, select, confirm, register }

/// Explicit Player Selection → Seating sheet (ICR-03).
///
/// Contract:
///   * An empty seat is NEVER seated just by opening this sheet.
///   * The operator searches a registered Player Identity by number or
///     name, or opens Register New.
///   * Register New writes only a Player Identity. No seat, no session
///     participation, no chip, no money.
///   * The final "Seat Player" action is the ONLY write that creates or
///     moves a seat. Back/Cancel/dismiss before that action writes
///     nothing.
Future<void> showSeatPlayerSheet(
  BuildContext context, {
  String? presetTableId,
  int? presetSeat,
}) async {
  final provider = context.read<SessionProvider>();
  if (provider.current == null) return;
  await showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    isDismissible: true,
    builder: (_) => _SeatPlayerSheet(
      initialTableId: presetTableId,
      initialSeat: presetSeat,
      linkMode: false,
    ),
  );
}

/// Explicit "Link to Existing Player" workflow for an occupied seat
/// that has no valid Player Identity link.
///
/// This is link-only. It does NOT create an identity, does NOT create a
/// seat and does NOT touch money/chips.
Future<void> showLinkExistingPlayerSheet(
  BuildContext context, {
  required Player player,
}) async {
  final provider = context.read<SessionProvider>();
  if (provider.current == null) return;
  await showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    isDismissible: true,
    builder: (_) => _SeatPlayerSheet(
      initialTableId: null,
      initialSeat: null,
      linkMode: true,
      seatToLink: player,
    ),
  );
}

class _SeatPlayerSheet extends StatefulWidget {
  final String? initialTableId;
  final int? initialSeat;
  final bool linkMode;
  final Player? seatToLink;

  const _SeatPlayerSheet({
    this.initialTableId,
    this.initialSeat,
    required this.linkMode,
    this.seatToLink,
  });

  @override
  State<_SeatPlayerSheet> createState() => _SeatPlayerSheetState();
}

class _SeatPlayerSheetState extends State<_SeatPlayerSheet> {
  late final SessionProvider _provider;
  late _SeatStep _step;
  String? _tableId;
  int? _seat;
  PlayerIdentity? _selected;

  final _searchController = TextEditingController();
  List<PlayerIdentity> _results = const [];

  // Register New fields (identity only).
  final _displayNameCtrl = TextEditingController();
  final _firstNameCtrl = TextEditingController();
  final _lastNameCtrl = TextEditingController();
  final _idNumberCtrl = TextEditingController();
  bool _creating = false;
  bool _seating = false;

  @override
  void initState() {
    super.initState();
    _provider = context.read<SessionProvider>();
    _tableId = widget.linkMode ? null : widget.initialTableId;
    _seat = widget.linkMode ? null : widget.initialSeat;
    _step = widget.linkMode
        ? _SeatStep.select
        : (_tableId != null && _seat != null
            ? _SeatStep.select
            : _SeatStep.table);
    _results = PlayerIdentityService.search('');
    _searchController.addListener(_onSearchChanged);
  }

  @override
  void dispose() {
    _searchController.dispose();
    _displayNameCtrl.dispose();
    _firstNameCtrl.dispose();
    _lastNameCtrl.dispose();
    _idNumberCtrl.dispose();
    super.dispose();
  }

  void _onSearchChanged() {
    setState(() {
      _results = PlayerIdentityService.search(_searchController.text);
    });
  }

  void _backToSelect() {
    setState(() {
      _step = _SeatStep.select;
      _selected = null;
    });
  }

  Future<void> _selectIdentity(PlayerIdentity identity) async {
    setState(() {
      _selected = identity;
      _step = _SeatStep.confirm;
    });
  }

  void _openRegister() {
    setState(() {
      _step = _SeatStep.register;
      _displayNameCtrl.text = '';
      _firstNameCtrl.text = '';
      _lastNameCtrl.text = '';
      _idNumberCtrl.text = '';
    });
  }

  /// Preserves the existing blacklist gate (strong warning, never a
  /// hard lock) on every explicit seat/link/register action. When the
  /// person is already known, the person-scoped registry entry is
  /// honoured too.
  Future<bool> _runBlacklistGate(
    BuildContext sheetContext,
    String playerName, {
    PlayerIdentity? identity,
  }) async {
    final blocked = identity == null
        ? PlayerRegistryService.isBlacklistedName(playerName)
        : PlayerRegistryService.statusForPersonId(identity.id, playerName)
            .isBlacklisted;
    if (!blocked) return true;
    return confirmBlacklistedPlayer(sheetContext, playerName: playerName);
  }

  Future<void> _saveIdentity(BuildContext sheetContext) async {
    final name = _displayNameCtrl.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(sheetContext)
          .showSnackBar(SnackBar(content: Text(tr('name_required'))));
      return;
    }
    if (!await _runBlacklistGate(sheetContext, name)) return;
    setState(() => _creating = true);
    try {
      final identity = await PlayerIdentityService.createNew(
        name,
        firstName: _firstNameCtrl.text.isEmpty ? null : _firstNameCtrl.text,
        lastName: _lastNameCtrl.text.isEmpty ? null : _lastNameCtrl.text,
        idNumber: _idNumberCtrl.text.trim().isEmpty
            ? null
            : _idNumberCtrl.text.trim(),
      );
      if (!mounted) return;
      if (identity == null) {
        setState(() => _creating = false);
        ScaffoldMessenger.of(sheetContext)
            .showSnackBar(SnackBar(content: Text(tr('identity_create_failed'))));
        return;
      }
      setState(() {
        _selected = identity;
        _step = _SeatStep.confirm;
        _creating = false;
      });
      ScaffoldMessenger.of(sheetContext).showSnackBar(
        SnackBar(
            content:
                Text('${identity.displayName} — ${tr('identity_created')}')),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _creating = false);
      ScaffoldMessenger.of(sheetContext)
          .showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  String _numberLabel(int number) => PlayerIdentityService.numberLabel(number);

  void _goToExistingSeat(BuildContext context, Player existing) {
    if (existing.tableId != null) {
      _provider.setActiveTable(existing.tableId!);
    }
    Navigator.of(context).popUntil((route) => route.isFirst);
  }

  Future<void> _showDuplicateDialog(
      BuildContext sheetContext, Player? existing) async {
    if (existing == null) return;
    final session = _provider.current!;
    final table = TableService.tableForPlayer(session, existing);
    final titleKey =
        existing.seated ? 'duplicate_active_title' : 'already_registered_title';
    final bodyKey = existing.seated
        ? 'duplicate_active_body'
        : 'already_registered_unseated_body';
    final message = tr(bodyKey)
        .replaceAll('{name}', existing.name)
        .replaceAll('{table}', table.name)
        .replaceAll('{seat}', '${existing.seatNumber}');
    final goPlayers = await showDialog<bool>(
      context: sheetContext,
      builder: (ctx) => AlertDialog(
        title: Text(tr(titleKey),
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
        content: Text(message, style: const TextStyle(fontSize: 13.5)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false), child: Text(tr('cancel'))),
          if (existing.seated)
            ElevatedButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: Text(tr('go_to_seat'))),
        ],
      ),
    );
    if (goPlayers == true && sheetContext.mounted) {
      _goToExistingSeat(sheetContext, existing);
    }
  }

  Future<void> _seatAction(BuildContext sheetContext) async {
    final identity = _selected;
    if (identity == null || _tableId == null || _seat == null) return;
    if (!await _runBlacklistGate(sheetContext, identity.displayName,
        identity: identity)) {
      return;
    }
    setState(() => _seating = true);
    try {
      final result = await SeatingService.seatPlayerAt(
        provider: _provider,
        personId: identity.id,
        tableId: _tableId!,
        seatNumber: _seat!,
      );
      if (!mounted) return;
      if (!result.succeeded) {
        setState(() => _seating = false);
        if (result.block.reason ==
            SeatingBlockReason.duplicateActiveParticipation) {
          await _showDuplicateDialog(
              sheetContext, result.block.existingParticipation);
        } else if (sheetContext.mounted) {
          ScaffoldMessenger.of(sheetContext)
            ..hideCurrentSnackBar()
            ..showSnackBar(SnackBar(content: Text(tr('seat_blocked'))));
        }
        return;
      }
      if (sheetContext.mounted) {
        final table =
            TableService.tableById(_provider.current!, _tableId!);
        ScaffoldMessenger.of(sheetContext).showSnackBar(
          SnackBar(
            content: Text('${identity.displayName} — ${tr('seated')} '
                '${_seat!} · ${table.name}'),
          ),
        );
        Navigator.of(sheetContext).pop();
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _seating = false);
      ScaffoldMessenger.of(sheetContext)
          .showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  Future<void> _confirmAction(BuildContext sheetContext) {
    return widget.linkMode
        ? _linkAction(sheetContext)
        : _seatAction(sheetContext);
  }

  Future<void> _linkAction(BuildContext sheetContext) async {
    final identity = _selected;
    final seat = widget.seatToLink;
    if (identity == null || seat == null) return;
    if (!await _runBlacklistGate(sheetContext, identity.displayName,
        identity: identity)) {
      return;
    }
    final session = _provider.current!;
    final block = SeatingService.linkBlocker(
      session: session,
      seat: seat,
      personId: identity.id,
    );
    if (!block.ok) {
      await _showDuplicateDialog(sheetContext, block.existingParticipation);
      return;
    }
    setState(() => _seating = true);
    try {
      await SeatingService.linkPlayer(seat, identity.id);
      if (!mounted) return;
      if (sheetContext.mounted) {
        ScaffoldMessenger.of(sheetContext).showSnackBar(
          SnackBar(content: Text('${identity.displayName} — ${tr('linked_to_seat')}')),
        );
        Navigator.of(sheetContext).pop();
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _seating = false);
      ScaffoldMessenger.of(sheetContext)
          .showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  Future<void> _chooseTable(String tableId, int seat) async {
    setState(() {
      _tableId = tableId;
      _seat = seat;
      _step = _SeatStep.select;
    });
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          left: 18,
          right: 18,
          top: 16,
          bottom: MediaQuery.of(context).viewInsets.bottom + 16,
        ),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.85,
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    const Icon(Icons.person_search_outlined,
                        color: AppColors.accentGreen),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _stepTitle(),
                        style: const TextStyle(
                            fontSize: 18, fontWeight: FontWeight.bold),
                      ),
                    ),
                    IconButton(
                      tooltip: tr('cancel'),
                      icon: const Icon(Icons.close),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(_stepSubtitle(),
                    style: const TextStyle(
                        fontSize: 12, color: AppColors.textSecondary)),
                const SizedBox(height: 16),
                if (_step == _SeatStep.table) _buildTableStep(context),
                if (_step == _SeatStep.select) _buildSelectStep(context),
                if (_step == _SeatStep.confirm) _buildConfirmStep(context),
                if (_step == _SeatStep.register) _buildRegisterStep(context),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _stepTitle() {
    switch (_step) {
      case _SeatStep.table:
        return tr('select_table_and_seat');
      case _SeatStep.select:
        return widget.linkMode
            ? tr('link_to_existing_player')
            : tr('select_player');
      case _SeatStep.confirm:
        return widget.linkMode ? tr('confirm_link_player') : tr('confirm_seat_player');
      case _SeatStep.register:
        return tr('register_new_player');
    }
  }

  String _stepSubtitle() {
    if (widget.linkMode) {
      return tr('link_occupied_seat_hint');
    }
    switch (_step) {
      case _SeatStep.table:
        return tr('select_table_seat_hint');
      case _SeatStep.select:
        return tr('select_player_hint');
      case _SeatStep.confirm:
        {
          final table = _tableId == null
              ? null
              : TableService.tableById(_provider.current!, _tableId!);
          return '${table?.name ?? '—'} · ${tr('seat')} ${_seat ?? '—'}';
        }
      case _SeatStep.register:
        return tr('register_new_hint');
    }
  }

  Widget _buildTableStep(BuildContext context) {
    final session = _provider.current!;
    final tables = TableService.tablesFor(session);
    final available = tables
        .where((t) => !t.status.isClosed)
        .where((t) => TableService.firstFreeSeat(session, t.id) != null)
        .toList();
    if (available.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 24),
        child: Center(
          child: Text(tr('all_tables_full'),
              style: const TextStyle(color: AppColors.textSecondary)),
        ),
      );
    }
    return Column(
      children: available.map((t) {
        final free = TableService.firstFreeSeat(session, t.id)!;
        final count = TableService.playerCountAt(session, t.id);
        return ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.table_bar_outlined,
              color: AppColors.accentGreen),
          title: Text(t.name),
          subtitle: Text(
              '${tr('seat')} $free ${tr('free')} · $count/${t.seatCount} ${tr('seated')}'),
          onTap: () => _chooseTable(t.id, free),
        );
      }).toList(),
    );
  }

  Widget _buildSelectStep(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _searchController,
          autofocus: !widget.linkMode,
          decoration: InputDecoration(
            labelText: tr('search_player_number_or_name'),
            prefixIcon: const Icon(Icons.search),
          ),
        ),
        const SizedBox(height: 12),
        if (_results.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Text(tr('no_identity_match'),
                style:
                    const TextStyle(color: AppColors.textSecondary)),
          )
        else
          ..._results.map((identity) {
            return Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Material(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(12),
                child: InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: () => _selectIdentity(identity),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 10),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: AppColors.divider),
                    ),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 52,
                          child: Text(
                            '#${_numberLabel(identity.playerNumber)}',
                            style: const TextStyle(
                                fontWeight: FontWeight.bold,
                                color: AppColors.accentGreen),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(identity.displayName.isEmpty
                                  ? '—'
                                  : identity.displayName,
                                  style: const TextStyle(
                                      fontWeight: FontWeight.w600)),
                              if (identity.idNumber != null &&
                                  identity.idNumber!.trim().isNotEmpty)
                                Text(identity.idNumber!.trim(),
                                    style: const TextStyle(
                                        fontSize: 11,
                                        color: AppColors.textSecondary)),
                            ],
                          ),
                        ),
                        const Icon(Icons.chevron_right,
                            color: AppColors.textSecondary),
                      ],
                    ),
                  ),
                ),
              ),
            );
          }),
        const SizedBox(height: 12),
        if (!widget.linkMode)
          OutlinedButton.icon(
            onPressed: _openRegister,
            icon: const Icon(Icons.person_add),
            label: Text(tr('register_new_player')),
            style: OutlinedButton.styleFrom(
                minimumSize: const Size.fromHeight(48)),
          )
        else
          Text(
            tr('no_match_link_hint'),
            style: const TextStyle(
                fontSize: 11, color: AppColors.textSecondary),
          ),
      ],
    );
  }

  Widget _buildConfirmStep(BuildContext context) {
    final identity = _selected!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            color: AppColors.surface,
            border: Border.all(color: AppColors.divider),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text('#${_numberLabel(identity.playerNumber)}',
                      style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                          color: AppColors.accentGreen)),
                  const Spacer(),
                  const Icon(Icons.verified_user_outlined,
                      color: AppColors.accentGreen),
                ],
              ),
              const SizedBox(height: 6),
              Text(identity.displayName.isEmpty
                  ? '—'
                  : identity.displayName,
                  style: const TextStyle(
                      fontWeight: FontWeight.bold, fontSize: 16)),
              if (identity.firstName.isNotEmpty ||
                  identity.lastName.isNotEmpty)
                Text(
                  [identity.firstName, identity.lastName]
                      .where((x) => x.isNotEmpty)
                      .join(' '),
                  style: const TextStyle(
                      fontSize: 12, color: AppColors.textSecondary),
                ),
              if (identity.idNumber != null &&
                  identity.idNumber!.trim().isNotEmpty)
                Text(
                  '${tr('id_number')}: ${identity.idNumber!.trim()}',
                  style: const TextStyle(
                      fontSize: 11, color: AppColors.textSecondary),
                ),
              if (identity.hasSpecimen)
                Text(
                  tr('identity_specimen_on_file'),
                  style: const TextStyle(
                      fontSize: 11, color: AppColors.accentGreen),
                ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        if (!widget.linkMode)
          Text(
            tr('seat_no_money_note'),
            style: const TextStyle(
                fontSize: 11, color: AppColors.textSecondary),
          ),
        const SizedBox(height: 16),
        ElevatedButton.icon(
          onPressed: _seating ? null : () => _confirmAction(context),
          icon: Icon(widget.linkMode
              ? Icons.link
              : Icons.event_seat),
          label: Text(widget.linkMode
              ? tr('link_to_existing_player')
              : tr('seat_player')),
          style: ElevatedButton.styleFrom(
              minimumSize: const Size.fromHeight(52)),
        ),
        const SizedBox(height: 8),
        OutlinedButton(
          onPressed: _backToSelect,
          child: Text(tr('change_player')),
        ),
      ],
    );
  }

  Widget _buildRegisterStep(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _displayNameCtrl,
          autofocus: true,
          decoration: InputDecoration(
            labelText: tr('name'),
            hintText: tr('display_name'),
          ),
        ),
        const SizedBox(height: 10),
        TextField(
          controller: _firstNameCtrl,
          decoration: InputDecoration(labelText: tr('first_name_optional')),
        ),
        const SizedBox(height: 10),
        TextField(
          controller: _lastNameCtrl,
          decoration: InputDecoration(labelText: tr('last_name_optional')),
        ),
        const SizedBox(height: 10),
        TextField(
          controller: _idNumberCtrl,
          decoration: InputDecoration(labelText: tr('id_number_optional')),
        ),
        const SizedBox(height: 12),
        Text(
          tr('register_new_only_note'),
          style: const TextStyle(
              fontSize: 11, color: AppColors.textSecondary),
        ),
        const SizedBox(height: 16),
        ElevatedButton(
          onPressed: _creating
              ? null
              : () => _saveIdentity(context),
          child: Text(_creating
              ? tr('saving')
              : tr('register_new_identity')),
          style: ElevatedButton.styleFrom(
              minimumSize: const Size.fromHeight(52)),
        ),
        OutlinedButton(
          onPressed: _creating ? null : _backToSelect,
          child: Text(tr('cancel')),
        ),
      ],
    );
  }
}
