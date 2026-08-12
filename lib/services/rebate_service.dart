import '../models/chip_movement.dart';
import '../models/enums.dart';
import '../models/financial_event.dart';
import '../models/session.dart';
import 'chip_tracking_service.dart';
import 'financial_ledger_service.dart';
import 'hive_service.dart';

/// Recovery journal reasons. Stored on [FinancialEvent.reason].
class RebateRecoveryKind {
  static const lostInPlay = 'lost_in_play';
  static const clawback = 'clawback';
}

/// Session-scoped loss-rebate (Discount) configuration.
class RebateConfig {
  final bool enabled;
  final int minLossMinor;
  final double percent;

  const RebateConfig({
    required this.enabled,
    required this.minLossMinor,
    required this.percent,
  });

  bool get isUsable => enabled && percent > 0 && minLossMinor > 0;
}

/// Suggested first or incremental grant. Nothing is written until confirm.
class RebateSuggestion {
  final int eligibleLossMinor;
  final int grantMinor;
  final int grossLossMinor;
  final int incrementalLossMinor;
  final bool alreadyQualified;
  final String? blockReason;

  const RebateSuggestion({
    required this.eligibleLossMinor,
    required this.grantMinor,
    required this.grossLossMinor,
    required this.incrementalLossMinor,
    required this.alreadyQualified,
    this.blockReason,
  });

  bool get canGrant => blockReason == null && grantMinor > 0;
}

/// What a cash-out does to the still-exposed grant.
///
/// Economic reading (locked):
///   C <= G  → player receives C; G − C returned as lost-in-play
///   C >  G  → claw back G from the window; player receives C − G
/// After either branch the grant cycle is closed. A later cash-out does
/// not invent another free grant.
class RebateRealization {
  final int cashOutMinor;
  final int exposedBeforeMinor;
  final int returnedMinor;
  final int paidOutFromDiscountMinor;
  final int clawbackMinor;
  final int actualCashPaidMinor;
  final String? recoveryKind;

  const RebateRealization({
    required this.cashOutMinor,
    required this.exposedBeforeMinor,
    required this.returnedMinor,
    required this.paidOutFromDiscountMinor,
    required this.clawbackMinor,
    required this.actualCashPaidMinor,
    this.recoveryKind,
  });

  bool get hasJournalRow => returnedMinor > 0;
  bool get closesGrant => exposedBeforeMinor > 0;
}

/// Derived Discount picture for one person in one session + currency.
class RebateSnapshot {
  final AppCurrency currency;
  final int playerCashInMinor;
  final int playerCashOutMinor;
  final int grossLossMinor;
  final int grantedMinor;
  final int returnedMinor;
  final int clawbackMinor;
  final int paidOutMinor;
  final int exposedMinor;
  final int actualCashPaidMinor;
  final int houseRetainedMinor;
  final int chipGrantMinor;
  final int cashGrantMinor;
  final bool recorded;

  const RebateSnapshot({
    required this.currency,
    required this.playerCashInMinor,
    required this.playerCashOutMinor,
    required this.grossLossMinor,
    required this.grantedMinor,
    required this.returnedMinor,
    required this.clawbackMinor,
    required this.paidOutMinor,
    required this.exposedMinor,
    required this.actualCashPaidMinor,
    required this.houseRetainedMinor,
    required this.chipGrantMinor,
    required this.cashGrantMinor,
    required this.recorded,
  });

  factory RebateSnapshot.empty(AppCurrency currency) => RebateSnapshot(
        currency: currency,
        playerCashInMinor: 0,
        playerCashOutMinor: 0,
        grossLossMinor: 0,
        grantedMinor: 0,
        returnedMinor: 0,
        clawbackMinor: 0,
        paidOutMinor: 0,
        exposedMinor: 0,
        actualCashPaidMinor: 0,
        houseRetainedMinor: 0,
        chipGrantMinor: 0,
        cashGrantMinor: 0,
        recorded: false,
      );

  double get playerCashIn => MoneyUnits.toMajor(currency, playerCashInMinor);
  double get playerCashOut => MoneyUnits.toMajor(currency, playerCashOutMinor);
  double get grossLoss => MoneyUnits.toMajor(currency, grossLossMinor);
  double get granted => MoneyUnits.toMajor(currency, grantedMinor);
  double get returned => MoneyUnits.toMajor(currency, returnedMinor);
  double get clawback => MoneyUnits.toMajor(currency, clawbackMinor);
  double get paidOut => MoneyUnits.toMajor(currency, paidOutMinor);
  double get exposed => MoneyUnits.toMajor(currency, exposedMinor);
  double get actualCashPaid =>
      MoneyUnits.toMajor(currency, actualCashPaidMinor);
  double get houseRetained => MoneyUnits.toMajor(currency, houseRetainedMinor);
  double get chipGrant => MoneyUnits.toMajor(currency, chipGrantMinor);
  double get cashGrant => MoneyUnits.toMajor(currency, cashGrantMinor);

  bool get hasActivity =>
      recorded && (grantedMinor > 0 || playerCashInMinor > 0);
}

/// Loss rebate / Discount engine.
///
/// HARD RULES
///   * Reads Financial Ledger events only. Never chip stacks, never
///     Buy-in/Rebuy rows, never SessionService totals.
///   * Types 8/9 contribute 0 to Outstanding Balance.
///   * A grant is never cashInForChips.
///   * Session + person + currency scoped. No cross-session carry.
///   * Cash game only.
///   * Does not import session_service.dart.
class RebateService {
  RebateService._();

  static RebateConfig configFor(String sessionId) {
    final session = _session(sessionId);
    if (session == null) {
      return const RebateConfig(enabled: false, minLossMinor: 0, percent: 0);
    }
    return configOf(session);
  }

  static RebateConfig configOf(PokerSession session) {
    if (session.isTournament) {
      return const RebateConfig(enabled: false, minLossMinor: 0, percent: 0);
    }
    final currency = session.currency;
    final minMajor = session.rebateMinLoss ?? 0;
    final minMinor = minMajor <= 0
        ? 0
        : (minMajor * MoneyUnits.factor(currency)).round();
    return RebateConfig(
      enabled: session.rebateEnabled,
      minLossMinor: minMinor < 0 ? 0 : minMinor,
      percent: session.rebatePercent ?? 0,
    );
  }

  /// Own-cash in / out / loss. Credit, Deposit, unbacked and rebate
  /// grants are excluded by using only those two event types.
  static RebateSnapshot snapshot({
    required String sessionId,
    required String personId,
    required AppCurrency currency,
  }) {
    final events = FinancialLedgerService.eventsForSession(
      sessionId,
      personId: personId,
      currency: currency,
    );
    if (events.isEmpty) return RebateSnapshot.empty(currency);

    final reversed = events
        .where((e) => e.isReversal)
        .map((e) => e.reversesEventId!)
        .toSet();
    final active = events
        .where((e) => !e.isReversal && !reversed.contains(e.id))
        .toList()
      ..sort((a, b) {
        final byTime = a.occurredAt.compareTo(b.occurredAt);
        if (byTime != 0) return byTime;
        return a.createdAt.compareTo(b.createdAt);
      });

    var cashIn = 0;
    var cashOut = 0;
    var granted = 0;
    var returned = 0;
    var clawback = 0;
    var exposed = 0;
    var paidOut = 0;
    var chipGrant = 0;
    var cashGrant = 0;

    for (final e in active) {
      switch (e.type) {
        case FinancialEventType.cashInForChips:
          cashIn += e.amountMinor;
          break;
        case FinancialEventType.cashOutForChips:
          cashOut += e.amountMinor;
          if (exposed > 0) {
            final g = exposed;
            final c = e.amountMinor;
            if (c < g) {
              paidOut += c;
            } else if (c == g) {
              paidOut += c;
            }
            exposed = 0;
          }
          break;
        case FinancialEventType.rebateGranted:
          granted += e.amountMinor;
          exposed += e.amountMinor;
          if (e.grantedAsChips == true) {
            chipGrant += e.amountMinor;
          } else {
            cashGrant += e.amountMinor;
          }
          break;
        case FinancialEventType.rebateRecovered:
          returned += e.amountMinor;
          if (e.reason == RebateRecoveryKind.clawback) {
            clawback += e.amountMinor;
          }
          break;
        default:
          break;
      }
    }

    // Paid-out identity: grant that neither returned nor is still exposed.
    final derivedPaid = granted - returned - exposed;
    if (derivedPaid >= 0) {
      paidOut = derivedPaid;
    }

    final grossLoss = cashIn > cashOut ? cashIn - cashOut : 0;
    final actualPaid = cashOut - clawback;
    final houseRetained = cashIn - actualPaid;

    return RebateSnapshot(
      currency: currency,
      playerCashInMinor: cashIn,
      playerCashOutMinor: cashOut,
      grossLossMinor: grossLoss,
      grantedMinor: granted,
      returnedMinor: returned,
      clawbackMinor: clawback,
      paidOutMinor: paidOut < 0 ? 0 : paidOut,
      exposedMinor: exposed < 0 ? 0 : exposed,
      actualCashPaidMinor: actualPaid,
      houseRetainedMinor: houseRetained,
      chipGrantMinor: chipGrant,
      cashGrantMinor: cashGrant,
      recorded: true,
    );
  }

  static RebateSuggestion suggest({
    required String sessionId,
    required String personId,
    required AppCurrency currency,
  }) {
    final session = _session(sessionId);
    if (session == null) {
      return const RebateSuggestion(
        eligibleLossMinor: 0,
        grantMinor: 0,
        grossLossMinor: 0,
        incrementalLossMinor: 0,
        alreadyQualified: false,
        blockReason: 'Session not found.',
      );
    }
    if (session.isTournament) {
      return const RebateSuggestion(
        eligibleLossMinor: 0,
        grantMinor: 0,
        grossLossMinor: 0,
        incrementalLossMinor: 0,
        alreadyQualified: false,
        blockReason: 'Discount is cash-game only.',
      );
    }
    final cfg = configOf(session);
    if (!cfg.isUsable) {
      return const RebateSuggestion(
        eligibleLossMinor: 0,
        grantMinor: 0,
        grossLossMinor: 0,
        incrementalLossMinor: 0,
        alreadyQualified: false,
        blockReason: 'Discount is not enabled for this session.',
      );
    }

    final snap = snapshot(
      sessionId: sessionId,
      personId: personId,
      currency: currency,
    );
    final consumed = _consumedBaseLoss(sessionId, personId, currency);
    final already = consumed > 0;
    final incremental = snap.grossLossMinor - consumed;
    if (!already && snap.grossLossMinor < cfg.minLossMinor) {
      return RebateSuggestion(
        eligibleLossMinor: 0,
        grantMinor: 0,
        grossLossMinor: snap.grossLossMinor,
        incrementalLossMinor: incremental < 0 ? 0 : incremental,
        alreadyQualified: false,
        blockReason: 'Own-cash loss is below the session minimum.',
      );
    }
    final eligible = already
        ? (incremental < 0 ? 0 : incremental)
        : snap.grossLossMinor;
    if (eligible <= 0) {
      return RebateSuggestion(
        eligibleLossMinor: 0,
        grantMinor: 0,
        grossLossMinor: snap.grossLossMinor,
        incrementalLossMinor: incremental < 0 ? 0 : incremental,
        alreadyQualified: already,
        blockReason: 'No new own-cash loss to rebate.',
      );
    }
    final grant = _percentOf(eligible, cfg.percent);
    if (grant <= 0) {
      return RebateSuggestion(
        eligibleLossMinor: eligible,
        grantMinor: 0,
        grossLossMinor: snap.grossLossMinor,
        incrementalLossMinor: incremental < 0 ? 0 : incremental,
        alreadyQualified: already,
        blockReason: 'Calculated Discount rounds to zero.',
      );
    }
    return RebateSuggestion(
      eligibleLossMinor: eligible,
      grantMinor: grant,
      grossLossMinor: snap.grossLossMinor,
      incrementalLossMinor: incremental < 0 ? 0 : incremental,
      alreadyQualified: already,
    );
  }

  /// Records a confirmed grant. Does not write chips; the caller does
  /// that through [issueGrantChips] so a chip failure cannot invent
  /// cashInForChips.
  static Future<FinancialEvent> grant({
    required String sessionId,
    required String personId,
    required AppCurrency currency,
    required bool asChips,
    String? note,
  }) async {
    final suggestion = suggest(
      sessionId: sessionId,
      personId: personId,
      currency: currency,
    );
    if (!suggestion.canGrant) {
      throw FinancialLedgerException(
        suggestion.blockReason ?? 'Cannot grant Discount.',
      );
    }
    return FinancialLedgerService.record(
      personId: personId,
      currency: currency,
      type: FinancialEventType.rebateGranted,
      amount: MoneyUnits.toMajor(currency, suggestion.grantMinor),
      sessionId: sessionId,
      note: note ?? (asChips ? 'Granted as chips' : 'Granted as cash'),
      baseLossMinor: suggestion.eligibleLossMinor,
      grantedAsChips: asChips,
    );
  }

  /// Physical chips for a chip-form grant. Linked to the grant event id
  /// so void/reverse can unwind them. Never a Buy-in row.
  static Future<List<ChipMovement>> issueGrantChips({
    required FinancialEvent grantEvent,
    required String playerId,
    required Map<String, int> distribution,
  }) {
    if (grantEvent.type != FinancialEventType.rebateGranted) {
      throw FinancialLedgerException(
        'Only a Discount grant can issue rebate chips.',
      );
    }
    if (distribution.isEmpty) return Future.value(const []);
    return ChipTrackingService.recordDistribution(
      distribution: distribution,
      from: ChipLocation.bank,
      to: ChipLocation.player(playerId),
      reason: ChipMovementReason.lossRebate,
      sessionId: grantEvent.sessionId,
      transactionId: grantEvent.id,
      note: 'Loss rebate',
    );
  }

  static RebateRealization previewRealization({
    required String sessionId,
    required String personId,
    required AppCurrency currency,
    required int cashOutMinor,
  }) {
    final snap = snapshot(
      sessionId: sessionId,
      personId: personId,
      currency: currency,
    );
    return _realize(snap.exposedMinor, cashOutMinor);
  }

  /// Appends rebateRecovered when this cash-out returns Discount value
  /// to the house. Player still receives the cash-out when C <= G.
  static Future<FinancialEvent?> realizeCashOut({
    required String sessionId,
    required String personId,
    required AppCurrency currency,
    required int cashOutMinor,
    String? linkedTransactionId,
  }) async {
    final plan = previewRealization(
      sessionId: sessionId,
      personId: personId,
      currency: currency,
      cashOutMinor: cashOutMinor,
    );
    if (!plan.hasJournalRow) return null;
    return FinancialLedgerService.record(
      personId: personId,
      currency: currency,
      type: FinancialEventType.rebateRecovered,
      amount: MoneyUnits.toMajor(currency, plan.returnedMinor),
      sessionId: sessionId,
      linkedTransactionId: linkedTransactionId,
      reason: plan.recoveryKind,
      note: plan.recoveryKind == RebateRecoveryKind.clawback
          ? 'Clawback at cash-out'
          : 'Lost in play',
    );
  }

  /// Append-only reverse of a grant, and of any chips issued for it.
  static Future<FinancialEvent> reverseGrant(String eventId) async {
    final event = HiveService.financialEvents.get(eventId);
    if (event == null || event.type != FinancialEventType.rebateGranted) {
      throw FinancialLedgerException('Cannot reverse: grant not found.');
    }
    final reversal = await FinancialLedgerService.reverse(
      eventId,
      reason: 'Discount grant reversed',
    );
    await ChipTrackingService.reverseForTransaction(
      eventId,
      note: 'Discount grant reversed',
    );
    return reversal;
  }

  static Future<FinancialEvent> reverseRecovery(String eventId) {
    return FinancialLedgerService.reverse(
      eventId,
      reason: 'Discount recovery reversed',
    );
  }

  /// Session-wide chip-grant total, for the expected checkBalance gap
  /// explanation. Does not change SessionService math.
  static int chipGrantsIssuedMinor(String sessionId, AppCurrency currency) {
    final events = FinancialLedgerService.eventsForSession(
      sessionId,
      currency: currency,
    );
    final reversed = events
        .where((e) => e.isReversal)
        .map((e) => e.reversesEventId!)
        .toSet();
    var minor = 0;
    for (final e in events) {
      if (e.isReversal || reversed.contains(e.id)) continue;
      if (e.type == FinancialEventType.rebateGranted &&
          e.grantedAsChips == true) {
        minor += e.amountMinor;
      }
    }
    return minor;
  }

  static RebateRealization _realize(int exposed, int cashOutMinor) {
    if (exposed <= 0) {
      return RebateRealization(
        cashOutMinor: cashOutMinor,
        exposedBeforeMinor: 0,
        returnedMinor: 0,
        paidOutFromDiscountMinor: 0,
        clawbackMinor: 0,
        actualCashPaidMinor: cashOutMinor,
      );
    }
    if (cashOutMinor < exposed) {
      return RebateRealization(
        cashOutMinor: cashOutMinor,
        exposedBeforeMinor: exposed,
        returnedMinor: exposed - cashOutMinor,
        paidOutFromDiscountMinor: cashOutMinor,
        clawbackMinor: 0,
        actualCashPaidMinor: cashOutMinor,
        recoveryKind: RebateRecoveryKind.lostInPlay,
      );
    }
    if (cashOutMinor == exposed) {
      return RebateRealization(
        cashOutMinor: cashOutMinor,
        exposedBeforeMinor: exposed,
        returnedMinor: 0,
        paidOutFromDiscountMinor: cashOutMinor,
        clawbackMinor: 0,
        actualCashPaidMinor: cashOutMinor,
      );
    }
    return RebateRealization(
      cashOutMinor: cashOutMinor,
      exposedBeforeMinor: exposed,
      returnedMinor: exposed,
      paidOutFromDiscountMinor: 0,
      clawbackMinor: exposed,
      actualCashPaidMinor: cashOutMinor - exposed,
      recoveryKind: RebateRecoveryKind.clawback,
    );
  }

  static int _consumedBaseLoss(
    String sessionId,
    String personId,
    AppCurrency currency,
  ) {
    final events = FinancialLedgerService.eventsForSession(
      sessionId,
      personId: personId,
      currency: currency,
    );
    final reversed = events
        .where((e) => e.isReversal)
        .map((e) => e.reversesEventId!)
        .toSet();
    var consumed = 0;
    for (final e in events) {
      if (e.isReversal || reversed.contains(e.id)) continue;
      if (e.type != FinancialEventType.rebateGranted) continue;
      consumed += e.baseLossMinor ?? 0;
    }
    return consumed;
  }

  static int _percentOf(int minor, double percent) {
    if (minor <= 0 || percent <= 0) return 0;
    return (minor * percent / 100).round();
  }

  static PokerSession? _session(String sessionId) {
    try {
      return HiveService.sessions.get(sessionId);
    } catch (_) {
      return null;
    }
  }
}
