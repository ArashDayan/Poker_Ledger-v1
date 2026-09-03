import '../models/player.dart';
import 'player_identity_service.dart';

/// The absolute Player-Master identity gate (locked J5).
///
/// Every NEW player-related operational action must pass through this
/// guard at the service/API boundary, not merely in the UI. A player row
/// whose [Player.personId] is missing/empty, or which points at no
/// existing [PlayerIdentity], is an unregistered/anonymous seat and must
/// be refused.
///
/// The guard is deliberately read-only and central: UI can explain, the
/// service refuses. It never creates or modifies anything.
class PlayerOperationGuard {
  PlayerOperationGuard._();

  /// True when [player] is backed by a real, existing Player Master
  /// identity.
  static bool hasRegisteredIdentity(Player? player) {
    if (player == null) return false;
    final id = player.personId;
    if (id == null || id.trim().isEmpty) return false;
    return PlayerIdentityService.byId(id) != null;
  }

  /// True when [personId] points at a real, existing identity.
  static bool hasRegisteredPerson(String? personId) {
    if (personId == null || personId.trim().isEmpty) return false;
    return PlayerIdentityService.byId(personId) != null;
  }

  /// Throws unless [player] has a registered Player Master identity.
  static void requireRegistered(Player? player, String operation) {
    if (!hasRegisteredIdentity(player)) {
      throw StateError(
        'A registered Player Master identity is required before $operation. '
        'Link/register the person first.',
      );
    }
  }

  /// Throws unless [personId] resolves to a Player Master identity.
  static void requireRegisteredPerson(String? personId, String operation) {
    if (!hasRegisteredPerson(personId)) {
      throw StateError(
        'A registered Player Master identity is required before $operation. '
        'Link/register the person first.',
      );
    }
  }
}
