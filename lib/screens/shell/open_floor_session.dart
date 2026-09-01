import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/session.dart';
import '../../providers/product_nav_controller.dart';
import '../../providers/session_provider.dart';

/// Every "resume/open this live session" path in the app converges here
/// (ICR-02): create-session, session-list tap, player-history live tap.
///
/// The Floor IS the live session in the product shell, so opening a
/// live session = load it into [SessionProvider], drop any routes
/// pushed above the shell (the create-session form, a history screen,
/// …), and select the Floor destination. No five-tab console is pushed
/// for live play anymore; it survives only as a secondary console for
/// session tooling.
///
/// Ended sessions never come through here — they stay on the
/// review/report path ([ReportsScreen]), exactly as before ICR-02.
void openFloorSession(BuildContext context, PokerSession session) {
  final provider = context.read<SessionProvider>();
  provider.loadSession(session);
  provider.retryFailedWatchers();

  final navigator = Navigator.of(context);
  if (navigator.canPop()) {
    navigator.popUntil((route) => route.isFirst);
  }

  try {
    context.read<ProductNavController>().goToFloor();
  } catch (_) {
    // Tool flows and widget tests can open a session without the
    // product shell above them. Loading the provider is the only hard
    // requirement, so a missing controller degrades to "loaded, not
    // visibly switched" instead of throwing through the operator's tap.
  }
}
