import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/localization/app_localizations.dart';
import '../../core/theme/app_theme.dart';
import '../../providers/app_lock_provider.dart';
import '../../security/app_lock_service.dart';
import '../../widgets/poker_chip_logo.dart';

/// Full-screen, fully opaque lock.
///
/// Opaque matters: the ledger stays mounted underneath so an in-progress
/// session keeps its state, and this must cover it completely so no
/// amount is readable through the lock.
class AppLockScreen extends StatefulWidget {
  const AppLockScreen({super.key});

  @override
  State<AppLockScreen> createState() => _AppLockScreenState();
}

class _AppLockScreenState extends State<AppLockScreen> {
  @override
  void initState() {
    super.initState();
    // Prompt as soon as the lock appears, so the common case is a single
    // glance at the sensor rather than an extra tap.
    WidgetsBinding.instance.addPostFrameCallback((_) => _authenticate());
  }

  Future<void> _authenticate() async {
    if (!mounted) return;
    final provider = context.read<AppLockProvider>();
    if (provider.isAuthenticating) return;
    await provider.unlock();
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<AppLockProvider>();
    final failure = provider.lastFailure;

    // Absorb every pointer event so nothing underneath can be touched.
    return Material(
      color: AppColors.background,
      child: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 380),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const PokerChipLogo(size: 84),
                  const SizedBox(height: 24),
                  const Icon(Icons.lock_outline,
                      size: 30, color: AppColors.gold),
                  const SizedBox(height: 12),
                  Text(
                    tr('app_lock_title'),
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 19,
                      fontWeight: FontWeight.bold,
                      color: AppColors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    tr('app_lock_reason'),
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 13,
                      height: 1.4,
                      color: AppColors.textSecondary,
                    ),
                  ),

                  if (failure != null) ...[
                    const SizedBox(height: 20),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: AppColors.warning.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                            color: AppColors.warning.withValues(alpha: 0.7)),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Icon(Icons.info_outline,
                              size: 16, color: AppColors.warning),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              AppLockService.messageFor(failure),
                              style: const TextStyle(
                                fontSize: 12,
                                height: 1.35,
                                color: AppColors.warning,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],

                  const SizedBox(height: 26),
                  SizedBox(
                    height: 48,
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed:
                          provider.isAuthenticating ? null : _authenticate,
                      icon: provider.isAuthenticating
                          ? const SizedBox(
                              height: 16,
                              width: 16,
                              child:
                                  CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.fingerprint),
                      label: Text(tr('app_lock_unlock')),
                    ),
                  ),

                  const SizedBox(height: 18),
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
