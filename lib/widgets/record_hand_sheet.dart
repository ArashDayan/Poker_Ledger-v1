import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/localization/app_localizations.dart';
import '../core/theme/app_theme.dart';
import '../core/utils/currency_formatter.dart';
import '../models/hand.dart';
import '../models/player.dart';
import '../providers/session_provider.dart';
import '../services/hand_service.dart';
import '../services/table_service.dart';
import 'dual_verification_sheet.dart';
import 'signature_pad.dart';

/// Record-after-the-fact sheet for a completed pot.
Future<Hand?> showRecordHandSheet(
  BuildContext context, {
  required String tableId,
}) {
  return showModalBottomSheet<Hand>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _RecordHandSheet(tableId: tableId),
  );
}

class _RecordHandSheet extends StatefulWidget {
  final String tableId;
  const _RecordHandSheet({required this.tableId});

  @override
  State<_RecordHandSheet> createState() => _RecordHandSheetState();
}

class _RecordHandSheetState extends State<_RecordHandSheet> {
  HandKind _kind = HandKind.poker;
  final Map<String, TextEditingController> _changes = {};
  final Map<String, bool> _included = {};
  final _rakeCtrl = TextEditingController();
  final _houseCtrl = TextEditingController();
  final _noteCtrl = TextEditingController();
  String _signature = '';
  bool _saving = false;

  @override
  void dispose() {
    for (final c in _changes.values) {
      c.dispose();
    }
    _rakeCtrl.dispose();
    _houseCtrl.dispose();
    _noteCtrl.dispose();
    super.dispose();
  }

  List<Player> _seated(SessionProvider provider) {
    final session = provider.current;
    if (session == null) return const [];
    return TableService.playersAt(session, widget.tableId);
  }

  void _ensureControllers(List<Player> seated) {
    for (final p in seated) {
      _changes.putIfAbsent(p.id, () => TextEditingController(text: '0'));
      _included.putIfAbsent(p.id, () => true);
    }
  }

  double _parse(TextEditingController ctrl) {
    final raw = ctrl.text.replaceAll(',', '').trim();
    if (raw.isEmpty) return 0;
    return double.tryParse(raw) ?? double.nan;
  }

  _Preview _preview(List<Player> seated) {
    var sum = 0.0;
    var pot = 0.0;
    final drafts = <HandResultDraft>[];
    var valid = true;
    for (final p in seated) {
      if (_included[p.id] != true) continue;
      final change = _parse(_changes[p.id]!);
      if (change.isNaN) {
        valid = false;
        continue;
      }
      sum += change;
      if (change < 0) pot += -change;
      drafts.add(HandResultDraft(seatPlayerId: p.id, chipChange: change));
    }
    final rake = _kind == HandKind.poker ? _parse(_rakeCtrl) : 0.0;
    var house = _kind == HandKind.houseGame ? _parse(_houseCtrl) : 0.0;
    if (house.isNaN || rake.isNaN) valid = false;
    if (_kind == HandKind.houseGame &&
        !house.isNaN &&
        house == 0 &&
        pot > 0) {
      // Convenience: a single house-game loss fills house win.
      house = pot;
    }
    final conservation = valid ? sum + rake + house : double.nan;
    return _Preview(
      drafts: drafts,
      pot: pot,
      rake: rake.isNaN ? 0 : rake,
      houseWin: house.isNaN ? 0 : house,
      conserved: valid && conservation.abs() < 0.005,
      valid: valid && drafts.isNotEmpty,
    );
  }

  Future<void> _save(List<Player> seated) async {
    final preview = _preview(seated);
    if (!preview.valid || !preview.conserved) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr('hand_conservation_error'))),
      );
      return;
    }
    if (_kind == HandKind.houseGame &&
        preview.houseWin > 0 &&
        _signature.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr('hand_signature_hint'))),
      );
      return;
    }

    // J8: a sensitive hand (rake and/or house win at/above the configured
    // threshold) requires a second authorisation before any ledger or chip
    // write. The captured identity + signature is forwarded to both money
    // legs; each service-level transaction applies the threshold itself.
    final provider = context.read<SessionProvider>();
    final session = provider.current;
    if (session == null) return;
    final sensitiveAmount =
        preview.rake > preview.houseWin ? preview.rake : preview.houseWin;
    final secondVerifier = await collectSecondVerifierIfRequired(
      context,
      amount: sensitiveAmount,
      currency: session.currency,
      operationLabel: tr('record_hand'),
    );
    if (secondVerifier == null) return;

    setState(() => _saving = true);
    try {
      final hand = await provider.recordHand(
            tableId: widget.tableId,
            kind: _kind,
            drafts: preview.drafts,
            potAmount: preview.pot,
            rakeAmount: preview.rake,
            houseWinAmount: preview.houseWin,
            note: _noteCtrl.text.trim().isEmpty ? null : _noteCtrl.text.trim(),
            hostSignatureBase64:
                preview.houseWin > 0 ? _signature : null,
            secondVerifierName:
                secondVerifier.isRequired ? secondVerifier.name : null,
            secondVerifierSignature:
                secondVerifier.isRequired ? secondVerifier.signature : null,
          );
      if (!mounted) return;
      Navigator.pop(context, hand);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<SessionProvider>();
    final session = provider.current;
    if (session == null) return const SizedBox.shrink();
    final seated = _seated(provider);
    _ensureControllers(seated);
    final fmt = CurrencyFormatter(session.currency);
    final preview = _preview(seated);

    return DraggableScrollableSheet(
      initialChildSize: 0.9,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      expand: false,
      builder: (context, scroll) => Container(
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
                    child: Text(tr('record_hand'),
                        style: const TextStyle(
                            fontSize: 17, fontWeight: FontWeight.bold)),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, size: 20),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                controller: scroll,
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
                children: [
                  SegmentedButton<HandKind>(
                    segments: [
                      ButtonSegment(
                        value: HandKind.poker,
                        label: Text(tr('hand_kind_poker')),
                      ),
                      ButtonSegment(
                        value: HandKind.houseGame,
                        label: Text(tr('hand_kind_house')),
                      ),
                    ],
                    selected: {_kind},
                    onSelectionChanged: _saving
                        ? null
                        : (s) => setState(() {
                              _kind = s.first;
                              if (_kind == HandKind.poker) {
                                _houseCtrl.text = '';
                              } else {
                                _rakeCtrl.text = '';
                              }
                            }),
                  ),
                  const SizedBox(height: 14),
                  if (seated.isEmpty)
                    Text(tr('add_player_first'),
                        style: const TextStyle(color: AppColors.textSecondary))
                  else
                    for (final p in seated)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: Row(
                          children: [
                            Checkbox(
                              value: _included[p.id] ?? true,
                              onChanged: _saving
                                  ? null
                                  : (v) => setState(
                                      () => _included[p.id] = v ?? false),
                            ),
                            Expanded(
                              child: Text(
                                '${tr('seat')} ${p.seatNumber} · ${p.name}',
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            SizedBox(
                              width: 110,
                              child: TextField(
                                controller: _changes[p.id],
                                enabled: !_saving && (_included[p.id] ?? true),
                                keyboardType: const TextInputType
                                    .numberWithOptions(
                                    decimal: true, signed: true),
                                textAlign: TextAlign.center,
                                decoration: InputDecoration(
                                  isDense: true,
                                  labelText: tr('hand_chip_change'),
                                ),
                                onChanged: (_) => setState(() {}),
                              ),
                            ),
                          ],
                        ),
                      ),
                  const SizedBox(height: 8),
                  if (_kind == HandKind.poker)
                    TextField(
                      controller: _rakeCtrl,
                      enabled: !_saving,
                      keyboardType:
                          const TextInputType.numberWithOptions(decimal: true),
                      decoration: InputDecoration(labelText: tr('hand_rake')),
                      onChanged: (_) => setState(() {}),
                    )
                  else
                    TextField(
                      controller: _houseCtrl,
                      enabled: !_saving,
                      keyboardType:
                          const TextInputType.numberWithOptions(decimal: true),
                      decoration: InputDecoration(
                        labelText: tr('hand_house_win'),
                        helperText: preview.pot > 0 && _houseCtrl.text.isEmpty
                            ? fmt.format(preview.pot)
                            : null,
                      ),
                      onChanged: (_) => setState(() {}),
                    ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: _noteCtrl,
                    enabled: !_saving,
                    decoration: InputDecoration(labelText: tr('note_optional')),
                  ),
                  if (_kind == HandKind.houseGame && preview.houseWin > 0) ...[
                    const SizedBox(height: 14),
                    Text(tr('hand_signature_hint'),
                        style: const TextStyle(
                            fontSize: 12, color: AppColors.textSecondary)),
                    const SizedBox(height: 8),
                    SignaturePad(
                        onChanged: (s) => setState(() => _signature = s)),
                  ],
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.fromLTRB(20, 10, 20, 20),
              child: Column(
                children: [
                  Row(
                    children: [
                      _stat(tr('hand_pot'), fmt.format(preview.pot)),
                      _stat(tr('hand_rake'), fmt.format(preview.rake),
                          color: AppColors.gold),
                      _stat(tr('hand_house_win'), fmt.format(preview.houseWin),
                          color: AppColors.gold),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    preview.conserved
                        ? tr('hand_conservation_ok')
                        : tr('hand_conservation_error'),
                    style: TextStyle(
                      fontSize: 11,
                      color: preview.conserved
                          ? AppColors.accentGreen
                          : AppColors.danger,
                    ),
                  ),
                  const SizedBox(height: 10),
                  SizedBox(
                    width: double.infinity,
                    height: 46,
                    child: ElevatedButton(
                      onPressed: _saving || !preview.valid || !preview.conserved
                          ? null
                          : () => _save(seated),
                      child: _saving
                          ? const SizedBox(
                              height: 20,
                              width: 20,
                              child: CircularProgressIndicator(strokeWidth: 2))
                          : Text(tr('confirm')),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _stat(String label, String value, {Color? color}) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: const TextStyle(
                  fontSize: 10, color: AppColors.textSecondary)),
          Text(value,
              style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: color ?? AppColors.textPrimary)),
        ],
      ),
    );
  }
}

class _Preview {
  final List<HandResultDraft> drafts;
  final double pot;
  final double rake;
  final double houseWin;
  final bool conserved;
  final bool valid;
  const _Preview({
    required this.drafts,
    required this.pot,
    required this.rake,
    required this.houseWin,
    required this.conserved,
    required this.valid,
  });
}
