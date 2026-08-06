import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../providers/license_provider.dart';
import 'activation_screen.dart';

/// Stands between the splash screen and the app.
///
/// If this installation is licensed it renders [child] untouched, so the
/// entire existing app — session list, PIN lock, everything below it — is
/// completely unaware the licensing layer exists. That is the whole point
/// of gating here rather than sprinkling checks through the app: zero
/// intrusion into session, player, transaction or settlement code.
///
/// If it is not licensed, the app is replaced by [ActivationScreen]. The
/// child is never built, so no ledger screen can be reached or
/// screenshotted around the gate.
class LicenseGate extends StatelessWidget {
  final Widget child;
  const LicenseGate({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    final license = context.watch<LicenseProvider>();
    if (license.isActive) return child;
    return const ActivationScreen();
  }
}
