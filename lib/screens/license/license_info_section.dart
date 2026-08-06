import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/localization/app_localizations.dart';
import '../../core/theme/app_theme.dart';
import '../../license/device_identity.dart';
import '../../license/license_model.dart';
import '../../license/license_policy.dart';
import '../../providers/license_provider.dart';
import 'activation_screen.dart';

/// The License block inside Settings.
///
/// Extracted into its own widget rather than inlined so the licensing
/// feature stays a self-contained module — Settings gains one line, and
/// this file can be deleted to remove the whole UI surface.
class LicenseInfoSection extends StatelessWidget {
  const LicenseInfoSection({super.key});

  String _typeLabel(LicenseType type) {
    switch (type) {
      case LicenseType.trial:
        return tr('license_type_trial');
      case LicenseType.full:
        return tr('license_type_full');
      case LicenseType.club:
        return tr('license_type_club');
      case LicenseType.owner:
        return tr('license_type_owner');
      case LicenseType.standard:
        return tr('license_type_standard');
    }
  }

  String _date(DateTime? d) {
    if (d == null) return '—';
    final local = d.toLocal();
    final y = local.year.toString().padLeft(4, '0');
    final m = local.month.toString().padLeft(2, '0');
    final day = local.day.toString().padLeft(2, '0');
    return '$y-$m-$day';
  }

  Future<void> _deactivate(BuildContext context) async {
    final provider = context.read<LicenseProvider>();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('deactivate_device')),
        content: Text(tr('deactivate_confirm')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(tr('cancel')),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.danger),
            child: Text(tr('deactivate_device')),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    // Only the activation record is removed. Sessions, players and
    // transactions are deliberately untouched, so a customer moving to a
    // new phone does not lose a single hand of history.
    await provider.deactivate();
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(tr('deactivate_done'))));
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<LicenseProvider>();
    final status = provider.status;
    final payload = status.payload;

    final Color statusColor;
    final String statusText;
    if (status.isActive) {
      statusColor = AppColors.accentGreen;
      statusText = tr('status_active');
    } else if (status.error == LicenseError.expired) {
      statusColor = AppColors.warning;
      statusText = tr('status_expired');
    } else if (status.wasEverActivated) {
      statusColor = AppColors.danger;
      statusText = tr('status_invalid');
    } else {
      statusColor = AppColors.textSecondary;
      statusText = tr('status_not_activated');
    }

    final days = status.daysRemaining();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(tr('license'),
            style: const TextStyle(color: AppColors.textSecondary)),
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: statusColor.withValues(alpha: 0.45)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    status.isActive
                        ? Icons.verified_outlined
                        : Icons.gpp_maybe_outlined,
                    size: 18,
                    color: statusColor,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    tr('license_status'),
                    style: const TextStyle(
                        fontSize: 12, color: AppColors.textSecondary),
                  ),
                  const Spacer(),
                  Text(
                    statusText,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                      color: statusColor,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              const Divider(height: 1),
              const SizedBox(height: 10),

              if (payload != null) ...[
                _Row(label: tr('license_id'), value: payload.licenseId),
                if (payload.customerName.isNotEmpty)
                  _Row(label: tr('licensed_to'), value: payload.customerName),
                if (payload.customerId.isNotEmpty)
                  _Row(label: tr('customer_id'), value: payload.customerId),
                _Row(
                    label: tr('license_type'),
                    value: _typeLabel(payload.type)),
                if (LicensePolicy.isOwner(payload))
                  _Row(
                      label: tr('license_scope'),
                      value: tr('owner_master_license')),
                _Row(
                  label: tr('activation_date'),
                  value: _date(status.activatedAt),
                ),
                _Row(
                  label: tr('expiry_date'),
                  value: !LicensePolicy.isExpiryEnforced(payload) ||
                          payload.isPerpetual
                      ? tr('never_expires')
                      : '${_date(payload.expiresAt)}'
                          '${days != null && days >= 0 ? '  ·  $days ${tr('days_remaining')}' : ''}',
                ),
                _Row(
                  label: tr('device_limit'),
                  value: LicensePolicy.deviceAllowanceSummary(payload),
                ),
                if (LicensePolicy.allowsMultipleDevices(payload))
                  Padding(
                    padding: const EdgeInsets.only(top: 2, bottom: 2),
                    child: Text(
                      tr('multi_device_note'),
                      style: TextStyle(
                        fontSize: 10.5,
                        height: 1.3,
                        color: AppColors.textSecondary.withValues(alpha: 0.9),
                      ),
                    ),
                  ),
                const SizedBox(height: 6),
                const Divider(height: 1),
                const SizedBox(height: 6),
              ],

              Text(
                tr('device_info'),
                style: const TextStyle(
                    fontSize: 11, color: AppColors.textSecondary),
              ),
              const SizedBox(height: 4),
              _Row(label: tr('device_id'), value: DeviceIdentity.shortId),
              _Row(
                  label: tr('platform'),
                  value: DeviceIdentity.platformLabel),
              const SizedBox(height: 6),
              Align(
                alignment: AlignmentDirectional.centerEnd,
                child: TextButton.icon(
                  onPressed: () async {
                    await Clipboard.setData(
                        ClipboardData(text: DeviceIdentity.id));
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text(tr('device_id_copied'))),
                    );
                  },
                  icon: const Icon(Icons.copy, size: 15),
                  label: Text(tr('copy')),
                ),
              ),
            ],
          ),
        ),

        if (status.isActive)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.link_off, color: AppColors.danger),
            title: Text(tr('deactivate_device')),
            subtitle: Text(tr('deactivate_desc')),
            onTap: () => _deactivate(context),
          )
        else
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.key, color: AppColors.gold),
            title: Text(tr('reactivate')),
            subtitle: Text(tr('activation_subtitle')),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => const ActivationScreen(),
              ),
            ),
          ),
      ],
    );
  }
}

class _Row extends StatelessWidget {
  final String label;
  final String value;
  const _Row({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            flex: 4,
            child: Text(
              label,
              style: const TextStyle(
                  fontSize: 12, color: AppColors.textSecondary),
            ),
          ),
          Expanded(
            flex: 6,
            child: Text(
              value,
              textAlign: TextAlign.end,
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: AppColors.textPrimary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
