import 'package:hive/hive.dart';

part 'player_identity.g.dart';

/// Permanent identity of one human across every session they sit in.
///
/// WHY THIS EXISTS
/// A [Player] row is one seat in one session. The same person has a
/// new row every night, so a name on a seat cannot be a financial
/// account. [PlayerIdentity.id] is the `personId` that later financial
/// events will attach to. Names are display only — two people may
/// share a name, and one person may be spelled differently next week.
///
/// SCOPE (Step 1)
/// This type holds NO money. No balance, no credit, no front money,
/// no currency. Those arrive in Step 2 as a separate Financial Ledger
/// that reads `personId` and never writes back here.
///
/// SCOPE (ICR-01 — Player Master fields)
/// [playerNumber], [firstName], [lastName], [idNumber],
/// [sampleSignatureBase64], [sampleSignature2Base64] and
/// [creditLimitMinor] are master-record attributes: they identify and
/// describe the person, they do not move money. [creditLimitMinor] is
/// a POLICY INPUT for the future marker workflow (ICR-06) — it is
/// stored here, but no engine reads it yet, and the current legacy
/// deposit-backed marker flow is untouched.
///
/// STORAGE
/// typeId 11 — the next free id after 0–10. Lives in its own Hive box
/// so a corrupted identity file cannot take the chip ledger down, and
/// so that box can fail loud (never silently wipe) independently.
///
/// ICR-01 EXTENSION CONTRACT
/// Fields 0–4 are frozen forever. Fields 5–11 were added additively:
/// every record written before ICR-01 loads with `playerNumber == 0`
/// (unassigned), empty names and zero credit limit, and
/// [PlayerIdentityService.migrateMasterFields] backfills the missing
/// values. New fields must only ever be appended after 11 — typeId 16
/// remains reserved and no identity data may move to a new typeId.
@HiveType(typeId: 11)
class PlayerIdentity extends HiveObject {
  /// The first number ever handed out. Numbering is people-facing
  /// (membership-card style), so it starts at 101, not at 1.
  static const int firstPlayerNumber = 101;

  /// The permanent id. This is [Player.personId] when a seat is linked.
  @HiveField(0)
  String id;

  /// Most recently confirmed spelling. Never a unique key.
  @HiveField(1)
  String displayName;

  @HiveField(2)
  DateTime createdAt;

  @HiveField(3)
  DateTime updatedAt;

  /// Optional banker note about the person (not a financial note).
  @HiveField(4)
  String? note;

  /// Permanent, human-memorable membership number. Assigned once from
  /// [firstPlayerNumber] upward and never reused, never renumbered.
  ///
  /// `0` means "not assigned yet" — that is every identity stored
  /// before ICR-01 until [PlayerIdentityService.migrateMasterFields]
  /// runs. Anything below [firstPlayerNumber] is treated as
  /// unassigned, so a corrupted or imported small value is healed by
  /// migration instead of colliding with real numbers.
  @HiveField(5)
  int playerNumber;

  /// Given name. Best-effort split from [displayName]; the banker may
  /// correct it. Display only — never a lookup key, never used to
  /// merge people. May be empty when unknown.
  @HiveField(6)
  String firstName;

  /// Family name. Same rules as [firstName].
  @HiveField(7)
  String lastName;

  /// Optional government/club ID reference. Free text, display only.
  /// Two people may share a name; an ID number is how a host tells
  /// them apart on paper. The app never validates or dedupes on it —
  /// validating it would legalise merges, which are forbidden.
  @HiveField(8)
  String? idNumber;

  /// Person-level reference signature (base64 PNG), same role as the
  /// per-seat specimen on [Player.sampleSignatureBase64] — a baseline
  /// to compare a disputed signature against, never an authorisation.
  ///
  /// Filled from the oldest linked seat by migration ONLY while empty;
  /// a specimen already stored here is never overwritten and the seat
  /// copies are never deleted (the seat specimen remains the "as
  /// seated on that night" record).
  @HiveField(9)
  String? sampleSignatureBase64;

  /// Second person-level specimen — see [Player.sampleSignature2Base64]
  /// for why two samples beat one.
  @HiveField(10)
  String? sampleSignature2Base64;

  /// Credit limit in MINOR currency units (same convention as
  /// `FinancialEvent.amountMinor` / `MoneyUnits`). Default 0 = no
  /// credit line. Read by the future marker workflow (ICR-06); no
  /// engine consumes it before that ICR, and writing it here changes
  /// no accounting today.
  @HiveField(11)
  int creditLimitMinor;

  PlayerIdentity({
    required this.id,
    required this.displayName,
    DateTime? createdAt,
    DateTime? updatedAt,
    this.note,
    this.playerNumber = 0,
    this.firstName = '',
    this.lastName = '',
    this.idNumber,
    this.sampleSignatureBase64,
    this.sampleSignature2Base64,
    this.creditLimitMinor = 0,
  })  : createdAt = createdAt ?? DateTime.now(),
        updatedAt = updatedAt ?? DateTime.now();

  /// Whether this identity has been handed its permanent number.
  bool get hasPlayerNumber => playerNumber >= firstPlayerNumber;

  /// Whether any person-level specimen exists.
  bool get hasSpecimen =>
      (sampleSignatureBase64 != null && sampleSignatureBase64!.isNotEmpty) ||
      (sampleSignature2Base64 != null && sampleSignature2Base64!.isNotEmpty);

  /// Best-effort split of a free-typed display name into
  /// (first, last). First whitespace-separated token is the given
  /// name, everything after it is the family name. A single word is a
  /// given name with no family name. Deliberately naive: guessing
  /// smarter (honorifics, multiword family names) corrupts more
  /// often than it helps, and the banker can correct the fields —
  /// they are display data, never identity keys.
  static ({String first, String last}) splitDisplayName(String displayName) {
    final compact = displayName.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (compact.isEmpty) return (first: '', last: '');
    final space = compact.indexOf(' ');
    if (space < 0) return (first: compact, last: '');
    return (
      first: compact.substring(0, space),
      last: compact.substring(space + 1),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'displayName': displayName,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
        'note': note,
        'playerNumber': playerNumber,
        'firstName': firstName,
        'lastName': lastName,
        'idNumber': idNumber,
        'sampleSignatureBase64': sampleSignatureBase64,
        'sampleSignature2Base64': sampleSignature2Base64,
        'creditLimitMinor': creditLimitMinor,
      };

  /// Tolerant in both directions of Backup v8: a backup written before
  /// ICR-01 has none of the new keys (defaults apply, migration
  /// backfills), and a backup written after ICR-01 still imports into
  /// an older build because unknown keys are ignored there.
  static PlayerIdentity fromJson(Map<String, dynamic> json) => PlayerIdentity(
        id: json['id'] as String,
        displayName: json['displayName'] as String? ?? '',
        createdAt: json['createdAt'] == null
            ? DateTime.now()
            : DateTime.parse(json['createdAt'] as String),
        updatedAt: json['updatedAt'] == null
            ? DateTime.now()
            : DateTime.parse(json['updatedAt'] as String),
        note: json['note'] as String?,
        playerNumber: (json['playerNumber'] as num?)?.toInt() ?? 0,
        firstName: json['firstName'] as String? ?? '',
        lastName: json['lastName'] as String? ?? '',
        idNumber: json['idNumber'] as String?,
        sampleSignatureBase64: json['sampleSignatureBase64'] as String?,
        sampleSignature2Base64: json['sampleSignature2Base64'] as String?,
        creditLimitMinor: (json['creditLimitMinor'] as num?)?.toInt() ?? 0,
      );
}
