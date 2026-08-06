import 'package:flutter/material.dart';
import '../core/localization/app_localizations.dart';
import 'package:provider/provider.dart';
import '../core/theme/app_theme.dart';
import '../providers/settings_provider.dart';

/// Confirms a destructive or financial-record-modifying action
/// (void/delete/edit a transaction, end a session, etc). Always requires
/// an explicit confirm tap; additionally requires the app PIN if one is
/// configured, since these are exactly the "sensitive actions" a PIN is
/// meant to protect.
Future<bool> confirmSensitiveAction(
  BuildContext context, {
  required String title,
  required String message,
  String confirmLabel = 'Confirm',
  bool isDestructive = false,
}) async {
  final settings = context.read<SettingsProvider>();
  final pinCtrl = TextEditingController();
  String? pinError;

  final result = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) => AlertDialog(
        title: Text(title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(message),
            if (settings.hasPinSet) ...[
              const SizedBox(height: 14),
              TextField(
                controller: pinCtrl,
                obscureText: true,
                keyboardType: TextInputType.number,
                maxLength: 6,
                decoration: InputDecoration(labelText: tr('enter_pin_confirm'), errorText: pinError),
              ),
            ],
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('cancel'))),
          ElevatedButton(
            style: isDestructive
                ? ElevatedButton.styleFrom(backgroundColor: AppColors.danger, foregroundColor: Colors.white)
                : null,
            onPressed: () {
              if (settings.hasPinSet && !settings.verifyPin(pinCtrl.text)) {
                setState(() => pinError = 'Incorrect PIN');
                return;
              }
              Navigator.pop(ctx, true);
            },
            child: Text(confirmLabel),
          ),
        ],
      ),
    ),
  );
  return result ?? false;
}
