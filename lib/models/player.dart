import 'package:hive/hive.dart';
import 'enums.dart';

part 'player.g.dart';

@HiveType(typeId: 4)
class Player extends HiveObject {
  @HiveField(0)
  String id;

  @HiveField(1)
  String sessionId;

  @HiveField(2)
  String name;

  @HiveField(3)
  String? photoPath;

  @HiveField(4)
  int seatNumber;

  @HiveField(5)
  List<PlayerTag> tags;

  @HiveField(6)
  bool isActive; // false once fully cashed out / left the table

  @HiveField(7)
  bool isFavorite;

  @HiveField(8)
  DateTime joinedAt;

  /// A reference signature captured from the player themselves when they
  /// were seated, stored as base64 PNG.
  ///
  /// This is the *specimen* — it is never used to authorise anything on
  /// its own. Its only job is to give the host something to compare a
  /// disputed transaction signature against later ("is this really the
  /// same hand that signed for the buy-in?"). Optional: a regular the
  /// host trusts can be seated without one, and the app never blocks on
  /// its absence.
  @HiveField(9)
  String? sampleSignatureBase64;

  /// When the specimen above was captured, so a host can tell a fresh
  /// sample from one taken months ago.
  @HiveField(10)
  DateTime? sampleSignatureAt;

  /// Which table within the session this player is seated at.
  ///
  /// Null means "the session's first/main table" — that is what every
  /// player saved before multi-table support has stored, so existing
  /// sessions keep working untouched and simply behave as a one-table
  /// game. Seat numbers are unique *per table*, not per session, so
  /// Table 1 Seat 3 and Table 2 Seat 3 are two different people.
  @HiveField(11)
  String? tableId;

  /// Finishing position in a tournament (1 = winner). Null while the
  /// player is still in. Cash games never set this.
  @HiveField(12)
  int? finishPosition;

  /// When the player busted out of a tournament.
  @HiveField(13)
  DateTime? eliminatedAt;

  /// Number of tournament add-ons taken (rebuys are counted from the
  /// ledger like any other transaction; add-ons are their own thing).
  @HiveField(14)
  int addOnCount;

  /// Second reference signature.
  ///
  /// A single specimen is a weak baseline: everyone's signature varies
  /// run to run, so one sample makes normal variation look suspicious.
  /// Two samples let the app measure how much this person's own
  /// signature naturally differs, and judge a new one against that.
  @HiveField(15)
  String? sampleSignature2Base64;

  @HiveField(16)
  DateTime? sampleSignature2At;

  /// Permanent identity of the human sitting in this seat.
  ///
  /// Null on every player saved before Step 1, and that is a real
  /// state — not "settled" and not "owes nothing". A missing personId
  /// means this seat has not been linked yet. Financial totals for an
  /// unlinked seat must later read as "Not recorded", never 0.
  ///
  /// Additive HiveField 17: old records load with null and keep working.
  /// Names stay display-only; this id is what later money attaches to.
  @HiveField(17)
  String? personId;

  Player({
    required this.id,
    required this.sessionId,
    required this.name,
    this.photoPath,
    required this.seatNumber,
    List<PlayerTag>? tags,
    this.isActive = true,
    this.isFavorite = false,
    DateTime? joinedAt,
    this.sampleSignatureBase64,
    this.sampleSignatureAt,
    this.tableId,
    this.finishPosition,
    this.eliminatedAt,
    this.addOnCount = 0,
    this.sampleSignature2Base64,
    this.sampleSignature2At,
    this.personId,
  })  : tags = tags ?? [],
        joinedAt = joinedAt ?? DateTime.now();

  Map<String, dynamic> toJson() => {
        'id': id,
        'sessionId': sessionId,
        'name': name,
        'photoPath': photoPath,
        'seatNumber': seatNumber,
        'tags': tags.map((t) => t.index).toList(),
        'isActive': isActive,
        'isFavorite': isFavorite,
        'joinedAt': joinedAt.toIso8601String(),
        'sampleSignatureBase64': sampleSignatureBase64,
        'sampleSignatureAt': sampleSignatureAt?.toIso8601String(),
        'tableId': tableId,
        'finishPosition': finishPosition,
        'eliminatedAt': eliminatedAt?.toIso8601String(),
        'addOnCount': addOnCount,
        'sampleSignature2Base64': sampleSignature2Base64,
        'sampleSignature2At': sampleSignature2At?.toIso8601String(),
        'personId': personId,
      };

  static Player fromJson(Map<String, dynamic> json) => Player(
        id: json['id'] as String,
        sessionId: json['sessionId'] as String,
        name: json['name'] as String,
        photoPath: json['photoPath'] as String?,
        seatNumber: json['seatNumber'] as int,
        tags: (json['tags'] as List? ?? [])
            .map((i) => PlayerTag.values[i as int])
            .toList(),
        isActive: json['isActive'] as bool? ?? true,
        isFavorite: json['isFavorite'] as bool? ?? false,
        joinedAt: json['joinedAt'] == null
            ? DateTime.now()
            : DateTime.parse(json['joinedAt'] as String),
        sampleSignatureBase64: json['sampleSignatureBase64'] as String?,
        sampleSignatureAt: json['sampleSignatureAt'] == null
            ? null
            : DateTime.parse(json['sampleSignatureAt'] as String),
        tableId: json['tableId'] as String?,
        finishPosition: json['finishPosition'] as int?,
        eliminatedAt: json['eliminatedAt'] == null
            ? null
            : DateTime.parse(json['eliminatedAt'] as String),
        addOnCount: json['addOnCount'] as int? ?? 0,
        sampleSignature2Base64: json['sampleSignature2Base64'] as String?,
        sampleSignature2At: json['sampleSignature2At'] == null
            ? null
            : DateTime.parse(json['sampleSignature2At'] as String),
        personId: json['personId'] as String?,
      );

  /// Whether this player has busted out of a tournament.
  bool get isEliminated => finishPosition != null;

  /// Whether a reference signature exists to compare against.
  bool get hasSampleSignature =>
      sampleSignatureBase64 != null && sampleSignatureBase64!.isNotEmpty;

  bool get hasSecondSample =>
      sampleSignature2Base64 != null && sampleSignature2Base64!.isNotEmpty;

  /// Every stored specimen, for comparison.
  List<String> get signatureSamples => [
        if (hasSampleSignature) sampleSignatureBase64!,
        if (hasSecondSample) sampleSignature2Base64!,
      ];
}
