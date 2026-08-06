import 'package:hive/hive.dart';
export 'enums.dart';
import 'enums.dart';

part 'transaction.g.dart';

/// A single, immutable-once-signed money movement.
/// Every buy-in, rebuy and cash-out MUST carry a host signature so the
/// audit log can never be disputed after the fact.
@HiveType(typeId: 5)
class LedgerTransaction extends HiveObject {
  @HiveField(0)
  String id;

  @HiveField(1)
  String sessionId;

  @HiveField(2)
  String? playerId; // null for rake collection / cash drop (table-level)

  @HiveField(3)
  TransactionType type;

  @HiveField(4)
  double amount;

  @HiveField(5)
  DateTime timestamp;

  /// PNG signature bytes, base64-encoded, captured from the host at the
  /// moment of the transaction. Mandatory for buyIn/rebuy/cashOut.
  @HiveField(6)
  String? hostSignatureBase64;

  @HiveField(7)
  String? note;

  @HiveField(8)
  String? voiceNotePath;

  @HiveField(9)
  bool isVoided; // used by undo, keeps the audit trail instead of deleting

  /// Set whenever a banker edits the amount/note of an already-recorded
  /// transaction (see SessionService.updateTransaction). The original
  /// timestamp is preserved; this just marks the record as amended so the
  /// audit log never hides that a change happened.
  @HiveField(10)
  bool isEdited;

  @HiveField(11)
  DateTime? editedAt;

  /// True when this transaction was recorded or edited while the player
  /// was already marked settled/inactive — meaning the signature captured
  /// could not have been the player's own. This never blocks the action
  /// (a banker must always be able to fix a mistake after someone has
  /// left), but it must stay visible in the audit log so anyone reviewing
  /// the report later can see the difference between a player's own
  /// confirmation and a banker's after-the-fact attestation.
  @HiveField(12)
  bool signedWhileAbsent;

  /// Which table inside the session this transaction happened at.
  ///
  /// Null means "the session's first/main table" — that is what every
  /// transaction recorded before multi-table support has stored, so
  /// existing sessions keep working and simply behave as a one-table
  /// game. Table-level rows (rake, cash drop) carry the table they were
  /// taken at so a per-table timeline can attribute them correctly.
  ///
  /// IMPORTANT: this is for FILTERING AND DISPLAY ONLY. The settlement
  /// engine deliberately ignores it — a host running three tables
  /// settles one bank at the end of the night, so every balance figure
  /// stays session-wide exactly as before.
  @HiveField(13)
  String? tableId;

  LedgerTransaction({
    required this.id,
    required this.sessionId,
    this.playerId,
    required this.type,
    required this.amount,
    DateTime? timestamp,
    this.hostSignatureBase64,
    this.note,
    this.voiceNotePath,
    this.isVoided = false,
    this.isEdited = false,
    this.editedAt,
    this.tableId,
    this.signedWhileAbsent = false,
  }) : timestamp = timestamp ?? DateTime.now();

  bool get requiresSignature =>
      type == TransactionType.buyIn ||
      type == TransactionType.rebuy ||
      type == TransactionType.cashOut;

  Map<String, dynamic> toJson() => {
        'id': id,
        'sessionId': sessionId,
        'playerId': playerId,
        'type': type.index,
        'amount': amount,
        'timestamp': timestamp.toIso8601String(),
        'hostSignatureBase64': hostSignatureBase64,
        'note': note,
        'voiceNotePath': voiceNotePath,
        'isVoided': isVoided,
        'isEdited': isEdited,
        'editedAt': editedAt?.toIso8601String(),
        'signedWhileAbsent': signedWhileAbsent,
        'tableId': tableId,
      };

  static LedgerTransaction fromJson(Map<String, dynamic> json) => LedgerTransaction(
        id: json['id'] as String,
        sessionId: json['sessionId'] as String,
        playerId: json['playerId'] as String?,
        type: TransactionType.values[json['type'] as int],
        amount: (json['amount'] as num).toDouble(),
        timestamp: DateTime.parse(json['timestamp'] as String),
        hostSignatureBase64: json['hostSignatureBase64'] as String?,
        note: json['note'] as String?,
        voiceNotePath: json['voiceNotePath'] as String?,
        isVoided: json['isVoided'] as bool? ?? false,
        isEdited: json['isEdited'] as bool? ?? false,
        editedAt: json['editedAt'] == null ? null : DateTime.parse(json['editedAt'] as String),
        signedWhileAbsent: json['signedWhileAbsent'] as bool? ?? false,
        tableId: json['tableId'] as String?,
      );
}
