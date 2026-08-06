import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/localization/app_localizations.dart';
import '../../core/theme/app_theme.dart';
import '../../providers/session_provider.dart';
import '../../services/tournament_service.dart';

/// Fully customisable blind structure: add, edit, reorder and delete
/// levels and breaks, with unlimited levels.
///
/// Edits are held locally and only written when the banker saves, so a
/// half-finished structure can never take effect mid-tournament.
class BlindStructureScreen extends StatefulWidget {
  const BlindStructureScreen({super.key});

  @override
  State<BlindStructureScreen> createState() => _BlindStructureScreenState();
}

class _BlindStructureScreenState extends State<BlindStructureScreen> {
  late List<BlindLevel> _levels;
  bool _dirty = false;

  @override
  void initState() {
    super.initState();
    _levels = [...context.read<SessionProvider>().blindLevels];
  }

  Future<void> _save() async {
    await context.read<SessionProvider>().saveBlindStructure(_levels);
    if (!mounted) return;
    setState(() => _dirty = false);
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(tr('structure_saved'))));
  }

  @override
  Widget build(BuildContext context) {
    final currentIndex = context.watch<SessionProvider>().current!.currentBlindIndex;

    return Scaffold(
      appBar: AppBar(
        title: Text(tr('blind_structure')),
        actions: [
          if (_dirty)
            TextButton(
              onPressed: _save,
              child: Text(tr('save'),
                  style: const TextStyle(
                      color: AppColors.accentGreen,
                      fontWeight: FontWeight.bold)),
            ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Text(
              tr('blind_structure_hint'),
              style: const TextStyle(
                  fontSize: 11.5, color: AppColors.textSecondary),
            ),
          ),
          Expanded(
            child: ReorderableListView.builder(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 100),
              itemCount: _levels.length,
              onReorderItem: (oldIndex, newIndex) {
                setState(() {
                  if (newIndex > oldIndex) newIndex--;
                  _levels.insert(newIndex, _levels.removeAt(oldIndex));
                  _dirty = true;
                });
              },
              itemBuilder: (ctx, i) => _levelTile(i, currentIndex),
            ),
          ),
        ],
      ),
      floatingActionButton: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          FloatingActionButton.extended(
            heroTag: 'addBreak',
            backgroundColor: AppColors.surfaceElevated,
            foregroundColor: AppColors.warning,
            onPressed: () => setState(() {
              _levels.add(const BlindLevel(
                  smallBlind: 0, bigBlind: 0, minutes: 10, isBreak: true));
              _dirty = true;
            }),
            icon: const Icon(Icons.free_breakfast_outlined, size: 18),
            label: Text(tr('add_break')),
          ),
          const SizedBox(width: 10),
          FloatingActionButton.extended(
            heroTag: 'addLevel',
            onPressed: () => setState(() {
              // Continue the escalation from the last real level so a new
              // level is a sensible next step, not a blank form.
              final lastReal = _levels.lastWhere(
                (l) => !l.isBreak,
                orElse: () => const BlindLevel(
                    smallBlind: 25, bigBlind: 50, minutes: 20),
              );
              final bb = lastReal.bigBlind * 1.5;
              _levels.add(BlindLevel(
                smallBlind: bb / 2,
                bigBlind: bb,
                ante: lastReal.ante > 0 ? bb / 4 : 0,
                minutes: lastReal.minutes,
              ));
              _dirty = true;
            }),
            icon: const Icon(Icons.add, size: 18),
            label: Text(tr('add_level')),
          ),
        ],
      ),
    );
  }

  Widget _levelTile(int i, int currentIndex) {
    final l = _levels[i];
    final isCurrent = i == currentIndex;
    // Level numbering skips breaks, matching how players count levels.
    final levelNumber =
        _levels.take(i + 1).where((x) => !x.isBreak).length;

    return Container(
      key: ValueKey('level-$i-${l.hashCode}'),
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: AppColors.surfaceElevated,
        borderRadius: BorderRadius.circular(13),
        border: Border.all(
          color: isCurrent
              ? AppColors.accentGreen
              : (l.isBreak
                  ? AppColors.warning.withValues(alpha: 0.4)
                  : AppColors.divider),
          width: isCurrent ? 1.6 : 1,
        ),
      ),
      child: ListTile(
        contentPadding: const EdgeInsetsDirectional.only(start: 12, end: 4),
        leading: Container(
          width: 34,
          height: 34,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: l.isBreak
                ? AppColors.warning.withValues(alpha: 0.15)
                : AppColors.accentGreen.withValues(alpha: 0.13),
          ),
          child: l.isBreak
              ? const Icon(Icons.free_breakfast_outlined,
                  size: 16, color: AppColors.warning)
              : Text('$levelNumber',
                  style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: AppColors.accentGreen)),
        ),
        title: Text(
          l.isBreak ? tr('break_') : l.blindsText,
          style: TextStyle(
            fontWeight: FontWeight.bold,
            fontSize: 13.5,
            color: l.isBreak ? AppColors.warning : AppColors.textPrimary,
          ),
        ),
        subtitle: Text('${l.minutes} ${tr('minutes')}',
            style: const TextStyle(fontSize: 11)),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.edit_outlined, size: 18),
              onPressed: () => _editLevel(i),
            ),
            IconButton(
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.delete_outline,
                  size: 18, color: AppColors.danger),
              onPressed: _levels.length <= 1
                  ? null
                  : () => setState(() {
                        _levels.removeAt(i);
                        _dirty = true;
                      }),
            ),
            ReorderableDragStartListener(
              index: i,
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 6),
                child: Icon(Icons.drag_handle,
                    size: 20, color: AppColors.textSecondary),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _editLevel(int i) async {
    final l = _levels[i];
    final sb = TextEditingController(text: l.smallBlind.toStringAsFixed(0));
    final bb = TextEditingController(text: l.bigBlind.toStringAsFixed(0));
    final ante = TextEditingController(text: l.ante.toStringAsFixed(0));
    final mins = TextEditingController(text: '${l.minutes}');
    var isBreak = l.isBreak;

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: Text(isBreak ? tr('break_') : tr('level')),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: isBreak,
                  activeColor: AppColors.warning,
                  title: Text(tr('is_break'),
                      style: const TextStyle(fontSize: 14)),
                  onChanged: (v) => setLocal(() => isBreak = v),
                ),
                if (!isBreak) ...[
                  TextField(
                    controller: sb,
                    keyboardType: TextInputType.number,
                    decoration:
                        InputDecoration(labelText: tr('small_blind')),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: bb,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(labelText: tr('big_blind')),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: ante,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(labelText: tr('ante')),
                  ),
                  const SizedBox(height: 10),
                ],
                TextField(
                  controller: mins,
                  keyboardType: TextInputType.number,
                  decoration:
                      InputDecoration(labelText: tr('duration_minutes')),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text(tr('cancel'))),
            ElevatedButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: Text(tr('save'))),
          ],
        ),
      ),
    );

    if (ok != true) return;
    setState(() {
      _levels[i] = BlindLevel(
        smallBlind: double.tryParse(sb.text) ?? l.smallBlind,
        bigBlind: double.tryParse(bb.text) ?? l.bigBlind,
        ante: double.tryParse(ante.text) ?? 0,
        minutes: int.tryParse(mins.text) ?? l.minutes,
        isBreak: isBreak,
      );
      _dirty = true;
    });
  }
}
