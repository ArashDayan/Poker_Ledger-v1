import 'package:hive/hive.dart';

part 'chip_movement.g.dart';

/// Where physical chips can be.
///
/// Stored as a string on the wire (not an enum index) so inserting a new
/// location later cannot silently re-map existing records.
enum ChipLocationKind {
  /// The banker's master case.
  bank,

  /// A poker table's tray.
  table,

  /// In front of a specific player.
  player,

  /// Taken out of play: rake, damage, manual write-off. Not missing —
  /// deliberately removed and accounted for.
  removed;

  static ChipLocationKind parse(String? raw) {
    switch (raw) {
      case 'table':
        return ChipLocationKind.table;
      case 'player':
        return ChipLocationKind.player;
      case 'removed':
        return ChipLocationKind.removed;
      default:
        return ChipLocationKind.bank;
    }
  }

  String get wire => name;
}

/// A physical place chips can sit: a kind plus, for tables and players,
/// which one.
///
/// Immutable value type with structural equality so it can key a map —
/// which is how every balance in [ChipTrackingService] is accumulated.
class ChipLocation {
  final ChipLocationKind kind;

  /// Table id or player id. Null for [ChipLocationKind.bank] and
  /// [ChipLocationKind.removed], which are singletons.
  final String? refId;

  const ChipLocation(this.kind, [this.refId]);

  static const bank = ChipLocation(ChipLocationKind.bank);
  static const removed = ChipLocation(ChipLocationKind.removed);

  static ChipLocation table(String id) =>
      ChipLocation(ChipLocationKind.table, id);
  static ChipLocation player(String id) =>
      ChipLocation(ChipLocationKind.player, id);

  bool get isBank => kind == ChipLocationKind.bank;
  bool get isTable => kind == ChipLocationKind.table;
  bool get isPlayer => kind == ChipLocationKind.player;
  bool get isRemoved => kind == ChipLocationKind.removed;

  /// Compact form used inside a movement record: `bank`, `removed`,
  /// `table:abc`, `player:xyz`.
  String get encoded => refId == null ? kind.wire : '${kind.wire}:$refId';

  static ChipLocation decode(String? raw) {
    if (raw == null || raw.isEmpty) return bank;
    final idx = raw.indexOf(':');
    if (idx < 0) return ChipLocation(ChipLocationKind.parse(raw));
    return ChipLocation(
      ChipLocationKind.parse(raw.substring(0, idx)),
      raw.substring(idx + 1),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ChipLocation && other.kind == kind && other.refId == refId;

  @override
  int get hashCode => Object.hash(kind, refId);

  @override
  String toString() => encoded;
}

/// Why chips moved. Descriptive only — none of these alter money.
enum ChipMovementReason {
  /// Chips handed out for a buy-in.
  buyIn,

  /// Chips handed out for a rebuy.
  rebuy,

  /// Chips handed out for an add-on.
  addOn,

  /// Chips returned when a player cashes out.
  cashOut,

  /// Bank stocking a table's tray, or pulling it back.
  tableFloat,

  /// Chips physically handed to the banker as rake.
  ///
  /// Rake in this app is always collected in chips, never cash, so those
  /// chips physically enter the Bank — the destination is
  /// [ChipLocationKind.bank], never `removed`.
  rake,

  /// Banker correcting a count, or writing off damaged chips.
  adjustment,

  /// Chips taken off a table as a dealer tip and returned to the Bank.
  ///
  /// Physically identical to [rake] — chips move table/player -> bank —
  /// but kept distinct so the audit log says WHY they moved, and so the
  /// reconciliation can report tips separately from house income.
  dealerTips,

  /// One leg of a denomination exchange. Both legs share an
  /// `exchange:<uuid>` tag in [ChipMovement.note] and carry equal total
  /// value, so an exchange nets to zero for both sides.
  exchange,

  /// Undoes an earlier movement, e.g. when a transaction is voided or a
  /// chip composition is corrected.
  ///
  /// Appended rather than deleting the original, so the audit trail
  /// still shows what happened and why it was undone.
  reversal,

  /// Chips physically moved between two places for any other reason,
  /// including player-to-player winnings.
  transfer,

  /// Promotional loss-rebate chips. NOT a buy-in, NOT a rebuy, NOT
  /// cashInForChips. SessionService money formulas never see this.
  lossRebate;

  static ChipMovementReason parse(String? raw) {
    for (final r in ChipMovementReason.values) {
      if (r.name == raw) return r;
    }
    return ChipMovementReason.transfer;
  }

  String get wire => name;
}

/// One physical chip movement: N chips of one denomination, from one
/// place to another, at one moment.
///
/// APPEND-ONLY BY DESIGN
/// Nothing ever edits or deletes a movement. Every balance in the system
/// is derived by folding this log, which means the audit report cannot
/// drift out of step with the holdings it reports on — they are computed
/// from the same records. Correcting a mistake means appending a
/// compensating [ChipMovementReason.adjustment], exactly like a real
/// ledger.
///
/// Uses typeId 10, the next free id.
@HiveType(typeId: 10)
class ChipMovement extends HiveObject {
  @HiveField(0)
  String id;

  /// Session this happened in. Null for movements made outside any
  /// session (e.g. the banker restocking the case at home).
  @HiveField(1)
  String? sessionId;

  /// The ChipType this refers to.
  @HiveField(2)
  String chipTypeId;

  /// Denomination captured AT THE TIME of the movement.
  ///
  /// Denormalised on purpose: if the banker later corrects a chip's
  /// value, historical movements must still report what actually moved.
  /// Recomputing from the live ChipType would silently rewrite history.
  @HiveField(3)
  double chipValue;

  /// How many chips moved. Always positive; direction is expressed by
  /// [from] and [to], never by a negative quantity.
  @HiveField(4)
  int quantity;

  /// Encoded [ChipLocation].
  @HiveField(5)
  String fromLocation;

  @HiveField(6)
  String toLocation;

  /// Encoded [ChipMovementReason].
  @HiveField(7)
  String reason;

  @HiveField(8)
  DateTime timestamp;

  /// Links this movement to the money transaction it accompanied, when
  /// there was one. Purely informational — the financial record does not
  /// know or care that this exists.
  @HiveField(9)
  String? transactionId;

  @HiveField(10)
  String? note;

  ChipMovement({
    required this.id,
    required this.chipTypeId,
    required this.chipValue,
    required this.quantity,
    required this.fromLocation,
    required this.toLocation,
    required this.reason,
    this.sessionId,
    this.transactionId,
    this.note,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();

  ChipLocation get from => ChipLocation.decode(fromLocation);
  ChipLocation get to => ChipLocation.decode(toLocation);
  ChipMovementReason get reasonEnum => ChipMovementReason.parse(reason);

  /// Money value of this movement. Descriptive only — never fed into any
  /// financial calculation.
  double get totalValue => chipValue * quantity;

  Map<String, dynamic> toJson() => {
        'id': id,
        'sessionId': sessionId,
        'chipTypeId': chipTypeId,
        'chipValue': chipValue,
        'quantity': quantity,
        'fromLocation': fromLocation,
        'toLocation': toLocation,
        'reason': reason,
        'timestamp': timestamp.toIso8601String(),
        'transactionId': transactionId,
        'note': note,
      };

  static ChipMovement fromJson(Map<String, dynamic> j) => ChipMovement(
        id: j['id'] as String,
        sessionId: j['sessionId'] as String?,
        chipTypeId: j['chipTypeId'] as String,
        chipValue: (j['chipValue'] as num).toDouble(),
        quantity: (j['quantity'] as num).toInt(),
        fromLocation: j['fromLocation'] as String,
        toLocation: j['toLocation'] as String,
        reason: j['reason'] as String,
        transactionId: j['transactionId'] as String?,
        note: j['note'] as String?,
        timestamp: DateTime.tryParse(j['timestamp']?.toString() ?? ''),
      );
}
