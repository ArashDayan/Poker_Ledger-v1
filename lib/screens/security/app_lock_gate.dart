import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../providers/app_lock_provider.dart';
import 'app_lock_screen.dart';

/// Watches app lifecycle and shows the lock screen when required.
///
/// Sits BELOW the license gate and ABOVE the app: a device must be
/// licensed before it can even be asked to authenticate, and the ledger
/// is only built once both layers are satisfied. The two remain fully
/// independent — neither reads the other's state.
class AppLockGate extends StatefulWidget {
  final Widget child;
  const AppLockGate({super.key, required this.child});

  @override
  State<AppLockGate> createState() => _AppLockGateState();
}

class _AppLockGateState extends State<AppLockGate>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final provider = context.read<AppLockProvider>();
    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
        provider.onPaused();
      case AppLifecycleState.resumed:
        provider.onResumed();
      case AppLifecycleState.inactive:
      case AppLifecycleState.detached:
        // 'inactive' fires for a notification shade pull or an incoming
        // call. Deliberately ignored: treating it as backgrounding would
        // lock the banker out mid-transaction for no security gain.
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final locked = context.watch<AppLockProvider>().isLocked;

    // The child stays alive underneath so the app does not rebuild its
    // whole state on every unlock — but it is covered completely, and
    // wrapped so nothing underneath can be read or touched.
    return Stack(
      children: [
        widget.child,
        if (locked)
          const Positioned.fill(
            child: AppLockScreen(),
          ),
      ],
    );
  }
}
