import 'package:flutter/material.dart';
import '../../core/localization/app_localizations.dart';
import 'package:provider/provider.dart';
import '../../core/theme/app_theme.dart';
import '../../providers/settings_provider.dart';

class PinLockScreen extends StatefulWidget {
  final Widget child;
  const PinLockScreen({super.key, required this.child});

  @override
  State<PinLockScreen> createState() => _PinLockScreenState();
}

class _PinLockScreenState extends State<PinLockScreen> {
  bool _unlocked = false;
  final _ctrl = TextEditingController();
  String? _error;

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsProvider>();
    if (!settings.hasPinSet || _unlocked) return widget.child;

    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.lock, size: 48, color: AppColors.accentGreen),
              const SizedBox(height: 16),
              Text(tr('enter_pin'), style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
              const SizedBox(height: 24),
              TextField(
                controller: _ctrl,
                obscureText: true,
                keyboardType: TextInputType.number,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 24, letterSpacing: 8),
                decoration: InputDecoration(errorText: _error),
                onSubmitted: (_) => _tryUnlock(settings),
              ),
              const SizedBox(height: 16),
              ElevatedButton(onPressed: () => _tryUnlock(settings), child: Text(tr('unlock'))),
            ],
          ),
        ),
      ),
    );
  }

  void _tryUnlock(SettingsProvider settings) {
    if (settings.verifyPin(_ctrl.text)) {
      setState(() => _unlocked = true);
    } else {
      setState(() => _error = 'Incorrect PIN');
    }
  }
}
