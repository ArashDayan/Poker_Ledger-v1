import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/localization/app_localizations.dart';
import '../../core/theme/app_theme.dart';
import '../../providers/app_lock_provider.dart';
import '../../security/app_lock_service.dart';
import '../../security/app_lock_settings.dart';

/// The App Lock block inside Settings.
///
/// Self-contained like the License section: Settings gains one line, and
/// deleting this file removes the whole UI surface.
class AppLockSection extends StatefulWidget {
  const AppLockSection({super.key});

  @override
  State<AppLockSection> createState() => _AppLockSectionState();
}

class _AppLockSectionState extends State<AppLockSection> {
  bool _checking = true;
  bool _supported = false;
  bool _hasBiometrics = false;

  @override
  void initState() {
    super.initState();
    _probeDevice();
  }

  /// Asks the OS what it can do. This reads capability only — it never
  /// reads enrolment data itself.
  Future<void> _probeDevice() async {
    final supported = await AppLockService.isSupported();
    final biometrics = await AppLockService.hasBiometricsEnrolled();
    if (!mounted) return;
    setState(() {
      _supported = supported;
      _hasBiometrics = biometrics;
      _checking = false;
    });
  }

  String _timeoutLabel(AutoLockTimeout t) {
    switch (t) {
      case AutoLockTimeout.immediately:
        return tr('lock_immediately');
      case AutoLockTimeout.after1Minute:
        return tr('lock_after_1');
      case AutoLockTimeout.after5Minutes:
        return tr('lock_after_5');
      case AutoLockTimeout.after15Minutes:
        return tr('lock_after_15');
    }
  }

  Future<void> _toggle(AppLockProvider provider, bool value) async {
    // Both directions require passing the OS prompt first: enabling so
    // the user cannot lock themselves out, disabling so someone holding
    // an unlocked phone cannot silently switch protection off.
    final ok = value ? await provider.enable() : await provider.disable();
    if (!mounted) return;

    if (ok) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(value ? tr('app_lock_enabled') : tr('app_lock_disabled')),
      ));
    } else {
      final failure = provider.lastFailure;
      if (failure != null) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(AppLockService.messageFor(failure)),
        ));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<AppLockProvider>();
    final enabled = provider.isEnabled;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(tr('app_lock'),
            style: const TextStyle(color: AppColors.textSecondary)),
        const SizedBox(height: 4),

        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: enabled,
          activeThumbColor: AppColors.accentGreen,
          secondary: Icon(
            enabled ? Icons.lock_outline : Icons.lock_open_outlined,
            color: enabled ? AppColors.accentGreen : AppColors.textSecondary,
          ),
          title: Text(tr('app_lock_enable')),
          subtitle: Text(tr('app_lock_desc')),
          // Disabled while probing, or on a device with no screen lock —
          // offering a switch that cannot work would be a trap.
          onChanged: (_checking || !_supported)
              ? null
              : (v) => _toggle(provider, v),
        ),

        if (!_checking && !_supported)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              tr('app_lock_unsupported_note'),
              style: const TextStyle(
                  fontSize: 11, height: 1.35, color: AppColors.warning),
            ),
          ),

        // Status line, always visible so the banker can confirm at a
        // glance whether the protection is on.
        Padding(
          padding: const EdgeInsets.only(left: 2, bottom: 6),
          child: Row(
            children: [
              Text('${tr('app_lock_status')}:  ',
                  style: const TextStyle(
                      fontSize: 12, color: AppColors.textSecondary)),
              Text(
                enabled ? tr('app_lock_enabled') : tr('app_lock_disabled'),
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  color:
                      enabled ? AppColors.accentGreen : AppColors.textSecondary,
                ),
              ),
            ],
          ),
        ),

        if (!_checking && _supported)
          Padding(
            padding: const EdgeInsets.only(left: 2, bottom: 4),
            child: Row(
              children: [
                Icon(
                  _hasBiometrics ? Icons.fingerprint : Icons.password,
                  size: 13,
                  color: AppColors.textSecondary,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    _hasBiometrics
                        ? tr('app_lock_biometrics_available')
                        : tr('app_lock_credential_only'),
                    style: const TextStyle(
                        fontSize: 11, color: AppColors.textSecondary),
                  ),
                ),
              ],
            ),
          ),

        if (enabled) ...[
          const SizedBox(height: 10),
          Text(tr('auto_lock'),
              style: const TextStyle(
                  fontSize: 12, color: AppColors.textSecondary)),
          const SizedBox(height: 2),
          Text(
            tr('auto_lock_desc'),
            style: TextStyle(
                fontSize: 11,
                color: AppColors.textSecondary.withValues(alpha: 0.85)),
          ),
          const SizedBox(height: 8),
          ...AutoLockTimeout.values.map((t) {
            final selected = provider.timeout == t;
            return RadioListTile<AutoLockTimeout>(
              contentPadding: EdgeInsets.zero,
              dense: true,
              value: t,
              groupValue: provider.timeout,
              activeColor: AppColors.gold,
              title: Text(
                _timeoutLabel(t),
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: selected ? FontWeight.bold : FontWeight.normal,
                  color:
                      selected ? AppColors.gold : AppColors.textPrimary,
                ),
              ),
              onChanged: (v) {
                if (v != null) provider.setTimeout(v);
              },
            );
          }),
        ],

        const SizedBox(height: 6),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.privacy_tip_outlined,
                size: 13, color: AppColors.accentGreen),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                tr('app_lock_privacy_note'),
                style: const TextStyle(
                    fontSize: 10.5,
                    height: 1.35,
                    color: AppColors.textSecondary),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
