import 'package:flutter/material.dart';
import '../core/house_rules.dart';
import '../core/localization/app_localizations.dart';
import '../core/theme/app_theme.dart';
import '../core/utils/currency_formatter.dart';

/// Editor for the banker's five one-tap rake buttons.
///
/// Deliberately a FIXED set of five slots rather than an add/remove list:
/// the banker knows their own table's rake ladder, the Collect Rake sheet
/// always shows the same five buttons in the same positions all night, and
/// muscle memory is worth more than flexibility here. A slot left blank is
/// simply not shown as a button — so a room that only ever takes three
/// amounts can leave two empty without the layout shifting around.
///
/// Used both when creating a session (New Session) and when editing a live
/// one (House Rules), so the two always look and behave identically.
class QuickRakeSlotsEditor extends StatelessWidget {
  /// Always exactly [HouseRules.quickRakeSlotCount] controllers.
  final List<TextEditingController> controllers;
  final CurrencyFormatter formatter;

  /// Called whenever a slot changes, so a parent can re-render a preview.
  final VoidCallback? onChanged;

  final bool enabled;

  const QuickRakeSlotsEditor({
    super.key,
    required this.controllers,
    required this.formatter,
    this.onChanged,
    this.enabled = true,
  });

  /// Builds the five controllers from whatever is stored on a session
  /// (which may historically have had more or fewer than five entries).
  static List<TextEditingController> controllersFrom(List<double>? amounts) {
    final source = amounts ?? HouseRules.defaultQuickRakeAmounts;
    return List.generate(HouseRules.quickRakeSlotCount, (i) {
      final v = i < source.length ? source[i] : null;
      return TextEditingController(
        text: (v == null || v <= 0) ? '' : v.toStringAsFixed(0),
      );
    });
  }

  /// Reads the controllers back into the list stored on the session.
  /// Blank/invalid slots are dropped; the result keeps slot order so the
  /// buttons stay where the banker put them.
  static List<double> valuesFrom(List<TextEditingController> controllers) {
    final out = <double>[];
    for (final c in controllers) {
      final v = double.tryParse(c.text.replaceAll(',', '').trim());
      if (v != null && v > 0) out.add(v);
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < controllers.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Row(
              children: [
                Container(
                  width: 30,
                  height: 30,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: AppColors.gold.withValues(alpha: 0.14),
                    shape: BoxShape.circle,
                    border: Border.all(color: AppColors.gold.withValues(alpha: 0.5)),
                  ),
                  child: Text(
                    '${i + 1}',
                    style: const TextStyle(
                        color: AppColors.gold, fontWeight: FontWeight.bold, fontSize: 12),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: TextField(
                    controller: controllers[i],
                    enabled: enabled,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    onChanged: (_) => onChanged?.call(),
                    decoration: InputDecoration(
                      isDense: true,
                      labelText: 'Quick rake ${i + 1}',
                      hintText: tr('leave_blank_hide'),
                      prefixText: formatter.symbol == '\$' ? '\$ ' : null,
                      suffixText: formatter.symbol == '\$' ? null : formatter.symbol,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Clear slot ${i + 1}',
                  icon: const Icon(Icons.backspace_outlined,
                      size: 18, color: AppColors.textSecondary),
                  onPressed: enabled
                      ? () {
                          controllers[i].clear();
                          onChanged?.call();
                        }
                      : null,
                ),
              ],
            ),
          ),
        const SizedBox(height: 2),
        Text(
          tr('five_buttons_note'),
          style: TextStyle(fontSize: 11, color: AppColors.textSecondary.withValues(alpha: 0.9)),
        ),
      ],
    );
  }
}

/// Read-only preview of the configured slots — shown in House Rules when
/// not editing, and on the New Session form so the banker can see what
/// they just set up.
class QuickRakePreview extends StatelessWidget {
  final List<double> amounts;
  final CurrencyFormatter formatter;
  const QuickRakePreview({super.key, required this.amounts, required this.formatter});

  @override
  Widget build(BuildContext context) {
    if (amounts.isEmpty) {
      return Text(tr('no_quick_rake_configured'),
          style: TextStyle(fontSize: 11, color: AppColors.textSecondary));
    }
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: amounts
          .map((a) => Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                decoration: BoxDecoration(
                  color: AppColors.gold.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: AppColors.gold.withValues(alpha: 0.55)),
                ),
                child: Text(formatter.format(a),
                    style: const TextStyle(
                        color: AppColors.gold, fontWeight: FontWeight.bold, fontSize: 12.5)),
              ))
          .toList(),
    );
  }
}
