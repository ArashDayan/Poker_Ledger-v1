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
/// STORAGE
/// typeId 11 — the next free id after 0–10. Lives in its own Hive box
/// so a corrupted identity file cannot take the chip ledger down, and
/// so that box can fail loud (never silently wipe) independently.
@HiveType(typeId: 11)
class PlayerIdentity extends HiveObject {
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

  PlayerIdentity({
    required this.id,
    required this.displayName,
    DateTime? createdAt,
    DateTime? updatedAt,
    this.note,
  })  : createdAt = createdAt ?? DateTime.now(),
        updatedAt = updatedAt ?? DateTime.now();

  Map<String, dynamic> toJson() => {
        'id': id,
        'displayName': displayName,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
        'note': note,
      };

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
      );
}
