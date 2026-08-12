import 'package:hive/hive.dart';

import 'enums.dart';

part 'financial_event.g.dart';

/// Converts between display (major) units and stored integer minor units.
///
/// Approved exponents: USD = 2 (cents), Toman = 0 (the unit itself).
/// A mis-set exponent is a 100× error, so this is the only conversion
/// the Financial Ledger is allowed to use. Chip Ledger doubles are
/// never fed through here.
class MoneyUnits {
  MoneyUnits._();

  static int exponent(AppCurrency currency) =>
      currency == AppCurrency.usd ? 2 : 0;

  static int factor(AppCurrency currency) =>
      currency == AppCurrency.usd ? 100 : 1;

  /// [major] must be a positive finite amount. Toman 0.4 and USD 0.001
  /// both round to 0 minor units and are refused — a stored 0 would
  /// look like a real event that did nothing.
  static int toMinor(AppCurrency currency, double major) {
    if (!major.isFinite || major <= 0) {
      throw ArgumentError('Amount must be a positive finite number.');
    }
    final minor = (major * factor(currency)).round();
    if (minor <= 0) {
      throw ArgumentError(
        'Amount is too small to store in ${currency.name} minor units.',
      );
    }
    return minor;
  }

  static double toMajor(AppCurrency currency, int minor) =>
      minor / factor(currency);
}

/// What kind of real-money event this is.
///
/// Byte mapping is permanent — never renumber.
///
///   0 cashInForChips      completed exchange; does NOT affect balance
///   1 cashOutForChips     completed exchange; does NOT affect balance
///   2 creditIssued        player received chips now, pays later  (+)
///   3 creditRepaid        player pays down credit               (−)
///   4 cashOutUnbacked     banker paid cash the player had not covered (+)
///   5 frontMoneyIn        banker is holding the player's cash   (−)
///   6 frontMoneyOut       that cash is returned to the player   (+)
///   7 adjustment          signed correction; reason mandatory   (±)
///   8 rebateGranted       loss rebate given (cash or chips)     (0)
///   9 rebateRecovered     grant portion returned to the house   (0)
///
/// Types 8 and 9 never enter Outstanding Balance. They are the
/// Discount journal. Marker is not a separate type: it is Credit
/// plus a signature.
@HiveType(typeId: 13)
enum FinancialEventType {
  @HiveField(0)
  cashInForChips,
  @HiveField(1)
  cashOutForChips,
  @HiveField(2)
  creditIssued,
  @HiveField(3)
  creditRepaid,
  @HiveField(4)
  cashOutUnbacked,
  @HiveField(5)
  frontMoneyIn,
  @HiveField(6)
  frontMoneyOut,
  @HiveField(7)
  adjustment,
  @HiveField(8)
  rebateGranted,
  @HiveField(9)
  rebateRecovered,
}

/// How the money physically moved, when the banker recorded it.
/// Optional. Never used in the balance formula.
@HiveType(typeId: 14)
enum PaymentMethod {
  @HiveField(0)
  cash,
  @HiveField(1)
  bankTransfer,
  @HiveField(2)
  other,
}

/// One append-only real-money event between the Banker and one person.
///
/// SCOPE
/// This is the Financial Ledger. It never reads the Chip Ledger, never
/// reads Buy-in/Rebuy as proof of payment, and never stores a running
/// balance. Outstanding Balance is always derived.
///
/// typeId 12 — reserved in Step 0. Lives in `financial_events_box`,
/// which opens fail-loud and is never silently wiped.
@HiveType(typeId: 12)
class FinancialEvent extends HiveObject {
  @HiveField(0)
  String id;

  /// Permanent identity. Names are display only.
  @HiveField(1)
  String personId;

  /// Stored on every event. Never inferred later from Settings (D-1).
  @HiveField(2)
  AppCurrency currency;

  @HiveField(3)
  FinancialEventType type;

  /// Always positive. Direction comes from [type] (and [adjustmentSign]
  /// for adjustments).
  @HiveField(4)
  int amountMinor;

  @HiveField(5)
  DateTime occurredAt;

  @HiveField(6)
  DateTime createdAt;

  @HiveField(7)
  bool isBackdated;

  /// Optional. Financial events may happen outside a session, and must
  /// remain writable after a session has ended (C-1).
  @HiveField(8)
  String? sessionId;

  @HiveField(9)
  PaymentMethod? paymentMethod;

  @HiveField(10)
  String? note;

  @HiveField(11)
  String? signatureBase64;

  /// Audit-only pointer at a Chip Ledger row. MUST NEVER enter the
  /// balance formula. A buy-in id here does not mean the player paid.
  @HiveField(12)
  String? linkedTransactionId;

  /// If set, this event is a reversal of that id. The original is left
  /// untouched (append-only). Reversal-of-reversal is refused.
  @HiveField(13)
  String? reversesEventId;

  /// +1 or −1. Required when [type] is [FinancialEventType.adjustment].
  @HiveField(14)
  int? adjustmentSign;

  /// Mandatory on adjustment. Optional elsewhere.
  @HiveField(15)
  String? reason;

  /// Eligible own-cash loss (minor units) this rebate grant consumed.
  /// Null on every type except [FinancialEventType.rebateGranted].
  @HiveField(16)
  int? baseLossMinor;

  /// True when the grant was issued as chips (ChipMovement.lossRebate).
  /// False/null = cash. Never means the chips were a Buy-in.
  @HiveField(17)
  bool? grantedAsChips;

  FinancialEvent({
    required this.id,
    required this.personId,
    required this.currency,
    required this.type,
    required this.amountMinor,
    required this.occurredAt,
    required this.createdAt,
    this.isBackdated = false,
    this.sessionId,
    this.paymentMethod,
    this.note,
    this.signatureBase64,
    this.linkedTransactionId,
    this.reversesEventId,
    this.adjustmentSign,
    this.reason,
    this.baseLossMinor,
    this.grantedAsChips,
  });

  bool get isReversal =>
      reversesEventId != null && reversesEventId!.isNotEmpty;

  double get amountMajor => MoneyUnits.toMajor(currency, amountMinor);

  Map<String, dynamic> toJson() => {
        'id': id,
        'personId': personId,
        'currency': currency.index,
        'type': type.index,
        'amountMinor': amountMinor,
        'occurredAt': occurredAt.toIso8601String(),
        'createdAt': createdAt.toIso8601String(),
        'isBackdated': isBackdated,
        'sessionId': sessionId,
        'paymentMethod': paymentMethod?.index,
        'note': note,
        'signatureBase64': signatureBase64,
        'linkedTransactionId': linkedTransactionId,
        'reversesEventId': reversesEventId,
        'adjustmentSign': adjustmentSign,
        'reason': reason,
        'baseLossMinor': baseLossMinor,
        'grantedAsChips': grantedAsChips,
      };

  static FinancialEvent fromJson(Map<String, dynamic> json) {
    final typeIndex = json['type'] as int;
    if (typeIndex < 0 || typeIndex >= FinancialEventType.values.length) {
      throw FormatException('Unknown FinancialEventType index $typeIndex');
    }
    final currencyIndex = json['currency'] as int;
    if (currencyIndex < 0 || currencyIndex >= AppCurrency.values.length) {
      throw FormatException('Unknown AppCurrency index $currencyIndex');
    }
    final methodIndex = json['paymentMethod'] as int?;
    return FinancialEvent(
      id: json['id'] as String,
      personId: json['personId'] as String,
      currency: AppCurrency.values[currencyIndex],
      type: FinancialEventType.values[typeIndex],
      amountMinor: json['amountMinor'] as int,
      occurredAt: DateTime.parse(json['occurredAt'] as String),
      createdAt: DateTime.parse(json['createdAt'] as String),
      isBackdated: json['isBackdated'] as bool? ?? false,
      sessionId: json['sessionId'] as String?,
      paymentMethod: methodIndex == null
          ? null
          : PaymentMethod.values[methodIndex],
      note: json['note'] as String?,
      signatureBase64: json['signatureBase64'] as String?,
      linkedTransactionId: json['linkedTransactionId'] as String?,
      reversesEventId: json['reversesEventId'] as String?,
      adjustmentSign: json['adjustmentSign'] as int?,
      reason: json['reason'] as String?,
      baseLossMinor: json['baseLossMinor'] as int?,
      grantedAsChips: json['grantedAsChips'] as bool?,
    );
  }
}
