import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/localization/app_localizations.dart';
import '../../core/theme/app_theme.dart';
import '../../models/chip_type.dart';
import '../../providers/chip_bank_provider.dart';
import '../../widgets/dual_verification_sheet.dart';

/// A small, fixed palette of typical casino chip colours.
///
/// Offered as a convenience only — "No colour" is the first option and
/// the default, because the spec requires the inventory to work fully
/// without colours.
const List<int> kChipColorSwatches = [
  0xFFE74C3C, // red
  0xFF2E86DE, // blue
  0xFF27AE60, // green
  0xFF1C1C1E, // black
  0xFFF5F5F5, // white
  0xFFF39C12, // orange
  0xFF8E44AD, // purple
  0xFFD4AF37, // gold
];

/// Add or edit one chip denomination.
///
/// Pass [existing] to edit; omit it to create.
class ChipEditorSheet extends StatefulWidget {
  final ChipType? existing;
  const ChipEditorSheet({super.key, this.existing});

  @override
  State<ChipEditorSheet> createState() => _ChipEditorSheetState();
}

class _ChipEditorSheetState extends State<ChipEditorSheet> {
  late final TextEditingController _name;
  late final TextEditingController _value;
  late final TextEditingController _quantity;
  late final TextEditingController _note;

  int? _color;
  String? _error;

  bool get _isEdit => widget.existing != null;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _name = TextEditingController(text: e?.name ?? '');
    // Trim a trailing .0 so a whole-number denomination reads as "200"
    // rather than "200.0" when the banker opens it to edit.
    _value = TextEditingController(
      text: e == null
          ? ''
          : (e.value % 1 == 0
              ? e.value.toInt().toString()
              : e.value.toString()),
    );
    _quantity = TextEditingController(text: e?.quantity.toString() ?? '');
    _note = TextEditingController(text: e?.note ?? '');
    _color = e?.colorValue;
  }

  @override
  void dispose() {
    _name.dispose();
    _value.dispose();
    _quantity.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final value = double.tryParse(_value.text.trim().replaceAll(',', ''));
    if (value == null || value <= 0) {
      setState(() => _error = tr('chip_value_invalid'));
      return;
    }
    final quantity = int.tryParse(_quantity.text.trim().replaceAll(',', ''));
    if (quantity == null || quantity < 0) {
      setState(() => _error = tr('chip_quantity_invalid'));
      return;
    }

    final provider = context.read<ChipBankProvider>();
    final name = _name.text.trim();
    final note = _note.text.trim();

    // D1 (finalised): a change to the quantity or the unit value is a
    // manual inventory adjustment and ALWAYS requires the two-person
    // authorisation (reason + both signatures) before anything is
    // written. Creating a denomination creates owned inventory, so the
    // add path is gated too. Cosmetic edits (name / colour / note)
    // stay single-operator.
    final existing = widget.existing;
    final inventoryChange = existing == null ||
        quantity != existing.quantity ||
        value != existing.value;
    final authorization = inventoryChange
        ? await collectDualAuthorization(
            context,
            operationLabel: tr('chip_inventory_adjustment'),
            amountText: existing == null
                ? '0 → $quantity × $value'
                : '${existing.quantity} → $quantity × $value',
            reasonHint: tr('adjustment_reason_hint'),
          )
        : null;
    if (inventoryChange && (authorization == null || !mounted)) return;

    // Same failure contract as the other inventory entry points
    // (_remove / _adjustQuantity / the holding sheet): a refused or
    // failed write surfaces as a SnackBar and the sheet stays open so
    // the authorization is not silently swallowed.
    try {
      if (_isEdit) {
        await provider.updateChip(
          widget.existing!.id,
          value: value,
          quantity: quantity,
          name: name.isEmpty ? null : name,
          colorValue: _color,
          note: note.isEmpty ? null : note,
          // Explicit clears: leaving a field blank must actually remove
          // it, not silently keep the old value.
          clearName: name.isEmpty,
          clearColor: _color == null,
          clearNote: note.isEmpty,
          authorization: authorization,
        );
      } else {
        await provider.addChip(
          value: value,
          quantity: quantity,
          name: name.isEmpty ? null : name,
          colorValue: _color,
          note: note.isEmpty ? null : note,
          authorization: authorization!,
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('$e')));
      return;
    }

    if (!mounted) return;
    Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final insets = MediaQuery.of(context).viewInsets.bottom;

    return Padding(
      padding: EdgeInsets.only(bottom: insets),
      child: SingleChildScrollView(
        child: Container(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 24),
          decoration: const BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 38,
                  height: 4,
                  decoration: BoxDecoration(
                    color: AppColors.divider,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                _isEdit ? tr('edit_chip_type') : tr('add_chip_type'),
                style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.bold,
                  color: AppColors.textPrimary,
                ),
              ),
              const SizedBox(height: 18),

              // Value and quantity first: these are the two required
              // fields and the only ones the maths depends on.
              TextField(
                controller: _value,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]')),
                ],
                decoration: InputDecoration(
                  labelText: tr('chip_value_required'),
                  prefixIcon: const Icon(Icons.sell_outlined, size: 19),
                  border: const OutlineInputBorder(),
                ),
                onChanged: (_) {
                  if (_error != null) setState(() => _error = null);
                },
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _quantity,
                keyboardType: TextInputType.number,
                inputFormatters: [
                  FilteringTextInputFormatter.digitsOnly,
                ],
                decoration: InputDecoration(
                  labelText: tr('chip_quantity_required'),
                  prefixIcon: const Icon(Icons.numbers, size: 19),
                  border: const OutlineInputBorder(),
                ),
                onChanged: (_) {
                  if (_error != null) setState(() => _error = null);
                },
              ),

              const SizedBox(height: 18),
              const Divider(height: 1),
              const SizedBox(height: 14),

              // Everything below is optional.
              TextField(
                controller: _name,
                textCapitalization: TextCapitalization.words,
                decoration: InputDecoration(
                  labelText: tr('chip_name_optional'),
                  prefixIcon: const Icon(Icons.label_outline, size: 19),
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 14),

              Text(
                tr('chip_color_optional'),
                style: const TextStyle(
                    fontSize: 12, color: AppColors.textSecondary),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _NoColorChoice(
                    selected: _color == null,
                    onTap: () => setState(() => _color = null),
                  ),
                  ...kChipColorSwatches.map((c) => _ColorChoice(
                        color: Color(c),
                        selected: _color == c,
                        onTap: () => setState(() => _color = c),
                      )),
                ],
              ),

              const SizedBox(height: 14),
              TextField(
                controller: _note,
                maxLines: 2,
                minLines: 1,
                decoration: InputDecoration(
                  labelText: tr('chip_note_optional'),
                  border: const OutlineInputBorder(),
                ),
              ),

              if (_error != null) ...[
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: AppColors.danger.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: AppColors.danger),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.error_outline,
                          size: 16, color: AppColors.danger),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _error!,
                          style: const TextStyle(
                              fontSize: 12, color: AppColors.danger),
                        ),
                      ),
                    ],
                  ),
                ),
              ],

              const SizedBox(height: 20),
              SizedBox(
                height: 48,
                child: ElevatedButton.icon(
                  onPressed: _save,
                  icon: const Icon(Icons.check),
                  label: Text(tr('save')),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ColorChoice extends StatelessWidget {
  final Color color;
  final bool selected;
  final VoidCallback onTap;

  const _ColorChoice({
    required this.color,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 38,
        height: 38,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(
            color: selected ? AppColors.gold : AppColors.divider,
            width: selected ? 2.5 : 1,
          ),
        ),
        child: selected
            ? Icon(
                Icons.check,
                size: 18,
                // Contrast against pale swatches like white and gold.
                color: color.computeLuminance() > 0.5
                    ? Colors.black
                    : Colors.white,
              )
            : null,
      ),
    );
  }
}

class _NoColorChoice extends StatelessWidget {
  final bool selected;
  final VoidCallback onTap;

  const _NoColorChoice({required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 38,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: AppColors.surfaceElevated,
          borderRadius: BorderRadius.circular(19),
          border: Border.all(
            color: selected ? AppColors.gold : AppColors.divider,
            width: selected ? 2 : 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              selected ? Icons.check : Icons.block,
              size: 15,
              color: selected ? AppColors.gold : AppColors.textSecondary,
            ),
            const SizedBox(width: 6),
            Text(
              tr('no_color'),
              style: TextStyle(
                fontSize: 12,
                fontWeight: selected ? FontWeight.bold : FontWeight.normal,
                color: selected ? AppColors.gold : AppColors.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
