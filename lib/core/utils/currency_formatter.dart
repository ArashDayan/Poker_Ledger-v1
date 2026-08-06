import 'package:intl/intl.dart';
import '../../models/enums.dart';

/// Formats amounts for display according to the session's currency.
/// Toman has no meaningful decimal places in everyday cash-game use,
/// so we drop them for readability at the table.
///
/// PRIVACY MODE lives here on purpose. Every amount the app renders goes
/// through [format], so masking at this single choke point guarantees no
/// figure can leak from a screen someone forgot to update — a per-screen
/// implementation would inevitably miss one, and the one it missed would
/// be the one on show when a player leans over the banker's shoulder.
///
/// It is a *display* mask only: the underlying values, the ledger, the
/// balance engine, exports and reports are all completely untouched.
class CurrencyFormatter {
  final AppCurrency currency;
  CurrencyFormatter(this.currency);

  /// When true, every formatted amount renders as dots instead of digits.
  ///
  /// Deliberately static/global rather than passed down through every
  /// widget: privacy has to be instant and total the moment the banker
  /// taps it, including on screens that are already built and merely
  /// repainting.
  static bool privacyMode = false;

  /// The mask shown in place of an amount. Fixed width so turning privacy
  /// on doesn't reflow the layout and shuffle buttons under the banker's
  /// thumb mid-tap.
  static const String maskedText = '••••';

  String format(double amount) {
    if (privacyMode) return maskedText;
    return formatRaw(amount);
  }

  /// Formats ignoring privacy mode.
  ///
  /// For the few places where the number is the entire point of the
  /// interaction and hiding it would be actively unsafe: the amount being
  /// typed into a transaction sheet, and the printed/exported report the
  /// banker generates deliberately. Everything else must use [format].
  String formatRaw(double amount) {
    switch (currency) {
      case AppCurrency.usd:
        final f = NumberFormat.currency(locale: 'en_US', symbol: '\$');
        return f.format(amount);
      case AppCurrency.toman:
        final f = NumberFormat.decimalPattern('fa_IR');
        return '${f.format(amount.round())} تومان';
    }
  }

  String get symbol => currency == AppCurrency.usd ? '\$' : 'تومان';
}
