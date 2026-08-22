import 'package:hive/hive.dart';

part 'hand.g.dart';

/// Poker pot vs house-banked game. Rake is legal only on [poker];
/// house win is legal only on [houseGame].
@HiveType(typeId: 21)
enum HandKind {
  @HiveField(0)
  poker,
  @HiveField(1)
  houseGame,
}

/// A completed pot is the only persisted state. Voided hands stay in
/// the box so the audit trail is intact; they are never the Last Hand.
@HiveType(typeId: 22)
enum HandStatus {
  @HiveField(0)
  completed,
  @HiveField(1)
  voided,
}

/// One seated player's net chip change on a completed hand.
///
/// [chipChange] is the actual stack change. For the canonical poker
/// pot A loses 4,000 to B and 500 is raked:
///   A.chipChange = -4000
///   B.chipChange = +3500
/// Rake is NOT subtracted from A. A winner is [chipChange] > 0.
class HandResult {
  final String seatPlayerId;
  final String? personId;
  final String nameSnapshot;
  final int seatNumber;
  final double chipChange;
  final bool isWinner;

  const HandResult({
    required this.seatPlayerId,
    this.personId,
    required this.nameSnapshot,
    required this.seatNumber,
    required this.chipChange,
    required this.isWinner,
  });

  bool get isLoser => chipChange < 0;

  Map<String, dynamic> toMap() => {
        'seatPlayerId': seatPlayerId,
        'personId': personId,
        'nameSnapshot': nameSnapshot,
        'seatNumber': seatNumber,
        'chipChange': chipChange,
        'isWinner': isWinner,
      };

  static HandResult fromMap(Map map) {
    final change = (map['chipChange'] as num?)?.toDouble() ?? 0;
    return HandResult(
      seatPlayerId: map['seatPlayerId'] as String? ?? '',
      personId: map['personId'] as String?,
      nameSnapshot: map['nameSnapshot'] as String? ?? '',
      seatNumber: (map['seatNumber'] as num?)?.toInt() ?? 0,
      chipChange: change,
      isWinner: map['isWinner'] as bool? ?? change > 0,
    );
  }
}

/// A completed pot at one table in one session.
///
/// Operational history only. This is NOT a second P/L engine, NOT a
/// Discount input, NOT a cashier transfer, and NOT a participation
/// close. Money stays on [LedgerTransaction]; chips stay on the
/// movement log. This record stores identity + pot facts.
@HiveType(typeId: 20)
class Hand extends HiveObject {
  @HiveField(0)
  String id;

  @HiveField(1)
  String sessionId;

  @HiveField(2)
  String tableId;

  /// Per-table sequence, starting at 1. Voiding never renumbers.
  @HiveField(3)
  int handNumber;

  @HiveField(4)
  HandKind kind;

  @HiveField(5)
  HandStatus status;

  @HiveField(6)
  DateTime completedAt;

  @HiveField(7)
  String? note;

  /// Chips contested — the sum of chips lost by losers.
  @HiveField(8)
  double potAmount;

  /// Poker-room fee. Always 0 on a house-game hand.
  @HiveField(9)
  double rakeAmount;

  /// House-banked take. Always 0 on a poker hand.
  @HiveField(10)
  double houseWinAmount;

  /// Persisted as a list of maps so no extra typeId is needed.
  @HiveField(11)
  List resultsRaw;

  @HiveField(12)
  String? rakeTransactionId;

  @HiveField(13)
  String? houseWinTransactionId;

  @HiveField(14)
  List chipMovementIds;

  Hand({
    required this.id,
    required this.sessionId,
    required this.tableId,
    required this.handNumber,
    required this.kind,
    this.status = HandStatus.completed,
    DateTime? completedAt,
    this.note,
    required this.potAmount,
    this.rakeAmount = 0,
    this.houseWinAmount = 0,
    List? resultsRaw,
    this.rakeTransactionId,
    this.houseWinTransactionId,
    List? chipMovementIds,
  })  : completedAt = completedAt ?? DateTime.now(),
        resultsRaw = resultsRaw ?? const [],
        chipMovementIds = chipMovementIds ?? const [];

  bool get isVoided => status == HandStatus.voided;

  List<HandResult> get results => [
        for (final row in resultsRaw)
          if (row is Map) HandResult.fromMap(row),
      ];

  set results(List<HandResult> value) {
    resultsRaw = [for (final r in value) r.toMap()];
  }

  List<String> get movementIds => [
        for (final id in chipMovementIds)
          if (id is String && id.isNotEmpty) id,
      ];

  HandResult? resultFor(String seatPlayerId) {
    for (final r in results) {
      if (r.seatPlayerId == seatPlayerId) return r;
    }
    return null;
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'sessionId': sessionId,
        'tableId': tableId,
        'handNumber': handNumber,
        'kind': kind.index,
        'status': status.index,
        'completedAt': completedAt.toIso8601String(),
        'note': note,
        'potAmount': potAmount,
        'rakeAmount': rakeAmount,
        'houseWinAmount': houseWinAmount,
        'results': [for (final r in results) r.toMap()],
        'rakeTransactionId': rakeTransactionId,
        'houseWinTransactionId': houseWinTransactionId,
        'chipMovementIds': movementIds,
      };

  static Hand fromJson(Map<String, dynamic> j) {
    final kindIndex = (j['kind'] as num?)?.toInt() ?? 0;
    final statusIndex = (j['status'] as num?)?.toInt() ?? 0;
    final rawResults = j['results'] as List? ?? const [];
    final rawMoves = j['chipMovementIds'] as List? ?? const [];
    return Hand(
      id: j['id'] as String,
      sessionId: j['sessionId'] as String,
      tableId: j['tableId'] as String,
      handNumber: (j['handNumber'] as num?)?.toInt() ?? 0,
      kind: HandKind.values[kindIndex.clamp(0, HandKind.values.length - 1)],
      status: HandStatus
          .values[statusIndex.clamp(0, HandStatus.values.length - 1)],
      completedAt: DateTime.tryParse(j['completedAt']?.toString() ?? '') ??
          DateTime.now(),
      note: j['note'] as String?,
      potAmount: (j['potAmount'] as num?)?.toDouble() ?? 0,
      rakeAmount: (j['rakeAmount'] as num?)?.toDouble() ?? 0,
      houseWinAmount: (j['houseWinAmount'] as num?)?.toDouble() ?? 0,
      resultsRaw: [
        for (final row in rawResults)
          if (row is Map) Map<String, dynamic>.from(row),
      ],
      rakeTransactionId: j['rakeTransactionId'] as String?,
      houseWinTransactionId: j['houseWinTransactionId'] as String?,
      chipMovementIds: [
        for (final id in rawMoves)
          if (id != null) id.toString(),
      ],
    );
  }
}
