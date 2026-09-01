import '../models/player.dart';
import '../models/session.dart';
import '../providers/session_provider.dart';
import 'player_identity_service.dart';
import 'session_service.dart';
import 'table_service.dart';

/// Why an explicit seat/link action cannot proceed.
enum SeatingBlockReason {
  /// No problem.
  none,

  /// The person has no (valid) Player Identity yet.
  personMissing,

  /// The table is closed.
  closedTable,

  /// The person already has an active seat in this session.
  duplicateActiveParticipation,

  /// The requested seat is already occupied by another player.
  seatTaken,

  /// The seat number is outside the table's configured range.
  invalidSeat,
}

/// Read-only result of the seating guard.
class SeatingBlock {
  final SeatingBlockReason reason;

  /// The existing active participation when
  /// [SeatingBlockReason.duplicateActiveParticipation] is reported.
  final Player? existingParticipation;

  const SeatingBlock.none()
      : reason = SeatingBlockReason.none,
        existingParticipation = null;

  const SeatingBlock.duplicate(Player existing)
      : reason = SeatingBlockReason.duplicateActiveParticipation,
        existingParticipation = existing;

  const SeatingBlock.fail(SeatingBlockReason value)
      : reason = value,
        existingParticipation = null;

  bool get ok => reason == SeatingBlockReason.none;
}

/// Result of an actual write attempt.
class SeatingResult {
  final SeatingBlock block;

  /// The stored Player row when the action succeeded.
  final Player? player;

  const SeatingResult.seated(Player player)
      : block = const SeatingBlock.none(),
        player = player;

  const SeatingResult.blocked(SeatingBlock value)
      : block = value,
        player = null;

  bool get succeeded => block.ok;
}

/// ICR-03 — explicit Player Selection → Seating workflow.
///
/// This is a seating/person-linking service only. It never writes a
/// transaction, financial event, chip movement, marker, discount or
/// table cash-out. The only writes are:
///   * a new [Player] row (session registration + seat) when the person
///     is not yet registered for this session;
///   * a seat pointer move on an already-registered unseated row.
///
/// The person must already be an explicit, registered [PlayerIdentity]
/// (selected or created by the operator). This service never invents an
/// identity.
class SeatingService {
  SeatingService._();

  /// Active seated participation of [personId] in [session], if any.
  static Player? activeParticipation(PokerSession session, String personId) =>
      SessionService.seatedForSession(session.id, personId);

  /// This session's registration row for [personId], whether seated or
  /// not.
  static Player? sessionRegistration(PokerSession session, String personId) =>
      SessionService.registeredForSession(session.id, personId);

  /// Whether an already-occupied [seat] can be explicitly linked to
  /// [personId].
  ///
  /// One (session, person) registration row is the locked rule. Linking
  /// a second seat to a person who already has a row in this session
  /// would silently create a duplicate participation.
  static SeatingBlock linkBlocker({
    required PokerSession session,
    required Player seat,
    required String personId,
  }) {
    if (personId.trim().isEmpty || PlayerIdentityService.byId(personId) == null) {
      return const SeatingBlock.fail(SeatingBlockReason.personMissing);
    }
    if (seat.personId == personId) return const SeatingBlock.none();
    final existing = sessionRegistration(session, personId);
    if (existing != null && existing.id != seat.id) {
      return SeatingBlock.duplicate(existing);
    }
    return const SeatingBlock.none();
  }

  /// Explicitly links an occupied/unlinked seat to an existing person.
  ///
  /// Registration (seating) is intentionally separate: this does not
  /// create a new Player row and it does not write any money/chip data.
  /// Callers must run [linkBlocker] first; [linkPlayer] itself never
  /// invents or validates against session rules.
  static Future<void> linkPlayer(Player seat, String personId) async {
    await PlayerIdentityService.attach(seat, personId);
  }

  /// Guard for the explicit Seat action.
  ///
  /// [tableId]/[seatNumber] are always the destination the operator
  /// confirmed on screen — never inferred by the service.
  static SeatingBlock canSeat({
    required PokerSession session,
    required String personId,
    required String tableId,
    required int seatNumber,
  }) {
    if (personId.trim().isEmpty || PlayerIdentityService.byId(personId) == null) {
      return const SeatingBlock.fail(SeatingBlockReason.personMissing);
    }
    final table = TableService.tableById(session, tableId);
    if (table.status.isClosed) {
      return const SeatingBlock.fail(SeatingBlockReason.closedTable);
    }
    if (seatNumber < 1 || seatNumber > table.seatCount) {
      return const SeatingBlock.fail(SeatingBlockReason.invalidSeat);
    }

    final existing = sessionRegistration(session, personId);
    if (existing != null && existing.seated) {
      return SeatingBlock.duplicate(existing);
    }

    final taken = TableService.occupiedSeats(
      session,
      tableId,
      excludePlayerId: existing?.id,
    );
    if (taken.contains(seatNumber)) {
      return const SeatingBlock.fail(SeatingBlockReason.seatTaken);
    }

    return const SeatingBlock.none();
  }

  /// Executes the confirmed Seat action.
  ///
  /// * New person in this session → writes one seated [Player] row with
  ///   the confirmed [personId]. No transaction, no chips, no money.
  /// * Already registered but unseated → moves the existing row onto the
  ///   confirmed seat. No transaction, no chips, no money.
  ///
  /// Duplicate active participation, closed/full/occupied-table and
  /// missing-person conditions are all rejected before any write.
  static Future<SeatingResult> seatPlayerAt({
    required SessionProvider provider,
    required String personId,
    required String tableId,
    required int seatNumber,
  }) async {
    final session = provider.current;
    if (session == null) {
      throw StateError('No active session.');
    }
    final block = canSeat(
      session: session,
      personId: personId,
      tableId: tableId,
      seatNumber: seatNumber,
    );
    if (!block.ok) {
      return SeatingResult.blocked(block);
    }

    final identity = PlayerIdentityService.byId(personId)!;
    final existing = sessionRegistration(session, personId);
    Player player;
    if (existing != null && !existing.seated) {
      player = await provider.seatRegisteredPlayer(
        existing,
        tableId,
        seat: seatNumber,
      );
    } else {
      player = await provider.addPlayer(
        name: identity.displayName,
        seatNumber: seatNumber,
        tableId: tableId,
        personId: personId,
      );
    }
    return SeatingResult.seated(player);
  }
}
