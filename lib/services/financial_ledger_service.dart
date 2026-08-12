import 'package:uuid/uuid.dart';

import '../models/enums.dart';
import '../models/financial_event.dart';
import 'hive_service.dart';
import 'player_identity_service.dart';

const _uuid = Uuid();

/// Validation / invariant failure on the Financial Ledger.
///
/// Separate from [SessionEndedException] on purpose: this service must
/// never call or catch session-lock errors. A closed session is not a
/// reason to refuse a financial write (C-1).
class FinancialLedgerException implements Exception {
  final String message;
  FinancialLedgerException(this.message);
  @override
  String toString() => message;
}

/// Derived outstanding balance for one `(personId, currency)`.
///
/// Never stored. Positive = player owes the banker. Negative = banker
/// holds the player's money. Zero with [recorded] = settled.
///
/// [recorded] is false when this pair has no financial events at all.
/// That is "Not recorded", never a numeric 0 — a missing ledger is not
/// the same as a settled one.
class OutstandingBalance {
  final String personId;
  final AppCurrency currency;
  final int amountMinor;
  final bool recorded;

  const OutstandingBalance({
    required this.personId,
    required this.currency,
    required this.amountMinor,
    required this.recorded,
  });

  factory OutstandingBalance.notRecorded(
    String personId,
    AppCurrency currency,
  ) =>
      OutstandingBalance(
        personId: personId,
        currency: currency,
        amountMinor: 0,
        recorded: false,
      );

  double get amountMajor => MoneyUnits.toMajor(currency, amountMinor);

  bool get isNotRecorded => !recorded;

  /// Player owes the banker.
  bool get playerOwes => recorded && amountMinor > 0;

  /// Banker is holding the player's cash (front money, overpayment, …).
  bool get bankerHolds => recorded && amountMinor < 0;

  bool get isSettled => recorded && amountMinor == 0;
}

/// Read-only view of one person's Financial Ledger.
///
/// Derived on every call. There is no stored balance field anywhere.
class PlayerAccount {
  final String personId;
  final String displayName;

  /// One entry per currency that actually has events. Never netted
  /// across currencies.
  final List<OutstandingBalance> balances;

  /// Newest [FinancialEvent.occurredAt] first. Includes reversed events
  /// and reversals — the history is the point.
  final List<FinancialEvent> events;

  const PlayerAccount({
    required this.personId,
    required this.displayName,
    required this.balances,
    required this.events,
  });

  bool get hasHistory => events.isNotEmpty;
}

/// Append-only Financial Ledger.
///
/// HARD RULES
///   * Never call [SessionService.assertSessionActive]. Closed sessions
///     still accept financial writes (C-1).
///   * Never read Chip Ledger totals, Buy-in, Rebuy or cash-out as
///     evidence of payment.
///   * Never store a balance. Always derive it.
///   * Never net two currencies together.
///   * Never include [FinancialEvent.linkedTransactionId] in the math.
///   * Never silently merge identities.
///   * Amounts are stored as positive integer minor units.
///   * Corrections are a new reversal or a new adjustment. Existing
///     events are not edited or deleted.
///
/// This file does not import session_service.dart. That is deliberate.
class FinancialLedgerService {
  FinancialLedgerService._();

  static bool get _boxOpen {
    try {
      HiveService.financialEvents;
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Records a new financial event. Does not look at session status.
  static Future<FinancialEvent> record({
    required String personId,
    required AppCurrency currency,
    required FinancialEventType type,
    required double amount,
    DateTime? occurredAt,
    String? sessionId,
    PaymentMethod? paymentMethod,
    String? note,
    String? signatureBase64,
    String? linkedTransactionId,
    int? adjustmentSign,
    String? reason,
    int? baseLossMinor,
    bool? grantedAsChips,
  }) async {
    _assertBoxOpen();
    _assertKnownPerson(personId);
    final amountMinor = MoneyUnits.toMinor(currency, amount);

    if (type == FinancialEventType.adjustment) {
      final trimmed = reason?.trim() ?? '';
      if (trimmed.isEmpty) {
        throw FinancialLedgerException(
          'An adjustment requires a reason.',
        );
      }
      if (adjustmentSign != 1 && adjustmentSign != -1) {
        throw FinancialLedgerException(
          'An adjustment requires a sign of +1 (player owes more) or '
          '−1 (banker holds more / player owes less).',
        );
      }
      reason = trimmed;
    } else {
      adjustmentSign = null;
    }

    final createdAt = DateTime.now();
    final occurred = occurredAt ?? createdAt;
    final backdated = occurredAt != null &&
        occurred.difference(createdAt).abs() > const Duration(seconds: 1);

    final event = FinancialEvent(
      id: _uuid.v4(),
      personId: personId,
      currency: currency,
      type: type,
      amountMinor: amountMinor,
      occurredAt: occurred,
      createdAt: createdAt,
      isBackdated: backdated,
      sessionId: sessionId,
      paymentMethod: paymentMethod,
      note: note,
      signatureBase64: signatureBase64,
      linkedTransactionId: linkedTransactionId,
      adjustmentSign: adjustmentSign,
      reason: reason,
      baseLossMinor: baseLossMinor,
      grantedAsChips: grantedAsChips,
    );
    await HiveService.financialEvents.put(event.id, event);
    return event;
  }

  /// Appends a reversal. The original event is left exactly as stored.
  ///
  /// Refuses if the target is itself a reversal, or has already been
  /// reversed. The new event copies the original type so history can
  /// say "reversal of credit issued" without a second type id.
  static Future<FinancialEvent> reverse(
    String eventId, {
    String? note,
    String? signatureBase64,
    String? reason,
  }) async {
    _assertBoxOpen();
    final original = HiveService.financialEvents.get(eventId);
    if (original == null) {
      throw FinancialLedgerException('Cannot reverse: event not found.');
    }
    if (original.isReversal) {
      throw FinancialLedgerException(
        'Cannot reverse a reversal. Record a new event instead.',
      );
    }
    if (_isReversed(original.id)) {
      throw FinancialLedgerException(
        'This event has already been reversed.',
      );
    }

    final now = DateTime.now();
    final event = FinancialEvent(
      id: _uuid.v4(),
      personId: original.personId,
      currency: original.currency,
      type: original.type,
      amountMinor: original.amountMinor,
      occurredAt: now,
      createdAt: now,
      isBackdated: false,
      sessionId: original.sessionId,
      note: note,
      signatureBase64: signatureBase64,
      reversesEventId: original.id,
      adjustmentSign: original.adjustmentSign,
      reason: reason,
    );
    await HiveService.financialEvents.put(event.id, event);
    return event;
  }

  /// Derived outstanding balance for one person in one currency.
  ///
  /// ```
  /// Σ creditIssued
  /// + Σ cashOutUnbacked
  /// + Σ frontMoneyOut
  /// − Σ creditRepaid
  /// − Σ frontMoneyIn
  /// ± Σ adjustment
  /// ```
  ///
  /// `cashInForChips` and `cashOutForChips` contribute 0.
  /// Reversed events and reversal events are excluded.
  /// [FinancialEvent.linkedTransactionId] is ignored.
  static OutstandingBalance balance(String personId, AppCurrency currency) {
    final events = _eventsFor(personId, currency: currency);
    if (events.isEmpty) {
      return OutstandingBalance.notRecorded(personId, currency);
    }
    final reversed = _reversedIds(events);
    var minor = 0;
    for (final e in events) {
      minor += _contribution(e, reversed);
    }
    return OutstandingBalance(
      personId: personId,
      currency: currency,
      amountMinor: minor,
      recorded: true,
    );
  }

  /// Every event for this person, newest first. Optional currency filter.
  static List<FinancialEvent> eventsFor(
    String personId, {
    AppCurrency? currency,
  }) {
    final list = _eventsFor(personId, currency: currency);
    list.sort((a, b) => b.occurredAt.compareTo(a.occurredAt));
    return list;
  }

  /// Remaining deposit (front money still held) in minor units.
  ///
  /// Derived only from frontMoneyIn − frontMoneyOut. Reversed events
  /// are excluded. This is NOT Outstanding Balance and is NOT a
  /// Discount/rebate base — cashInForChips is never included.
  static int depositHeldMinor(String personId, AppCurrency currency) {
    final events = _eventsFor(personId, currency: currency);
    if (events.isEmpty) return 0;
    final reversed = _reversedIds(events);
    var minor = 0;
    for (final e in events) {
      if (e.isReversal || reversed.contains(e.id)) continue;
      switch (e.type) {
        case FinancialEventType.frontMoneyIn:
          minor += e.amountMinor;
          break;
        case FinancialEventType.frontMoneyOut:
          minor -= e.amountMinor;
          break;
        default:
          break;
      }
    }
    return minor < 0 ? 0 : minor;
  }

  /// Same figure as [depositHeldMinor], in display units.
  static double depositHeldMajor(String personId, AppCurrency currency) =>
      MoneyUnits.toMajor(currency, depositHeldMinor(personId, currency));

  /// Events recorded against [sessionId], newest first.
  ///
  /// A missing or empty sessionId matches nothing — events without a
  /// session stay off the session settlement view.
  static List<FinancialEvent> eventsForSession(
    String sessionId, {
    String? personId,
    AppCurrency? currency,
  }) {
    final list = _eventsInSession(sessionId,
        personId: personId, currency: currency);
    list.sort((a, b) => b.occurredAt.compareTo(a.occurredAt));
    return list;
  }

  /// Every event whose [FinancialEvent.linkedTransactionId] is [transactionId].
  /// Includes reversed originals and does not include reversal rows
  /// (reversals do not copy the link).
  static List<FinancialEvent> eventsLinkedTo(String transactionId) {
    if (!_boxOpen || transactionId.isEmpty) return const [];
    return HiveService.financialEvents.values
        .where((e) => e.linkedTransactionId == transactionId)
        .toList();
  }

  /// Linked events that still affect derived figures — not reversals
  /// and not already reversed.
  static List<FinancialEvent> activeEventsLinkedTo(String transactionId) {
    final linked = eventsLinkedTo(transactionId);
    if (linked.isEmpty) return const [];
    final reversed = _reversedIds(HiveService.financialEvents.values);
    return linked
        .where((e) => !e.isReversal && !reversed.contains(e.id))
        .toList();
  }

  /// Appends a reversal for each still-active event linked to
  /// [transactionId]. Never deletes. Never touches unrelated events.
  static Future<List<FinancialEvent>> reverseLinkedTo(
    String transactionId, {
    String? reason,
  }) async {
    final active = activeEventsLinkedTo(transactionId);
    final out = <FinancialEvent>[];
    for (final e in active) {
      out.add(await reverse(
        e.id,
        reason: reason ?? 'Linked chip transaction voided',
      ));
    }
    return out;
  }

  /// Session-scoped Deposit remaining for one person.
  ///
  /// Same definition as [depositHeldMinor] but only events whose
  /// [FinancialEvent.sessionId] is [sessionId]. Lifetime Deposit stays
  /// on [depositHeldMinor].
  static int depositHeldMinorForSession(
    String personId,
    AppCurrency currency,
    String sessionId,
  ) {
    final snap = snapshotForSession(
      sessionId,
      currency: currency,
      personId: personId,
    );
    return snap.depositRemainingMinor;
  }

  static double depositHeldMajorForSession(
    String personId,
    AppCurrency currency,
    String sessionId,
  ) =>
      MoneyUnits.toMajor(
        currency,
        depositHeldMinorForSession(personId, currency, sessionId),
      );

  /// Derived session totals. Does not change Outstanding Balance.
  static SessionFinancialSnapshot snapshotForSession(
    String sessionId, {
    required AppCurrency currency,
    String? personId,
  }) {
    final events = _eventsInSession(sessionId,
        personId: personId, currency: currency);
    if (events.isEmpty) {
      return SessionFinancialSnapshot.empty(currency);
    }
    final reversed = _reversedIds(events);
    var cashIn = 0, cashOut = 0, creditIssued = 0, creditRepaid = 0;
    var unbacked = 0, depositIn = 0, depositOut = 0, usedForChips = 0;
    var outstanding = 0;

    final cashInLinks = <String>{};
    for (final e in events) {
      if (e.isReversal || reversed.contains(e.id)) continue;
      if (e.type == FinancialEventType.cashInForChips &&
          e.linkedTransactionId != null) {
        cashInLinks.add(e.linkedTransactionId!);
      }
    }

    for (final e in events) {
      if (e.isReversal || reversed.contains(e.id)) continue;
      outstanding += _contribution(e, reversed);
      switch (e.type) {
        case FinancialEventType.cashInForChips:
          cashIn += e.amountMinor;
          break;
        case FinancialEventType.cashOutForChips:
          cashOut += e.amountMinor;
          break;
        case FinancialEventType.creditIssued:
          creditIssued += e.amountMinor;
          break;
        case FinancialEventType.creditRepaid:
          creditRepaid += e.amountMinor;
          break;
        case FinancialEventType.cashOutUnbacked:
          unbacked += e.amountMinor;
          break;
        case FinancialEventType.frontMoneyIn:
          depositIn += e.amountMinor;
          break;
        case FinancialEventType.frontMoneyOut:
          depositOut += e.amountMinor;
          final link = e.linkedTransactionId;
          if (link != null && cashInLinks.contains(link)) {
            usedForChips += e.amountMinor;
          }
          break;
        case FinancialEventType.adjustment:
        case FinancialEventType.rebateGranted:
        case FinancialEventType.rebateRecovered:
          break;
      }
    }

    final remaining = depositIn - depositOut;
    return SessionFinancialSnapshot(
      currency: currency,
      cashInForChipsMinor: cashIn,
      cashOutForChipsMinor: cashOut,
      creditIssuedMinor: creditIssued,
      creditRepaidMinor: creditRepaid,
      cashOutUnbackedMinor: unbacked,
      depositInMinor: depositIn,
      depositUsedForChipsMinor: usedForChips,
      depositReturnedMinor: depositOut - usedForChips,
      depositRemainingMinor: remaining < 0 ? 0 : remaining,
      sessionOutstandingMinor: outstanding,
      recorded: true,
    );
  }

  /// Derived, never stored. Empty history ⇒ [PlayerAccount.hasHistory]
  /// is false and the UI must show "Not recorded", not 0.
  static PlayerAccount accountFor(String personId) {
    final identity = PlayerIdentityService.byId(personId);
    final events = eventsFor(personId);
    final currencies = <AppCurrency>{};
    for (final e in events) {
      currencies.add(e.currency);
    }
    final balances = currencies
        .map((c) => balance(personId, c))
        .toList()
      ..sort((a, b) => a.currency.index.compareTo(b.currency.index));
    return PlayerAccount(
      personId: personId,
      displayName: identity?.displayName ?? personId,
      balances: balances,
      events: events,
    );
  }

  /// Signed minor-unit contribution of one event to the approved
  /// formula. Exposed for tests and for the read-only UI so a row's
  /// sign can never drift from the engine.
  static int contributionOf(FinancialEvent event) {
    final reversed = _isReversed(event.id) ? {event.id} : <String>{};
    return _contribution(event, reversed);
  }

  static int _contribution(FinancialEvent event, Set<String> reversedIds) {
    if (event.isReversal) return 0;
    if (reversedIds.contains(event.id)) return 0;
    switch (event.type) {
      case FinancialEventType.cashInForChips:
      case FinancialEventType.cashOutForChips:
      case FinancialEventType.rebateGranted:
      case FinancialEventType.rebateRecovered:
        return 0;
      case FinancialEventType.creditIssued:
      case FinancialEventType.cashOutUnbacked:
      case FinancialEventType.frontMoneyOut:
        return event.amountMinor;
      case FinancialEventType.creditRepaid:
      case FinancialEventType.frontMoneyIn:
        return -event.amountMinor;
      case FinancialEventType.adjustment:
        return event.amountMinor * (event.adjustmentSign ?? 0);
    }
  }

  static List<FinancialEvent> _eventsFor(
    String personId, {
    AppCurrency? currency,
  }) {
    if (!_boxOpen) return const [];
    return HiveService.financialEvents.values
        .where((e) =>
            e.personId == personId &&
            (currency == null || e.currency == currency))
        .toList();
  }

  static List<FinancialEvent> _eventsInSession(
    String sessionId, {
    String? personId,
    AppCurrency? currency,
  }) {
    if (!_boxOpen || sessionId.isEmpty) return const [];
    return HiveService.financialEvents.values
        .where((e) =>
            e.sessionId == sessionId &&
            (personId == null || e.personId == personId) &&
            (currency == null || e.currency == currency))
        .toList();
  }

  static Set<String> _reversedIds(Iterable<FinancialEvent> events) {
    return events
        .where((e) => e.isReversal)
        .map((e) => e.reversesEventId!)
        .toSet();
  }

  static bool _isReversed(String eventId) {
    if (!_boxOpen) return false;
    for (final e in HiveService.financialEvents.values) {
      if (e.reversesEventId == eventId) return true;
    }
    return false;
  }

  static void _assertBoxOpen() {
    if (!_boxOpen) {
      throw FinancialLedgerException(
        'Financial ledger storage is not available.',
      );
    }
  }

  static void _assertKnownPerson(String personId) {
    if (personId.trim().isEmpty) {
      throw FinancialLedgerException('personId is required.');
    }
    if (PlayerIdentityService.byId(personId) == null) {
      throw FinancialLedgerException(
        'Cannot record a financial event: personId does not exist. '
        'Create and confirm the identity first.',
      );
    }
  }
}

/// Derived session totals for the Financial Ledger. Never stored.
///
/// Major-unit getters exist so the UI never re-implements the exponent.
class SessionFinancialSnapshot {
  final AppCurrency currency;
  final int cashInForChipsMinor;
  final int cashOutForChipsMinor;
  final int creditIssuedMinor;
  final int creditRepaidMinor;
  final int cashOutUnbackedMinor;
  final int depositInMinor;
  final int depositUsedForChipsMinor;
  final int depositReturnedMinor;
  final int depositRemainingMinor;
  final int sessionOutstandingMinor;
  final bool recorded;

  const SessionFinancialSnapshot({
    required this.currency,
    required this.cashInForChipsMinor,
    required this.cashOutForChipsMinor,
    required this.creditIssuedMinor,
    required this.creditRepaidMinor,
    required this.cashOutUnbackedMinor,
    required this.depositInMinor,
    required this.depositUsedForChipsMinor,
    required this.depositReturnedMinor,
    required this.depositRemainingMinor,
    required this.sessionOutstandingMinor,
    required this.recorded,
  });

  factory SessionFinancialSnapshot.empty(AppCurrency currency) =>
      SessionFinancialSnapshot(
        currency: currency,
        cashInForChipsMinor: 0,
        cashOutForChipsMinor: 0,
        creditIssuedMinor: 0,
        creditRepaidMinor: 0,
        cashOutUnbackedMinor: 0,
        depositInMinor: 0,
        depositUsedForChipsMinor: 0,
        depositReturnedMinor: 0,
        depositRemainingMinor: 0,
        sessionOutstandingMinor: 0,
        recorded: false,
      );

  double get cashInForChips =>
      MoneyUnits.toMajor(currency, cashInForChipsMinor);
  double get cashOutForChips =>
      MoneyUnits.toMajor(currency, cashOutForChipsMinor);
  double get creditIssued => MoneyUnits.toMajor(currency, creditIssuedMinor);
  double get creditRepaid => MoneyUnits.toMajor(currency, creditRepaidMinor);
  double get cashOutUnbacked =>
      MoneyUnits.toMajor(currency, cashOutUnbackedMinor);
  double get depositIn => MoneyUnits.toMajor(currency, depositInMinor);
  double get depositUsedForChips =>
      MoneyUnits.toMajor(currency, depositUsedForChipsMinor);
  double get depositReturned =>
      MoneyUnits.toMajor(currency, depositReturnedMinor);
  double get depositRemaining =>
      MoneyUnits.toMajor(currency, depositRemainingMinor);
  double get sessionOutstanding =>
      MoneyUnits.toMajor(currency, sessionOutstandingMinor);

  bool get hasDepositRemaining => recorded && depositRemainingMinor > 0;

  bool get hasOpenCredit =>
      recorded &&
      (creditIssuedMinor - creditRepaidMinor > 0 || cashOutUnbackedMinor > 0);
}
