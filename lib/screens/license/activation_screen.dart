import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/localization/app_localizations.dart';
import '../../core/theme/app_theme.dart';
import '../../license/device_identity.dart';
import '../../license/license_model.dart';
import '../../providers/license_provider.dart';
import '../../widgets/poker_chip_logo.dart';

/// Maps a machine-level failure to a message a non-technical banker can
/// act on. Shared with Settings so both places explain a problem the
/// same way.
String licenseErrorMessage(LicenseError error) {
  switch (error) {
    case LicenseError.empty:
      return tr('err_license_empty');
    case LicenseError.malformed:
      return tr('err_license_malformed');
    case LicenseError.badSignature:
      return tr('err_license_signature');
    case LicenseError.expired:
      return tr('err_license_expired');
    case LicenseError.wrongDevice:
      return tr('err_license_device');
    case LicenseError.deviceLimitReached:
      return tr('err_license_limit');
    case LicenseError.futureFormat:
      return tr('err_license_future');
    case LicenseError.tampered:
      return tr('err_license_tampered');
  }
}

/// Shown instead of the app when this installation is not licensed.
///
/// Tone matters here: the person looking at this screen is usually a
/// paying customer who just installed the app, not an attacker. So it
/// explains what to do next and makes the Device ID trivially easy to
/// send, rather than reading like an accusation.
class ActivationScreen extends StatefulWidget {
  const ActivationScreen({super.key});

  @override
  State<ActivationScreen> createState() => _ActivationScreenState();
}

class _ActivationScreenState extends State<ActivationScreen> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _activate() async {
    final provider = context.read<LicenseProvider>();
    final ok = await provider.activate(_controller.text);
    if (!mounted) return;
    if (ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr('activation_success'))),
      );
      // When reached from Settings this screen sits on a route that must
      // be dismissed. At the launch gate there is nothing to pop and the
      // gate swaps itself for the app automatically.
      final navigator = Navigator.of(context);
      if (navigator.canPop()) navigator.pop();
    }
  }

  Future<void> _copyDeviceId() async {
    await Clipboard.setData(ClipboardData(text: DeviceIdentity.id));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(tr('device_id_copied'))),
    );
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<LicenseProvider>();
    final error = provider.lastError;
    final status = provider.status;

    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 28),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Center(child: PokerChipLogo(size: 92)),
                  const SizedBox(height: 20),
                  Text(
                    tr('activation_title'),
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                      color: AppColors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    tr('activation_subtitle'),
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 13,
                      color: AppColors.textSecondary,
                    ),
                  ),

                  // An expired or previously-broken activation is a
                  // different situation from a fresh install, so say so
                  // rather than showing the same blank prompt.
                  if (status.error != null && error == null) ...[
                    const SizedBox(height: 16),
                    _Notice(
                      icon: Icons.info_outline,
                      color: AppColors.warning,
                      message: licenseErrorMessage(status.error!),
                    ),
                  ],

                  const SizedBox(height: 24),
                  TextField(
                    controller: _controller,
                    maxLines: 4,
                    minLines: 2,
                    autocorrect: false,
                    enableSuggestions: false,
                    textDirection: TextDirection.ltr,
                    style: const TextStyle(
                      fontSize: 12,
                      fontFamily: 'monospace',
                      height: 1.4,
                    ),
                    decoration: InputDecoration(
                      labelText: tr('license_key'),
                      hintText: tr('license_key_hint'),
                      alignLabelWithHint: true,
                      border: const OutlineInputBorder(),
                    ),
                    onChanged: (_) => provider.clearError(),
                  ),

                  if (error != null) ...[
                    const SizedBox(height: 12),
                    _Notice(
                      icon: Icons.error_outline,
                      color: AppColors.danger,
                      message: licenseErrorMessage(error),
                    ),
                  ],

                  const SizedBox(height: 18),
                  SizedBox(
                    height: 48,
                    child: ElevatedButton.icon(
                      onPressed: provider.busy ? null : _activate,
                      icon: provider.busy
                          ? const SizedBox(
                              height: 16,
                              width: 16,
                              child:
                                  CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.key),
                      label: Text(tr('activate')),
                    ),
                  ),

                  const SizedBox(height: 28),
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: AppColors.surface,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                          color: AppColors.gold.withValues(alpha: 0.35)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Icon(Icons.help_outline,
                                size: 16, color: AppColors.gold),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                tr('activation_how_title'),
                                style: const TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.bold,
                                  color: AppColors.gold,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Text(
                          tr('activation_how_body'),
                          style: const TextStyle(
                              fontSize: 11.5,
                              height: 1.4,
                              color: AppColors.textSecondary),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          tr('device_id'),
                          style: const TextStyle(
                              fontSize: 11, color: AppColors.textSecondary),
                        ),
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            Expanded(
                              child: SelectableText(
                                DeviceIdentity.shortId,
                                textDirection: TextDirection.ltr,
                                style: const TextStyle(
                                  fontSize: 16,
                                  fontFamily: 'monospace',
                                  letterSpacing: 1.5,
                                  fontWeight: FontWeight.bold,
                                  color: AppColors.textPrimary,
                                ),
                              ),
                            ),
                            TextButton.icon(
                              onPressed: _copyDeviceId,
                              icon: const Icon(Icons.copy, size: 15),
                              label: Text(tr('copy')),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 16),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(Icons.shield_outlined,
                          size: 13, color: AppColors.accentGreen),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          '${tr('license_data_safe_note')} '
                          '${tr('license_offline_note')}',
                          style: const TextStyle(
                            fontSize: 10.5,
                            height: 1.35,
                            color: AppColors.textSecondary,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String message;

  const _Notice({
    required this.icon,
    required this.color,
    required this.message,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(11),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.7)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: TextStyle(fontSize: 12, height: 1.35, color: color),
            ),
          ),
        ],
      ),
    );
  }
}
