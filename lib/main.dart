import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';
import 'core/localization/app_localizations.dart';
import 'core/theme/app_theme.dart';
import 'providers/app_lock_provider.dart';
import 'providers/chip_bank_provider.dart';
import 'providers/license_provider.dart';
import 'providers/session_provider.dart';
import 'providers/settings_provider.dart';
import 'screens/license/license_gate.dart';
import 'screens/security/app_lock_gate.dart';
import 'screens/home/session_list_screen.dart';
import 'screens/settings/pin_lock_screen.dart';
import 'screens/splash/splash_screen.dart';
import 'services/hive_service.dart';
import 'services/sound_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await HiveService.init();
    // Read the chip-sound preference before the first frame so the very
    // first tap of the night already respects it.
    AppSounds.loadPreference();
    runApp(const PokerLedgerApp());
  } catch (e) {
    // A corrupted local database (a killed write, low storage, a bad OS
    // update) should never mean the app fails to even launch with no
    // explanation. Show a clear, honest screen instead of crashing.
    runApp(StorageErrorApp(error: e.toString()));
  }
}

/// Minimal fallback shown only if local storage genuinely could not be
/// initialized even after HiveService's own per-box recovery attempt.
class StorageErrorApp extends StatelessWidget {
  final String error;
  const StorageErrorApp({super.key, required this.error});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: AppTheme.dark(),
      home: Scaffold(
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.storage_outlined, size: 48, color: AppColors.danger),
                  const SizedBox(height: 16),
                  Text(tr('app_start_failed'),
                      style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                      textAlign: TextAlign.center),
                  const SizedBox(height: 12),
                  const Text(
                    "Local storage on this device couldn't be opened, even after "
                    'attempting to recover it automatically. Try restarting the app. '
                    'If this keeps happening, check available storage space, or '
                    'reinstall — but note reinstalling will lose any unsaved sessions.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: AppColors.textSecondary),
                  ),
                  const SizedBox(height: 16),
                  Text(error,
                      style: const TextStyle(fontSize: 11, color: AppColors.textSecondary),
                      textAlign: TextAlign.center),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class PokerLedgerApp extends StatelessWidget {
  const PokerLedgerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => SettingsProvider()),
        ChangeNotifierProvider(create: (_) => SessionProvider()),
        // Licensing is a sibling provider, not a wrapper around the
        // others, so nothing about session/settings behaviour changes.
        ChangeNotifierProvider(create: (_) => LicenseProvider()),
        // App Lock is a sibling of the license provider, not nested in
        // it: the two layers are independent and neither reads the
        // other's state.
        ChangeNotifierProvider(create: (_) => AppLockProvider()),
        // Physical chip inventory. A sibling provider that never reads or
        // notifies the session tree, so chip edits cannot touch the ledger.
        ChangeNotifierProvider(create: (_) => ChipBankProvider()),
      ],
      child: Consumer<SettingsProvider>(
        builder: (context, settings, _) {
          return MaterialApp(
            title: 'Poker Ledger',
            debugShowCheckedModeBanner: false,
            theme: AppTheme.dark(),
            darkTheme: AppTheme.dark(),
            themeMode: ThemeMode.dark,
            locale: settings.locale,
            supportedLocales: AppLocalizations.supportedLocales,
            localizationsDelegates: const [
              AppLocalizationsDelegate(),
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            builder: (context, child) {
              final isRtl = settings.locale.languageCode == 'fa';
              return Directionality(
                textDirection: isRtl ? TextDirection.rtl : TextDirection.ltr,
                // Keying the subtree on privacy mode forces EVERY built
                // screen to rebuild the instant it is toggled — including
                // tabs parked inside an IndexedStack, which would
                // otherwise keep their last frame (and its visible
                // amounts) until the banker happened to touch them. That
                // stale frame is precisely the leak privacy mode exists
                // to prevent, so correctness beats the rebuild cost here.
                // Re-key on privacy AND language so every built screen —
                // including tabs parked in an IndexedStack — rebuilds the
                // instant either changes. A stale frame would leave
                // amounts visible after privacy is enabled, or English
                // text on screen after switching to Persian.
                child: KeyedSubtree(
                  key: ValueKey(
                      'ui-${settings.privacyMode}-${settings.locale.languageCode}'),
                  child: child!,
                ),
              );
            },
            // Order matters: brand splash, then the license gate, then
            // the existing PIN lock and app. Gating ABOVE the app means
            // the ledger UI is never built while unlicensed, and gating
            // BELOW the splash means a licensed user sees the normal
            // launch they always have.
            // Layer order: brand splash -> license gate -> app lock ->
            // existing PIN lock -> app. A device must be licensed before
            // it is asked to authenticate, and the ledger is only built
            // once both security layers are satisfied. Everything below
            // AppLockGate is untouched from before.
            home: const SplashScreen(
              child: LicenseGate(
                child: AppLockGate(
                  child: PinLockScreen(child: SessionListScreen()),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
