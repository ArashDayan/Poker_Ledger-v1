import '../models/player.dart';
import 'hive_service.dart';
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

  /// True when a low-level holder reference resolves to a registered
  /// person. The reference may either be a Player Master [personId] or a
  /// seat [Player.id] whose row carries a registered personId.
  static bool hasRegisteredHolderRef(String? refId) {
    if (refId == null || refId.trim().isEmpty) return false;
    if (PlayerIdentityService.byId(refId) != null) return true;
    try {
      final seat = HiveService.players.get(refId);
      return hasRegisteredIdentity(seat);
    } catch (_) {
      return false;
    }
  }

  /// Throws unless a low-level holder reference — a personId or a
  /// seat row id — resolves to a registered Player Master identity.
  ///
  /// This is the boundary gate for untyped/primitive services whose
  /// arguments are ids rather than [Player] objects (for example the
  /// generic chip movement primitives that take a [ChipLocation]).
  static void requireRegisteredHolderRef(String? refId, String operation) {
    if (!hasRegisteredHolderRef(refId)) {
      throw StateError(
        'A registered Player Master identity is required before $operation. '
        'Link/register the person first.',
      );
    }
  }
}
