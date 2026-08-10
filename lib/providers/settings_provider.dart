import 'package:flutter/material.dart';
import 'package:crypto/crypto.dart';
import 'dart:convert';
import '../core/localization/app_localizations.dart';
import '../core/utils/currency_formatter.dart';
import '../models/enums.dart';
import '../services/hive_service.dart';

class SettingsProvider extends ChangeNotifier {
  Locale _locale = const Locale('en');
  AppCurrency _defaultCurrency = AppCurrency.usd;
  String? _pinHash;
  bool _privacyMode = false;
  bool _showCumulativeRake = true;

  SettingsProvider() {
    _load();
  }

  Locale get locale => _locale;
  AppCurrency get defaultCurrency => _defaultCurrency;
  bool get hasPinSet => _pinHash != null;

  /// Hides every money amount on screen. Display-only — the ledger,
  /// balance engine and exports are untouched.
  bool get privacyMode => _privacyMode;
  bool get showCumulativeRake => _showCumulativeRake;

  /// Re-reads every preference from storage. Used after a backup
  /// restore, so language, currency, privacy mode and sound settings all
  /// reflect the restored data immediately rather than after a restart.
  Future<void> reload() async {
    _load();
  }

  void _load() {
    final box = HiveService.settings;
    final lang = box.get('language', defaultValue: 'en') as String;
    _locale = Locale(lang);
    // Keep the context-free translator in step with the stored locale.
    setActiveLanguage(lang);
    final currencyIndex = box.get('currency', defaultValue: 0) as int;
    _defaultCurrency = AppCurrency.values[currencyIndex];
    _pinHash = box.get('pin_hash') as String?;
    // Deliberately NOT persisted as "on" across restarts by default —
    // see setPrivacyMode. We still restore it so a banker who wants it
    // always-on gets it from launch.
    _privacyMode = box.get('privacy_mode', defaultValue: false) as bool;
    CurrencyFormatter.privacyMode = _privacyMode;
    // Visible unless the banker previously chose to hide it.
    _showCumulativeRake =
        box.get('show_cumulative_rake', defaultValue: true) as bool;
    notifyListeners();
  }

  Future<void> setLanguage(String code) async {
    _locale = Locale(code);
    setActiveLanguage(code);
    await HiveService.settings.put('language', code);
    notifyListeners();
  }

  Future<void> setDefaultCurrency(AppCurrency currency) async {
    _defaultCurrency = currency;
    await HiveService.settings.put('currency', currency.index);
    notifyListeners();
  }

  /// Toggles the on-screen money mask. Mirrored onto
  /// [CurrencyFormatter.privacyMode] so every amount in the app — on
  /// screens already built and merely repainting — masks instantly.
  Future<void> setPrivacyMode(bool value) async {
    _privacyMode = value;
    CurrencyFormatter.privacyMode = value;
    notifyListeners();
    try {
      await HiveService.settings.put('privacy_mode', value);
    } catch (_) {
      // Best-effort persistence; the toggle still applies this session.
    }
  }

  Future<void> togglePrivacyMode() => setPrivacyMode(!_privacyMode);

  /// Whether the Home screen's cumulative Total Rake figure is shown.
  ///
  /// A DISPLAY PREFERENCE ONLY. It never reaches the rake calculation —
  /// `SessionService.hostProfit` remains the single source of truth and
  /// is queried unchanged whether this is on or off. Hiding simply
  /// swaps the rendered string for a mask.
  ///
  /// Separate from [privacyMode], which blanks every amount app-wide.
  /// A banker may want the running house take off the home screen (it is
  /// the one figure a guest is most likely to glance at) while still
  /// reading normal amounts everywhere else.
  ///
  /// Defaults to true — visible — so behaviour is unchanged until the
  /// banker opts out.
  Future<void> setShowCumulativeRake(bool value) async {
    _showCumulativeRake = value;
    notifyListeners();
    try {
      await HiveService.settings.put('show_cumulative_rake', value);
    } catch (_) {
      // Best-effort persistence; the toggle still applies this session.
    }
  }

  Future<void> toggleCumulativeRake() =>
      setShowCumulativeRake(!_showCumulativeRake);

  String _hash(String pin) => sha256.convert(utf8.encode(pin)).toString();

  Future<void> setPin(String pin) async {
    _pinHash = _hash(pin);
    await HiveService.settings.put('pin_hash', _pinHash);
    notifyListeners();
  }

  Future<void> clearPin() async {
    _pinHash = null;
    await HiveService.settings.delete('pin_hash');
    notifyListeners();
  }

  bool verifyPin(String pin) => _pinHash != null && _hash(pin) == _pinHash;
}
