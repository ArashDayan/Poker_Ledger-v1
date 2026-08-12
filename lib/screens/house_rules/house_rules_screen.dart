import 'package:flutter/material.dart';
import '../../core/localization/app_localizations.dart';
import 'package:provider/provider.dart';
import '../../core/house_rules.dart';
import '../../core/rake_calculator.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/currency_formatter.dart';
import '../../models/enums.dart';
import '../../models/session.dart';
import '../../providers/session_provider.dart';
import '../../widgets/quick_rake_slots_editor.dart';

/// Always-accessible view/edit of the current session's house rules —
/// entry fee, buy-in cap, rebuy levels, and rake configuration. This is
/// also where "View Rule" links from house-rule warnings land, so a
/// banker always understands exactly what triggered a warning and can
/// adjust it on the spot if the table's rules are actually different
/// tonight.
class HouseRulesScreen extends StatefulWidget {
  const HouseRulesScreen({super.key});

  @override
  State<HouseRulesScreen> createState() => _HouseRulesScreenState();
}

class _HouseRulesScreenState extends State<HouseRulesScreen> {
  bool _editing = false;
  late final TextEditingController _entryFee;
  late final TextEditingController _buyInCap;
  late final TextEditingController _rebuyLastLevel;
  late RakeMode _rakeMode;
  late final TextEditingController _rakePercentage;
  late final TextEditingController _fixedRake;
  late List<RakeTierRule> _tiers;
  late final TextEditingController _tieredMaxRake;
  late final TextEditingController _tieredCutoff;
  late List<TextEditingController> _quickRakeSlots;
  late bool _rebuyLevelEnforcementEnabled;
  late bool _rebateEnabled;
  late final TextEditingController _rebateMin;
  late final TextEditingController _rebatePercent;

  @override
  void initState() {
    super.initState();
    final s = context.read<SessionProvider>().current;
    _entryFee = TextEditingController(text: s?.defaultBuyInAmount?.toStringAsFixed(0) ?? '');
    _buyInCap = TextEditingController(text: s?.buyInCapAmount?.toStringAsFixed(0) ?? '');
    _rebuyLastLevel =
        TextEditingController(text: (s?.rebuyLastLevel ?? HouseRules.lastRebuyLevel).toString());
    _rakeMode = s?.rakeMode ?? RakeMode.percentage;
    _rakePercentage = TextEditingController(text: (s?.rakePercentage ?? 0).toString());
    _fixedRake = TextEditingController(text: s?.fixedRakeAmount?.toStringAsFixed(0) ?? '');
    _tiers = s?.tieredRakeRules == null
        ? [...RakeCalculator.defaultTiers]
        : s!.tieredRakeRules!.map(RakeTierRule.fromMap).toList();
    _tieredMaxRake =
        TextEditingController(text: (s?.tieredMaxRake ?? RakeCalculator.defaultMaxRake).toStringAsFixed(0));
    _tieredCutoff = TextEditingController(
        text: (s?.tieredNoRakeAtOrAbove ?? RakeCalculator.defaultNoRakeAtOrAbove).toStringAsFixed(0));
    _quickRakeSlots = QuickRakeSlotsEditor.controllersFrom(s?.quickRakeAmounts);
    _rebuyLevelEnforcementEnabled = s?.rebuyLevelEnforcementEnabled ?? true;
    _rebateEnabled = s?.rebateEnabled ?? false;
    _rebateMin = TextEditingController(
        text: (s?.rebateMinLoss ?? 1000).toStringAsFixed(0));
    _rebatePercent = TextEditingController(
        text: (s?.rebatePercent ?? 10).toStringAsFixed(0));
  }

  Future<void> _save() async {
    final provider = context.read<SessionProvider>();
    await provider.updateHouseRules(
      buyInCapAmount: double.tryParse(_buyInCap.text.replaceAll(',', '')),
      defaultBuyInAmount: double.tryParse(_entryFee.text.replaceAll(',', '')),
      rebuyLastLevel: int.tryParse(_rebuyLastLevel.text) ?? HouseRules.lastRebuyLevel,
      rakeMode: _rakeMode,
      rakePercentage: double.tryParse(_rakePercentage.text) ?? 0,
      fixedRakeAmount: double.tryParse(_fixedRake.text.replaceAll(',', '')),
      tieredRakeRules: _tiers.map((t) => t.toMap()).toList(),
      tieredMaxRake: double.tryParse(_tieredMaxRake.text.replaceAll(',', '')),
      tieredNoRakeAtOrAbove: double.tryParse(_tieredCutoff.text.replaceAll(',', '')),
      quickRakeAmounts: QuickRakeSlotsEditor.valuesFrom(_quickRakeSlots),
      rebuyLevelEnforcementEnabled: _rebuyLevelEnforcementEnabled,
      rebateEnabled: _rebateEnabled,
      rebateMinLoss: double.tryParse(_rebateMin.text.replaceAll(',', '')),
      rebatePercent: double.tryParse(_rebatePercent.text.replaceAll(',', '')),
    );
    if (!mounted) return;
    setState(() => _editing = false);
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(tr('house_rules_updated'))));
  }

  @override
  Widget build(BuildContext context) {
    final session = context.watch<SessionProvider>().current;
    if (session == null) {
      return Scaffold(
        appBar: AppBar(title: Text(tr('house_rules'))),
        body: Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text(tr('open_session_for_rules'),
                textAlign: TextAlign.center, style: TextStyle(color: AppColors.textSecondary)),
          ),
        ),
      );
    }
    final fmt = CurrencyFormatter(session.currency);

    return Scaffold(
      appBar: AppBar(
        title: Text(tr('house_rules')),
        actions: [
          IconButton(
            icon: Icon(_editing ? Icons.close : Icons.edit_outlined),
            onPressed: () => setState(() => _editing = !_editing),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _sectionTitle('Buy-in & Rebuys'),
          _editing
              ? _editableRow('Default Entry Fee', _entryFee, hint: 'blank = no pre-fill', isCurrency: true)
              : _readRow('Default Entry Fee',
                  session.defaultBuyInAmount == null ? 'Not set' : fmt.format(session.defaultBuyInAmount!)),
          _editing
              ? _editableRow('Buy-in Cap per Player', _buyInCap, hint: 'blank = no cap', isCurrency: true)
              : _readRow('Buy-in Cap per Player',
                  session.buyInCapAmount == null ? 'No cap' : fmt.format(session.buyInCapAmount!)),
          if (_editing)
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(tr('enforce_rebuy_levels')),
              subtitle: const Text(
                "Off = rebuys are always allowed, no level checks. Use this for "
                "tables that don't run formal blind levels.",
                style: TextStyle(fontSize: 11),
              ),
              value: _rebuyLevelEnforcementEnabled,
              onChanged: (v) => setState(() => _rebuyLevelEnforcementEnabled = v),
            )
          else
            _readRow('Rebuy Level Enforcement',
                _rebuyLevelEnforcementEnabled ? 'On' : 'Off — rebuys always allowed'),
          if (_rebuyLevelEnforcementEnabled) ...[
            _editing
                ? _editableRow('Rebuys offered through level', _rebuyLastLevel, isInt: true)
                : _readRow('Rebuys offered through level', 'Level ${session.rebuyLastLevel}'),
            const SizedBox(height: 4),
            Text(
              tr('rebuy_unlock_note'),
              style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
            ),
          ],
          const SizedBox(height: 24),
          _sectionTitle('Rake'),
          if (_editing) ...[
            SegmentedButton<RakeMode>(
              segments: [
                ButtonSegment(value: RakeMode.percentage, label: Text('%')),
                ButtonSegment(value: RakeMode.fixed, label: Text(tr('fixed'))),
                ButtonSegment(value: RakeMode.tiered, label: Text(tr('tiered'))),
              ],
              selected: {_rakeMode},
              onSelectionChanged: (s) => setState(() => _rakeMode = s.first),
            ),
            const SizedBox(height: 12),
            if (_rakeMode == RakeMode.percentage)
              _editableRow('Rake %', _rakePercentage),
            if (_rakeMode == RakeMode.fixed)
              _editableRow('Fixed Rake Amount', _fixedRake, isCurrency: true),
            if (_rakeMode == RakeMode.tiered) _buildTieredEditor(),
            const SizedBox(height: 20),
            Text(tr('quick_rake_buttons'),
                style: TextStyle(color: AppColors.textSecondary)),
            const SizedBox(height: 4),
            Text(tr('five_slots_note'),
                style: TextStyle(fontSize: 11, color: AppColors.textSecondary)),
            const SizedBox(height: 10),
            QuickRakeSlotsEditor(
              controllers: _quickRakeSlots,
              formatter: fmt,
              onChanged: () => setState(() {}),
            ),
          ] else ...[
            _buildRakeReadOnly(session, fmt),
            const SizedBox(height: 16),
            Text(tr('quick_rake_buttons'),
                style: TextStyle(color: AppColors.textSecondary, fontSize: 12)),
            const SizedBox(height: 8),
            QuickRakePreview(
              amounts: QuickRakeSlotsEditor.valuesFrom(_quickRakeSlots),
              formatter: fmt,
            ),
          ],
          if (session.mode == SessionMode.cashGame) ...[
            const SizedBox(height: 24),
            _sectionTitle(tr('rebate_title')),
            Text(tr('rebate_hint'),
                style: const TextStyle(
                    fontSize: 12, color: AppColors.textSecondary)),
            const SizedBox(height: 8),
            if (_editing) ...[
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(tr('rebate_enabled')),
                value: _rebateEnabled,
                onChanged: (v) => setState(() => _rebateEnabled = v),
              ),
              if (_rebateEnabled) ...[
                _editableRow(tr('rebate_min_loss'), _rebateMin, isCurrency: true),
                _editableRow(tr('rebate_percent'), _rebatePercent),
              ],
            ] else ...[
              _readRow(tr('rebate_enabled'),
                  _rebateEnabled ? tr('active') : tr('closed')),
              if (_rebateEnabled) ...[
                _readRow(tr('rebate_min_loss'),
                    fmt.format(session.rebateMinLoss ?? 0)),
                _readRow(tr('rebate_percent'),
                    '${session.rebatePercent ?? 0}%'),
              ],
            ],
          ],
          const SizedBox(height: 24),
          if (_editing)
            ElevatedButton(onPressed: _save, child: Text(tr('save_house_rules'))),
        ],
      ),
    );
  }

  Widget _buildRakeReadOnly(PokerSession session, CurrencyFormatter fmt) {
    switch (_rakeMode) {
      case RakeMode.percentage:
        return _readRow('Rake', '${session.rakePercentage}% of pot');
      case RakeMode.fixed:
        return _readRow('Rake',
            session.fixedRakeAmount == null ? 'Not set' : '${fmt.format(session.fixedRakeAmount!)} flat');
      case RakeMode.tiered:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final tier in _tiers)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Text('${tr('under')} ${fmt.format(tier.upperBound)}  →  ${fmt.format(tier.rake)}',
                    style: const TextStyle(fontSize: 13)),
              ),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Text(
                  'At/above ${fmt.format(_tiers.isEmpty ? 0 : _tiers.last.upperBound)}  →  '
                  '${fmt.format(double.tryParse(_tieredMaxRake.text) ?? 0)} (max)',
                  style: const TextStyle(fontSize: 13)),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Text(
                  'At/above ${fmt.format(double.tryParse(_tieredCutoff.text) ?? 0)}  →  no rake',
                  style: const TextStyle(fontSize: 13, color: AppColors.gold)),
            ),
          ],
        );
    }
  }

  Widget _buildTieredEditor() {
    final currency = context.read<SessionProvider>().current!.currency;
    final tierFmt = CurrencyFormatter(currency);
    final prefixText = tierFmt.symbol == '\$' ? '\$ ' : null;
    final suffixText = tierFmt.symbol == '\$' ? null : tierFmt.symbol;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (int i = 0; i < _tiers.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              children: [
                Expanded(
                  child: TextFormField(
                    initialValue: _tiers[i].upperBound.toStringAsFixed(0),
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                        labelText: tr('under'), prefixText: prefixText, suffixText: suffixText),
                    onChanged: (v) => _tiers[i] = RakeTierRule(
                        double.tryParse(v.replaceAll(',', '')) ?? _tiers[i].upperBound,
                        _tiers[i].rake),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextFormField(
                    initialValue: _tiers[i].rake.toStringAsFixed(0),
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                        labelText: tr('rake'), prefixText: prefixText, suffixText: suffixText),
                    onChanged: (v) => _tiers[i] = RakeTierRule(_tiers[i].upperBound,
                        double.tryParse(v.replaceAll(',', '')) ?? _tiers[i].rake),
                  ),
                ),
              ],
            ),
          ),
        _editableRow('Max rake (above highest tier)', _tieredMaxRake, isCurrency: true),
        _editableRow('No rake at/above', _tieredCutoff, isCurrency: true),
      ],
    );
  }

  Widget _sectionTitle(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Text(text, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
      );

  Widget _readRow(String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label, style: const TextStyle(color: AppColors.textSecondary)),
            Text(value, style: const TextStyle(fontWeight: FontWeight.bold)),
          ],
        ),
      );

  Widget _editableRow(String label, TextEditingController ctrl,
      {String? hint, bool isInt = false, bool isCurrency = false}) {
    String? prefixText;
    String? suffixText;
    if (isCurrency) {
      final currency = context.read<SessionProvider>().current!.currency;
      final fmt = CurrencyFormatter(currency);
      prefixText = fmt.symbol == '\$' ? '\$ ' : null;
      suffixText = fmt.symbol == '\$' ? null : fmt.symbol;
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextFormField(
        controller: ctrl,
        keyboardType: isInt ? TextInputType.number : const TextInputType.numberWithOptions(decimal: true),
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          prefixText: prefixText,
          suffixText: suffixText,
        ),
      ),
    );
  }
}
