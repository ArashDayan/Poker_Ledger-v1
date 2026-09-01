import 'package:flutter/material.dart';
import '../../core/localization/app_localizations.dart';
import 'package:provider/provider.dart';
import '../../core/house_rules.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/currency_formatter.dart';
import '../../core/utils/validators.dart';
import '../../models/enums.dart';
import '../../providers/session_provider.dart';
import '../../providers/settings_provider.dart';
import '../../services/tournament_service.dart';
import '../../widgets/quick_rake_slots_editor.dart';
import '../shell/open_floor_session.dart';

class NewSessionScreen extends StatefulWidget {
  const NewSessionScreen({super.key});

  @override
  State<NewSessionScreen> createState() => _NewSessionScreenState();
}

class _NewSessionScreenState extends State<NewSessionScreen> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController(text: 'Friday Night Game');
  final _location = TextEditingController();
  final _smallBlind = TextEditingController(text: '1');
  final _bigBlind = TextEditingController(text: '2');
  final _rake = TextEditingController(text: '5');
  final _tableNumber = TextEditingController(text: '1');
  final _hostName = TextEditingController();
  final _buyInCap = TextEditingController();
  final _defaultEntryFee = TextEditingController();
  final _fixedRake = TextEditingController();
  late List<TextEditingController> _quickRakeSlots;
  SessionMode _mode = SessionMode.cashGame;
  final _tBuyIn = TextEditingController();
  final _tFee = TextEditingController();
  final _tRebuy = TextEditingController();
  final _tStack = TextEditingController(text: '10000');
  final _tLevelMinutes = TextEditingController(text: '20');
  DateTime _dateTime = DateTime.now();

  /// Banker-defined end of the Session working period (Discount
  /// deadline). Optional; any duration. Null = no planned end.
  DateTime? _plannedEndAt;
  AppCurrency _currency = AppCurrency.usd;
  RakeMode _rakeMode = RakeMode.percentage;
  bool _showHouseRules = false;
  bool _rebateEnabled = false;
  final _rebateMin = TextEditingController(text: '1000');
  final _rebatePercent = TextEditingController(text: '10');

  @override
  void initState() {
    super.initState();
    final settings = context.read<SettingsProvider>();
    _currency = settings.defaultCurrency;
    _quickRakeSlots = QuickRakeSlotsEditor.controllersFrom(
      _currency == AppCurrency.usd
          ? HouseRules.defaultQuickRakeAmountsUsd
          : HouseRules.defaultQuickRakeAmounts,
    );
    _applyCurrencyDefaults();
  }

  /// Pre-fills entry fee / buy-in cap from the house rule defaults when
  /// switching to Toman (the currency these rules were written for), and
  /// clears them for USD. Always editable/clearable afterwards.
  void _applyCurrencyDefaults() {
    final rakeDefaults = _currency == AppCurrency.toman
        ? HouseRules.defaultQuickRakeAmounts
        : HouseRules.defaultQuickRakeAmountsUsd;
    if (_currency == AppCurrency.toman) {
      _defaultEntryFee.text = HouseRules.defaultEntryFeeToman.toStringAsFixed(0);
      _buyInCap.text = HouseRules.defaultBuyInCapToman.toStringAsFixed(0);
    } else {
      _defaultEntryFee.clear();
      _buyInCap.clear();
    }
    // Re-seed the five quick-rake slots to a ladder that matches the
    // chosen currency — Toman-scale numbers in a USD session are useless.
    for (var i = 0; i < _quickRakeSlots.length; i++) {
      _quickRakeSlots[i].text =
          i < rakeDefaults.length ? rakeDefaults[i].toStringAsFixed(0) : '';
    }
  }

  Future<void> _pickDateTime() async {
    final date = await showDatePicker(
      context: context,
      initialDate: _dateTime,
      firstDate: DateTime.now().subtract(const Duration(days: 1)),
      lastDate: DateTime.now().add(const Duration(days: 365)),
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(_dateTime),
    );
    if (time == null) return;
    setState(() {
      _dateTime = DateTime(date.year, date.month, date.day, time.hour, time.minute);
      // A start moved past the previously chosen period end would leave
      // an inverted period. Drop it instead of storing a contradiction.
      if (_plannedEndAt != null && !_plannedEndAt!.isAfter(_dateTime)) {
        _plannedEndAt = null;
      }
    });
  }

  Future<void> _pickPlannedEnd() async {
    final date = await showDatePicker(
      context: context,
      initialDate: _plannedEndAt ?? _dateTime.add(const Duration(hours: 12)),
      firstDate: _dateTime,
      lastDate: _dateTime.add(const Duration(days: 365)),
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(
          _plannedEndAt ?? _dateTime.add(const Duration(hours: 12))),
    );
    if (time == null) return;
    final picked =
        DateTime(date.year, date.month, date.day, time.hour, time.minute);
    if (!picked.isAfter(_dateTime)) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr('session_period_invalid'))),
      );
      return;
    }
    setState(() => _plannedEndAt = picked);
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    if (_mode == SessionMode.cashGame && _rebateEnabled) {
      final min = double.tryParse(_rebateMin.text.replaceAll(',', '')) ?? 0;
      final pct = double.tryParse(_rebatePercent.text.replaceAll(',', '')) ?? 0;
      if (min <= 0 || pct <= 0) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(tr('discount_config_incomplete'))),
        );
        return;
      }
    }
    final provider = context.read<SessionProvider>();
    final session = await provider.createSession(
      name: _name.text.trim(),
      location: _location.text.trim(),
      dateTime: _dateTime,
      smallBlind: double.parse(_smallBlind.text),
      bigBlind: double.parse(_bigBlind.text),
      rakePercentage: double.tryParse(_rake.text) ?? 0,
      tableNumber: _tableNumber.text.trim(),
      currency: _currency,
      hostName: _hostName.text.trim().isEmpty ? null : _hostName.text.trim(),
      buyInCapAmount: double.tryParse(_buyInCap.text.replaceAll(',', '')),
      defaultBuyInAmount: double.tryParse(_defaultEntryFee.text.replaceAll(',', '')),
      rakeMode: _rakeMode,
      fixedRakeAmount: double.tryParse(_fixedRake.text.replaceAll(',', '')),
      quickRakeAmounts: QuickRakeSlotsEditor.valuesFrom(_quickRakeSlots),
      mode: _mode,
      // A tournament starts with a generated structure derived from the
      // chosen big blind and level length; the banker can then customise
      // every level from the Blind Structure screen.
      blindLevels: _mode == SessionMode.tournament
          ? _generatedStructure()
          : null,
      tournamentBuyIn: _mode == SessionMode.tournament
          ? double.tryParse(_tBuyIn.text.replaceAll(',', ''))
          : null,
      tournamentFee: _mode == SessionMode.tournament
          ? double.tryParse(_tFee.text.replaceAll(',', ''))
          : null,
      tournamentRebuy: _mode == SessionMode.tournament
          ? double.tryParse(_tRebuy.text.replaceAll(',', ''))
          : null,
      startingStack: _mode == SessionMode.tournament
          ? int.tryParse(_tStack.text.replaceAll(',', ''))
          : null,
      rebateEnabled: _mode == SessionMode.cashGame && _rebateEnabled,
      rebateMinLoss: _mode == SessionMode.cashGame
          ? double.tryParse(_rebateMin.text.replaceAll(',', ''))
          : null,
      rebatePercent: _mode == SessionMode.cashGame
          ? double.tryParse(_rebatePercent.text.replaceAll(',', ''))
          : null,
      plannedEndAt:
          _mode == SessionMode.cashGame && _rebateEnabled ? _plannedEndAt : null,
    );
    if (!mounted) return;
    // ICR-02: a live session opens on the Floor (the session is loaded
    // and the shell switches to it); the five-tab console is no longer
    // the product-level destination for live play.
    openFloorSession(context, session);
  }

  /// Builds an amount field's decoration with the correct currency
  /// Builds the opening blind structure for a new tournament from the
  /// big blind and level length entered on this form.
  List<BlindLevel> _generatedStructure() {
    final minutes = int.tryParse(_tLevelMinutes.text) ?? 20;
    final startingBb = double.tryParse(_bigBlind.text) ?? 50;
    return TournamentService.defaultStructure(startingBigBlind: startingBb)
        .map((l) => l.isBreak ? l : l.copyWith(minutes: minutes))
        .toList();
  }

  /// symbol for whichever currency is currently selected in this form
  /// (USD as a prefix, Toman as a suffix — matches the convention used
  /// everywhere else amounts are entered in the app).
  Widget _discountSetupCard() {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
      decoration: BoxDecoration(
        color: AppColors.surfaceElevated,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: _rebateEnabled
              ? AppColors.gold.withValues(alpha: 0.55)
              : AppColors.divider,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(Icons.percent, size: 18, color: AppColors.gold),
              const SizedBox(width: 8),
              Expanded(
                child: Text(tr('rebate_title'),
                    style: const TextStyle(
                        fontWeight: FontWeight.bold, fontSize: 15)),
              ),
              Text(
                _rebateEnabled ? tr('discount_on') : tr('discount_off'),
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  color: _rebateEnabled
                      ? AppColors.gold
                      : AppColors.textSecondary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(tr('discount_setup_hint'),
              style: const TextStyle(
                  fontSize: 11.5, color: AppColors.textSecondary, height: 1.35)),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(tr('rebate_enabled')),
            subtitle: Text(
              _rebateEnabled
                  ? tr('discount_on_hint')
                  : tr('discount_off_hint'),
              style: const TextStyle(fontSize: 11),
            ),
            value: _rebateEnabled,
            onChanged: (v) => setState(() => _rebateEnabled = v),
          ),
          if (_rebateEnabled) ...[
            TextFormField(
              controller: _rebateMin,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: _moneyDecoration(tr('rebate_min_loss')),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _rebatePercent,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(labelText: tr('rebate_percent')),
            ),
            const SizedBox(height: 12),
            InkWell(
              onTap: _pickPlannedEnd,
              child: InputDecorator(
                decoration: InputDecoration(
                  labelText: tr('session_period_end'),
                  helperText: tr('session_period_hint'),
                  suffixIcon: _plannedEndAt == null
                      ? null
                      : IconButton(
                          icon: const Icon(Icons.clear),
                          onPressed: () =>
                              setState(() => _plannedEndAt = null),
                        ),
                ),
                child: Text(
                  _plannedEndAt == null
                      ? tr('session_period_not_set')
                      : '${_plannedEndAt!.toLocal()}'.substring(0, 16),
                  style: const TextStyle(color: AppColors.textPrimary),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  InputDecoration _moneyDecoration(String label, {String? hint}) {
    final fmt = CurrencyFormatter(_currency);
    return InputDecoration(
      labelText: label,
      hintText: hint,
      prefixText: fmt.symbol == '\$' ? '\$ ' : null,
      suffixText: fmt.symbol == '\$' ? null : fmt.symbol,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(tr('new_session'))),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            // Mode is chosen first and fixed for the session's life:
            // converting a running game between cash and tournament
            // would invalidate money already recorded under the other
            // set of rules.
            Text(tr('game_mode'),
                style: const TextStyle(color: AppColors.textSecondary)),
            const SizedBox(height: 8),
            SegmentedButton<SessionMode>(
              segments: [
                ButtonSegment(
                  value: SessionMode.cashGame,
                  icon: const Icon(Icons.payments_outlined, size: 17),
                  label: Text(tr('cash_game')),
                ),
                ButtonSegment(
                  value: SessionMode.tournament,
                  icon: const Icon(Icons.emoji_events_outlined, size: 17),
                  label: Text(tr('tournament')),
                ),
              ],
              selected: {_mode},
              onSelectionChanged: (v) => setState(() => _mode = v.first),
            ),
            const SizedBox(height: 18),
            TextFormField(
              controller: _name,
              decoration: InputDecoration(labelText: tr('session_name')),
              validator: (v) => Validators.requiredText(v, field: 'Session name'),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _location,
              decoration: InputDecoration(labelText: tr('location')),
              validator: (v) => Validators.requiredText(v, field: 'Location'),
            ),
            const SizedBox(height: 12),
            InkWell(
              onTap: _pickDateTime,
              child: InputDecorator(
                decoration: InputDecoration(labelText: tr('date_time')),
                child: Text(
                  '${_dateTime.toLocal()}'.substring(0, 16),
                  style: const TextStyle(color: AppColors.textPrimary),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextFormField(
                    controller: _smallBlind,
                    keyboardType: TextInputType.number,
                    decoration: _moneyDecoration('Small Blind'),
                    validator: Validators.positiveAmount,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextFormField(
                    controller: _bigBlind,
                    keyboardType: TextInputType.number,
                    decoration: _moneyDecoration('Big Blind'),
                    validator: Validators.positiveAmount,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                if (_rakeMode == RakeMode.percentage) ...[
                  Expanded(
                    child: TextFormField(
                      controller: _rake,
                      keyboardType: TextInputType.number,
                      decoration: InputDecoration(labelText: tr('rake_percent')),
                      validator: Validators.percentage,
                    ),
                  ),
                  const SizedBox(width: 12),
                ],
                Expanded(
                  child: TextFormField(
                    controller: _tableNumber,
                    decoration: InputDecoration(labelText: tr('table_number')),
                    validator: (v) => Validators.requiredText(v, field: 'Table number'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _hostName,
              decoration: InputDecoration(labelText: tr('host_name_optional')),
            ),
            const SizedBox(height: 12),
            Text(tr('currency'), style: TextStyle(color: AppColors.textSecondary)),
            const SizedBox(height: 8),
            SegmentedButton<AppCurrency>(
              segments: [
                ButtonSegment(value: AppCurrency.usd, label: Text('USD (\$)')),
                ButtonSegment(value: AppCurrency.toman, label: Text(tr('toman'))),
              ],
              selected: {_currency},
              onSelectionChanged: (s) => setState(() {
                _currency = s.first;
                _applyCurrencyDefaults();
              }),
            ),
            const SizedBox(height: 16),
            InkWell(
              onTap: () => setState(() => _showHouseRules = !_showHouseRules),
              child: Row(
                children: [
                  Icon(_showHouseRules ? Icons.expand_less : Icons.expand_more,
                      color: AppColors.accentGreen),
                  const SizedBox(width: 4),
                  Text(tr('house_rules_optional'),
                      style: TextStyle(color: AppColors.accentGreen, fontWeight: FontWeight.bold)),
                ],
              ),
            ),
            if (_showHouseRules) ...[
              const SizedBox(height: 12),
              TextFormField(
                controller: _defaultEntryFee,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: _moneyDecoration('Default Entry Fee (pre-fills buy-in amount)'),
                validator: (v) => (v == null || v.trim().isEmpty) ? null : Validators.nonNegativeAmount(v),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _buyInCap,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: _moneyDecoration('Buy-in Cap per Player (leave blank for no cap)'),
                validator: (v) => (v == null || v.trim().isEmpty) ? null : Validators.nonNegativeAmount(v),
              ),
              const SizedBox(height: 4),
              Text(
                'Rebuys are offered through level ${HouseRules.lastRebuyLevel} '
                '(one extra rebuy every two levels). This is enforced as a '
                'host warning, never a hard block.',
                style: const TextStyle(fontSize: 11, color: AppColors.textSecondary),
              ),
              const SizedBox(height: 16),
              Text(tr('rake_mode'), style: TextStyle(color: AppColors.textSecondary)),
              const SizedBox(height: 8),
              SegmentedButton<RakeMode>(
                segments: [
                  ButtonSegment(value: RakeMode.percentage, label: Text('%')),
                  ButtonSegment(value: RakeMode.fixed, label: Text(tr('fixed'))),
                  ButtonSegment(value: RakeMode.tiered, label: Text(tr('tiered'))),
                ],
                selected: {_rakeMode},
                onSelectionChanged: (s) => setState(() => _rakeMode = s.first),
              ),
              if (_rakeMode == RakeMode.fixed) ...[
                const SizedBox(height: 12),
                TextFormField(
                  controller: _fixedRake,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: _moneyDecoration('Fixed Rake Amount'),
                ),
              ],
              if (_rakeMode == RakeMode.tiered) ...[
                const SizedBox(height: 4),
                Text(
                  tr('tier_default_note'),
                  style: TextStyle(fontSize: 11, color: AppColors.textSecondary),
                ),
              ],
              const SizedBox(height: 22),
              Text(tr('quick_rake_buttons'),
                  style: TextStyle(color: AppColors.textSecondary)),
              const SizedBox(height: 4),
              Text(
                tr('define_five_note'),
                style: TextStyle(fontSize: 11, color: AppColors.textSecondary),
              ),
              const SizedBox(height: 12),
              QuickRakeSlotsEditor(
                controllers: _quickRakeSlots,
                formatter: CurrencyFormatter(_currency),
                onChanged: () => setState(() {}),
              ),
              const SizedBox(height: 10),
              QuickRakePreview(
                amounts: QuickRakeSlotsEditor.valuesFrom(_quickRakeSlots),
                formatter: CurrencyFormatter(_currency),
              ),
            ],
            if (_mode == SessionMode.tournament) ...[
              const SizedBox(height: 22),
              Row(
                children: [
                  const Icon(Icons.emoji_events_outlined,
                      size: 17, color: AppColors.gold),
                  const SizedBox(width: 6),
                  Text(tr('tournament_setup'),
                      style: const TextStyle(
                          color: AppColors.gold, fontWeight: FontWeight.bold)),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                tr('tournament_setup_hint'),
                style: const TextStyle(
                    fontSize: 11, color: AppColors.textSecondary),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _tBuyIn,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: _moneyDecoration(tr('tournament_buy_in')),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _tFee,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: _moneyDecoration(tr('house_fee_per_entry'),
                    hint: tr('blank_for_none')),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _tRebuy,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: _moneyDecoration(tr('rebuy_cost'),
                    hint: tr('blank_for_none')),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: TextFormField(
                      controller: _tStack,
                      keyboardType: TextInputType.number,
                      decoration:
                          InputDecoration(labelText: tr('starting_stack')),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextFormField(
                      controller: _tLevelMinutes,
                      keyboardType: TextInputType.number,
                      decoration:
                          InputDecoration(labelText: tr('level_length')),
                    ),
                  ),
                ],
              ),
            ],
            if (_mode == SessionMode.cashGame) ...[
              const SizedBox(height: 24),
              _discountSetupCard(),
            ],
            const SizedBox(height: 24),
            ElevatedButton(onPressed: _submit, child: Text(tr('create_session'))),
          ],
        ),
      ),
    );
  }
}
