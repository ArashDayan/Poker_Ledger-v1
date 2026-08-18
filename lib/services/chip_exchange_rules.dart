import '../models/chip_movement.dart';
import 'chip_tracking_service.dart';

/// Validation for Player ↔ Bank denomination exchange.
///
/// Limit is the player's derived Chip Ledger holding — never Buy-in,
/// Rebuy, Money In, or any financial figure.
class ChipExchangeRules {
  ChipExchangeRules._();

  static double givenValue(Map<String, int> given) =>
      ChipTrackingService.valueOf(given);

  static double receivedValue(Map<String, int> received) =>
      ChipTrackingService.valueOf(received);

  static bool isBalanced(Map<String, int> given, Map<String, int> received) {
    final g = givenValue(given);
    final r = receivedValue(received);
    return g > 0 && (g - r).abs() < 0.005;
  }

  static bool playerCanCover(String playerId, Map<String, int> given) {
    for (final e in given.entries) {
      if (e.value < 0) return false;
      if (e.value >
          ChipTrackingService.quantityAt(
              ChipLocation.player(playerId), e.key)) {
        return false;
      }
    }
    return true;
  }

  static bool bankCanCover(Map<String, int> received) {
    for (final e in received.entries) {
      if (e.value < 0) return false;
      if (e.value >
          ChipTrackingService.quantityAt(ChipLocation.bank, e.key)) {
        return false;
      }
    }
    return true;
  }

  static bool isEmpty(Map<String, int> given, Map<String, int> received) {
    final g = given.values.fold<int>(0, (a, b) => a + (b > 0 ? b : 0));
    final r = received.values.fold<int>(0, (a, b) => a + (b > 0 ? b : 0));
    return g <= 0 && r <= 0;
  }

  /// Null when the exchange may be committed.
  static String? blocker({
    required String? playerId,
    required Map<String, int> given,
    required Map<String, int> received, {
    required String choosePlayer,
    required String empty,
    required String unbalanced,
    required String playerLacks,
    required String bankLacks,
  }) {
    if (playerId == null || playerId.isEmpty) return choosePlayer;
    if (isEmpty(given, received)) return empty;
    if (!isBalanced(given, received)) return unbalanced;
    if (!playerCanCover(playerId, given)) return playerLacks;
    if (!bankCanCover(received)) return bankLacks;
    return null;
  }

  static bool canConfirm({
    required String? playerId,
    required Map<String, int> given,
    required Map<String, int> received,
  }) {
    if (playerId == null || playerId.isEmpty) return false;
    if (!isBalanced(given, received)) return false;
    if (!playerCanCover(playerId, given)) return false;
    if (!bankCanCover(received)) return false;
    return true;
  }
}
