import 'dart:io';
import '../../core/localization/app_localizations.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import '../../core/theme/app_theme.dart';
import '../../models/enums.dart';
import '../../providers/settings_provider.dart';
import '../../services/sound_service.dart';
import '../../services/backup_service.dart';
import '../license/license_info_section.dart';
import '../security/app_lock_section.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _working = false;

  Future<void> _setPinDialog(SettingsProvider settings) async {
    final ctrl = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('set_pin')),
        content: TextField(
          controller: ctrl,
          keyboardType: TextInputType.number,
          obscureText: true,
          maxLength: 6,
          decoration: InputDecoration(labelText: tr('pin_digits')),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('cancel'))),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text),
            child: Text(tr('save')),
          ),
        ],
      ),
    );
    if (result != null && result.length >= 4) {
      await settings.setPin(result);
    }
  }

  Future<void> _backup() async {
    setState(() => _working = true);
    try {
      final file = await BackupService.exportBackup();
      await Share.shareXFiles([XFile(file.path)],
          text: 'Poker Ledger backup — keep this file safe.');
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(tr('backup_created'))));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Backup failed: $e')));
      }
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _restore() async {
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['json'],
    );
    if (result == null || result.files.single.path == null) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('restore_backup_title')),
        content: Text(tr('restore_merge_note')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('cancel'))),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr('restore')),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() => _working = true);
    try {
      final file = File(result.files.single.path!);
      final res = await BackupService.importBackup(file);
      // Preferences may have changed on disk; re-read them so the UI and
      // the privacy/language state reflect the restored backup at once.
      if (mounted) {
        await context.read<SettingsProvider>().reload();
        AppSounds.loadPreference();
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(
            'Restored ${res.sessionsImported} sessions, ${res.playersImported} '
            'players, ${res.transactionsImported} transactions'
            '${res.settingsImported > 0 ? ', ${res.settingsImported} settings' : ''}.',
          ),
        ));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Restore failed: $e')));
      }
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsProvider>();

    return Scaffold(
      appBar: AppBar(title: Text(tr('settings'))),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(tr('language'), style: TextStyle(color: AppColors.textSecondary)),
          const SizedBox(height: 8),
          SegmentedButton<String>(
            segments: [
              ButtonSegment(value: 'en', label: Text(tr('english'))),
              ButtonSegment(value: 'fa', label: Text('فارسی')),
            ],
            selected: {settings.locale.languageCode},
            onSelectionChanged: (s) => settings.setLanguage(s.first),
          ),
          const SizedBox(height: 24),
          Text(tr('default_currency'), style: TextStyle(color: AppColors.textSecondary)),
          const SizedBox(height: 8),
          SegmentedButton<AppCurrency>(
            segments: [
              ButtonSegment(value: AppCurrency.usd, label: Text('USD (\$)')),
              ButtonSegment(value: AppCurrency.toman, label: Text(tr('toman'))),
            ],
            selected: {settings.defaultCurrency},
            onSelectionChanged: (s) => settings.setDefaultCurrency(s.first),
          ),
          const SizedBox(height: 24),
          const Divider(),
          const SizedBox(height: 8),
          Text(tr('table_sounds'), style: TextStyle(color: AppColors.textSecondary)),
          const SizedBox(height: 4),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: AppSounds.enabled,
            activeThumbColor: AppColors.accentGreen,
            title: Text(tr('chip_sound')),
            subtitle: Text(
                tr('chip_sound_desc_long')),
            onChanged: (v) async {
              await AppSounds.setEnabled(v);
              if (v) AppSounds.playChip();
              if (mounted) setState(() {});
            },
          ),
          if (AppSounds.enabled) ...[
            const SizedBox(height: 12),
            Text(tr('chip_sound'),
                style: const TextStyle(
                    fontSize: 12, color: AppColors.textSecondary)),
            const SizedBox(height: 2),
            Text(
              tr('chip_sound_pick_hint'),
              style: TextStyle(
                  fontSize: 11,
                  color: AppColors.textSecondary.withValues(alpha: 0.85)),
            ),
            const SizedBox(height: 10),
            // Every option is a real slice of the banker's own recording,
            // cut at the natural pauses between gestures.
            ...kChipSamples.map((sample) {
              final selected = AppSounds.selectedSampleId == sample.id;
              return Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Material(
                  color: selected
                      ? AppColors.gold.withValues(alpha: 0.10)
                      : AppColors.surface,
                  borderRadius: BorderRadius.circular(12),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(12),
                    onTap: () async {
                      await AppSounds.setSample(sample.id);
                      AppSounds.previewSample(sample);
                      if (mounted) setState(() {});
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 11),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: selected
                              ? AppColors.gold.withValues(alpha: 0.75)
                              : AppColors.divider,
                        ),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            selected
                                ? Icons.radio_button_checked
                                : Icons.radio_button_unchecked,
                            size: 19,
                            color: selected
                                ? AppColors.gold
                                : AppColors.textSecondary,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  sample.title,
                                  style: TextStyle(
                                    fontSize: 13.5,
                                    fontWeight: FontWeight.bold,
                                    color: selected
                                        ? AppColors.gold
                                        : AppColors.textPrimary,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  '${sample.description} · '
                                  '${sample.duration.toStringAsFixed(2)}s',
                                  style: const TextStyle(
                                      fontSize: 11,
                                      color: AppColors.textSecondary),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 8),
                          Icon(Icons.volume_up_outlined,
                              size: 17,
                              color: AppColors.textSecondary.withValues(alpha: 0.8)),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            }),
          ],
          const SizedBox(height: 16),
          const Divider(),
          const SizedBox(height: 8),
          Text(tr('privacy'), style: TextStyle(color: AppColors.textSecondary)),
          const SizedBox(height: 4),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: settings.privacyMode,
            activeThumbColor: AppColors.gold,
            secondary: Icon(
              settings.privacyMode
                  ? Icons.visibility_off_outlined
                  : Icons.visibility_outlined,
              color: settings.privacyMode ? AppColors.gold : AppColors.accentGreen,
            ),
            title: Text(tr('privacy_mode')),
            subtitle: Text(
                tr('privacy_desc_long')),
            onChanged: (v) => settings.setPrivacyMode(v),
          ),
          const SizedBox(height: 8),
          const Divider(),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.lock_outline, color: AppColors.accentGreen),
            title: Text(settings.hasPinSet ? 'Change App PIN' : 'Set App PIN'),
            subtitle: Text(tr('pin_protect')),
            trailing: settings.hasPinSet
                ? TextButton(onPressed: settings.clearPin, child: Text(tr('remove')))
                : null,
            onTap: () => _setPinDialog(settings),
          ),
          const Divider(),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.upload_file, color: AppColors.accentGreen),
            title: Text(tr('backup_all')),
            subtitle: Text(tr('backup_exports_note')),
            trailing: _working ? const _MiniSpinner() : null,
            onTap: _working ? null : _backup,
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.download, color: AppColors.accentGreen),
            title: Text(tr('restore_backup')),
            subtitle: Text(tr('restore_desc')),
            trailing: _working ? const _MiniSpinner() : null,
            onTap: _working ? null : _restore,
          ),
          const SizedBox(height: 16),
          const Divider(),
          const SizedBox(height: 8),
          const AppLockSection(),
          const SizedBox(height: 16),
          const Divider(),
          const SizedBox(height: 8),
          const LicenseInfoSection(),
          const SizedBox(height: 12),
        ],
      ),
    );
  }
}

class _MiniSpinner extends StatelessWidget {
  const _MiniSpinner();
  @override
  Widget build(BuildContext context) {
    return const SizedBox(
      height: 18,
      width: 18,
      child: CircularProgressIndicator(strokeWidth: 2),
    );
  }
}
