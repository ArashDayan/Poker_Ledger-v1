class Validators {
  static String? requiredText(String? value, {String field = 'This field'}) {
    if (value == null || value.trim().isEmpty) {
      return '$field is required.';
    }
    return null;
  }

  static String? positiveAmount(String? value) {
    if (value == null || value.trim().isEmpty) return 'Amount is required.';
    final parsed = double.tryParse(value.replaceAll(',', ''));
    if (parsed == null) return 'Enter a valid number.';
    if (parsed <= 0) return 'Amount must be greater than zero.';
    return null;
  }

  static String? nonNegativeAmount(String? value) {
    if (value == null || value.trim().isEmpty) return 'Amount is required.';
    final parsed = double.tryParse(value.replaceAll(',', ''));
    if (parsed == null) return 'Enter a valid number.';
    if (parsed < 0) return 'Amount cannot be negative.';
    return null;
  }

  /// Cash-out is the one transaction type where 0 is a normal, valid
  /// outcome — a player who loses every chip busts out for $0. Only
  /// negative or unparseable values are rejected.
  static String? cashOutAmount(String? value) => nonNegativeAmount(value);

  static String? seatNumber(String? value) {
    if (value == null || value.trim().isEmpty) return 'Seat number is required.';
    final parsed = int.tryParse(value);
    if (parsed == null || parsed < 1 || parsed > 10) {
      return 'Seat must be between 1 and 10.';
    }
    return null;
  }

  static String? percentage(String? value) {
    if (value == null || value.trim().isEmpty) return null; // optional
    final parsed = double.tryParse(value);
    if (parsed == null) return 'Enter a valid percentage.';
    if (parsed < 0 || parsed > 100) return 'Must be between 0 and 100.';
    return null;
  }
}
