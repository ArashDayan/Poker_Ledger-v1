import 'package:hive/hive.dart';

part 'table_participation.g.dart';

/// How a participation was closed.
///
/// `tableCashOut` is defined now (Phase 6 lifecycle) and written by the
/// table-cash-out flow when it lands (Phase 7).
enum ParticipationCloseReason {
  tableCashOut,
  transferOut,
  sessionEnd,
}

/// The lifecycle of a participation (Phase 6).
enum ParticipationStatus { open, closed }

/// One PERSON's commitment of chips/money to ONE table in ONE session
/// — the Level-2 table-participation object (Phase 0 blueprint).
///
/// P-1 (invariant): the participation stores IDENTITY AND LIFECYCLE
/// ONLY. Its money legs are DERIVED — the [LedgerTransaction] rows that
/// carry its id (buy-in / rebuy / transfer-in / transfer-out /
/// cash-out), plus the checkpoints that reference it (a later phase).
/// No money figure is ever stored on this entity.
///
/// LIFECYCLE
///   * Opens on the person's first money leg at the table (buy-in,
///     rebuy, or transfer-in) — never at seating alone: a person can
///     rail a table without committing chips.
///   * Exactly ONE open participation per (person-or-seat, table,
///     session) — a second leg while open stamps the existing one.
///   * Closes on transfer-out (the person moved, carrying chips to
///     another table), on table cash-out (Phase 7 — chips stay with
///     the person), or on session end (the commitment ended with the
///     session).
///
/// LEGACY SEATS
/// [personId] is null for a seat that has never been linked to a
/// person — the participation is then seat-scoped, so unlinked legacy
/// sessions keep working exactly as before (no identity is ever
/// invented).
///
/// A TABLE CASH-OUT is NOT a final casino redemption: it closes the
/// participation while the chips remain the person's physical holding.
/// Final redemption is the cage's operation (Phase 7).
@HiveType(typeId: 15)
class TableParticipation extends HiveObject {
  @HiveField(0)
  String id;

  @HiveField(1)
  String sessionId;

  /// The person's permanent id — or null for an unlinked legacy seat
  /// (see class docs).
  @HiveField(2)
  String? personId;

  @HiveField(3)
  String tableId;

  /// The seat row this participation is tracked through (the Player
  /// row id). Seat rows are session-scoped; this is the seat the
  /// commitment was made through.
  @HiveField(4)
  String seatPlayerId;

  @HiveField(5)
  DateTime openedAt;

  @HiveField(6)
  DateTime? closedAt;

  @HiveField(7)
  ParticipationStatus status;

  @HiveField(8)
  ParticipationCloseReason? closeReason;

  TableParticipation({
    required this.id,
    required this.sessionId,
    required this.personId,
    required this.tableId,
    required this.seatPlayerId,
    DateTime? openedAt,
    this.closedAt,
    this.status = ParticipationStatus.open,
    this.closeReason,
  }) : openedAt = openedAt ?? DateTime.now();

  bool get isOpen => status == ParticipationStatus.open;
  bool get isClosed => status == ParticipationStatus.closed;

  Map<String, dynamic> toJson() => {
        'id': id,
        'sessionId': sessionId,
        'personId': personId,
        'tableId': tableId,
        'seatPlayerId': seatPlayerId,
        'openedAt': openedAt.toIso8601String(),
        'closedAt': closedAt?.toIso8601String(),
        'status': status.index,
        'closeReason': closeReason?.index,
      };

  static TableParticipation fromJson(Map<String, dynamic> j) =>
      TableParticipation(
        id: j['id'] as String,
        sessionId: j['sessionId'] as String,
        personId: j['personId'] as String?,
        tableId: j['tableId'] as String,
        seatPlayerId: j['seatPlayerId'] as String,
        openedAt:
            DateTime.tryParse(j['openedAt']?.toString() ?? '') ??
                DateTime.now(),
        closedAt: j['closedAt'] == null
            ? null
            : DateTime.parse(j['closedAt'] as String),
        status: ParticipationStatus
            .values[(j['status'] as int? ?? 0)],
        closeReason: j['closeReason'] == null
            ? null
            : ParticipationCloseReason.values[j['closeReason'] as int],
      );
}
