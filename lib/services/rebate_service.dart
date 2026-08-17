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
  static const override = 'override';
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

/// Suggested first or later-cycle grant. Nothing is written until confirm.
class RebateSuggestion {
  final int eligibleLossMinor;
  final int grantMinor;
  final int grossLossMinor;
  final int incrementalLossMinor;
  final bool alreadyQualified;
  final bool lossRealized;
  final int cycleIndex;
  final String? blockReason;

  /// Banker-defined Session/Discount period. Display / audit only:
  /// eligibility itself is derived from event [FinancialEvent.occurredAt]
  /// values versus the period end.
  final DateTime? periodStart;
  final DateTime? periodEnd;
  final bool periodEnded;

  const RebateSuggestion({
    required this.eligibleLossMinor,
    required this.grantMinor,
    required this.grossLossMinor,
    required this.incrementalLossMinor,
    required this.alreadyQualified,
    this.lossRealized = false,
    this.cycleIndex = 1,
    this.blockReason,
    this.periodStart,
    this.periodEnd,
    this.periodEnded = false,
  });

  bool get canGrant => blockReason == null && grantMinor > 0;
}

/// What a cash-out does to the still-exposed grant.
///
/// Finalized remaining-loss entitlement:
///   C <= G  → player receives C; G − C lost in play
///   C >  G  → recon = G − p × max(0, L − C), capped to [0, G]
///             player receives C − recon
/// This is not a new percent tax on the cash-out. After either branch
/// the cycle is closed. Banker override pays C and journals the waived
/// recon so it can never be reclaimed.
class RebateRealization {
  final int cashOutMinor;
  final int exposedBeforeMinor;
  final int originalLossMinor;
  final int remainingLossMinor;
  final int remainingEntitlementMinor;
  final int returnedMinor;
  final int paidOutFromDiscountMinor;
  final int clawbackMinor;
  final int waivedMinor;
  final int actualCashPaidMinor;
  final double grantPercent;
  final bool overrideApplied;
  final String? recoveryKind;

  const RebateRealization({
    required this.cashOutMinor,
    required this.exposedBeforeMinor,
    this.originalLossMinor = 0,
    this.remainingLossMinor = 0,
    this.remainingEntitlementMinor = 0,
    required this.returnedMinor,
    required this.paidOutFromDiscountMinor,
    required this.clawbackMinor,
    this.waivedMinor = 0,
    required this.actualCashPaidMinor,
    this.grantPercent = 0,
    this.overrideApplied = false,
    this.recoveryKind,
  });

  int get reconciliationMinor =>
      overrideApplied ? waivedMinor : clawbackMinor;

  int get normalPaidMinor => cashOutMinor - clawbackMinor;

  bool get hasJournalRow => returnedMinor > 0 || waivedMinor > 0;
  bool get closesGrant => exposedBeforeMinor > 0;

  RebateRealization get asOverride {
    if (clawbackMinor <= 0) return this;
    return RebateRealization(
      cashOutMinor: cashOutMinor,
      exposedBeforeMinor: exposedBeforeMinor,
      originalLossMinor: originalLossMinor,
      remainingLossMinor: remainingLossMinor,
      remainingEntitlementMinor: remainingEntitlementMinor,
      returnedMinor: 0,
      paidOutFromDiscountMinor: exposedBeforeMinor,
      clawbackMinor: 0,
      waivedMinor: clawbackMinor,
      actualCashPaidMinor: cashOutMinor,
      grantPercent: grantPercent,
      overrideApplied: true,
      recoveryKind: RebateRecoveryKind.override,
    );
  }
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
  final int waivedMinor;
  final int paidOutMinor;
  final int exposedMinor;
  final int actualCashPaidMinor;
  final int houseRetainedMinor;
  final int chipGrantMinor;
  final int cashGrantMinor;
  final int originalLossMinor;
  final int remainingLossMinor;
  final int remainingEntitlementMinor;
  final double grantPercent;
  final int cycleIndex;
  final bool cycleOpen;
  final String? closeReason;
  final bool recorded;
  final bool hasOwnCashOutEvent;

  /// Banker-defined Session/Discount period, for display / reporting.
  /// Cumulative snapshot figures above are never affected by the period
  /// end — expiration is never deletion.
  final DateTime? periodStart;
  final DateTime? periodEnd;
  final bool periodEnded;

  const RebateSnapshot({
    required this.currency,
    required this.playerCashInMinor,
    required this.playerCashOutMinor,
    required this.grossLossMinor,
    required this.grantedMinor,
    required this.returnedMinor,
    required this.clawbackMinor,
    this.waivedMinor = 0,
    required this.paidOutMinor,
    required this.exposedMinor,
    required this.actualCashPaidMinor,
    required this.houseRetainedMinor,
    required this.chipGrantMinor,
    required this.cashGrantMinor,
    this.originalLossMinor = 0,
    this.remainingLossMinor = 0,
    this.remainingEntitlementMinor = 0,
    this.grantPercent = 0,
    this.cycleIndex = 0,
    this.cycleOpen = false,
    this.closeReason,
    required this.recorded,
    this.hasOwnCashOutEvent = false,
    this.periodStart,
    this.periodEnd,
    this.periodEnded = false,
  });

  /// Discount value lost at the table — not a window clawback.
  int get lostInPlayMinor {
    final v = returnedMinor - clawbackMinor;
    return v < 0 ? 0 : v;
  }

  factory RebateSnapshot.empty(
    AppCurrency currency, {
    DateTime? periodStart,
    DateTime? periodEnd,
    bool periodEnded = false,
  }) =>
      RebateSnapshot(
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
        periodStart: periodStart,
        periodEnd: periodEnd,
        periodEnded: periodEnded,
      );

  double get playerCashIn => MoneyUnits.toMajor(currency, playerCashInMinor);
  double get playerCashOut => MoneyUnits.toMajor(currency, playerCashOutMinor);
  double get grossLoss => MoneyUnits.toMajor(currency, grossLossMinor);
  double get granted => MoneyUnits.toMajor(currency, grantedMinor);
  double get returned => MoneyUnits.toMajor(currency, returnedMinor);
  double get clawback => MoneyUnits.toMajor(currency, clawbackMinor);
  double get waived => MoneyUnits.toMajor(currency, waivedMinor);
  double get paidOut => MoneyUnits.toMajor(currency, paidOutMinor);
  double get exposed => MoneyUnits.toMajor(currency, exposedMinor);
  double get actualCashPaid =>
      MoneyUnits.toMajor(currency, actualCashPaidMinor);
  double get houseRetained => MoneyUnits.toMajor(currency, houseRetainedMinor);
  double get chipGrant => MoneyUnits.toMajor(currency, chipGrantMinor);
  double get cashGrant => MoneyUnits.toMajor(currency, cashGrantMinor);
  double get lostInPlay => MoneyUnits.toMajor(currency, lostInPlayMinor);
  double get originalLoss => MoneyUnits.toMajor(currency, originalLossMinor);
  double get remainingLoss => MoneyUnits.toMajor(currency, remainingLossMinor);
  double get remainingEntitlement =>
      MoneyUnits.toMajor(currency, remainingEntitlementMinor);
  double get playerEconomicNet =>
      MoneyUnits.toMajor(currency, actualCashPaidMinor - playerCashInMinor);

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
///   * Later cycles are independent. Never GrossLoss − Σ baseLoss.
///   * Eligibility respects the Banker-defined Session period
///     (session start → plannedEndAt): qualifying activity must OCCUR
///     (occurredAt) before the period end. occurredAt is the only
///     clock that matters — a qualifying event inside the period stays
///     eligible whenever the Banker records the Discount. There is
///     exactly one period per session — no fixed 24h, no repeating
///     windows, no carry of expired loss or winning cushion, and
///     endedAt (the actual close) never rewrites the period. Tables
///     never define the period. Expiration is never deletion: history
///     stays fully walkable.
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

  /// Banker-defined Session/Discount period end, or null when the
  /// session has none.
  ///
  /// The Banker chooses the session start ([PokerSession.dateTime]) and
  /// optionally a planned end ([PokerSession.plannedEndAt]); the period
  /// may be 24h, 18h, or any duration. There is exactly ONE period per
  /// session — no fixed 24-hour constant and no repeating windows.
  ///
  /// The period is the plan, start → plannedEndAt, and nothing else:
  ///   * [PokerSession.endedAt] is the ACTUAL close fact. It is never
  ///     folded into the period math and never rewrites the Banker's
  ///     period. Closing a session early does not move the deadline;
  ///     eligibility still follows occurredAt versus plannedEndAt.
  ///   * plannedEndAt null (legacy / unset) → no time-based expiry:
  ///     eligibility stays session-scoped exactly as before. No duration
  ///     is ever invented.
  static DateTime? effectivePeriodEnd(PokerSession session) {
    return session.plannedEndAt;
  }

  static DateTime? effectivePeriodEndFor(String sessionId) {
    final session = _session(sessionId);
    if (session == null) return null;
    return effectivePeriodEnd(session);
  }

  /// True when [moment] is at or past the session's period end.
  /// A null period end never expires on its own.
  static bool periodEndedAt(PokerSession session, DateTime moment) {
    final end = effectivePeriodEnd(session);
    return end != null && !moment.isBefore(end);
  }

  /// Own-cash in / out / loss. Credit, Deposit, unbacked and rebate
  /// grants are excluded by using only those two event types.
  ///
  /// Reporting view: always walks the FULL session history. The
  /// Banker-defined period end never truncates these figures —
  /// expiration is never deletion.
  static RebateSnapshot snapshot({
    required String sessionId,
    required String personId,
    required AppCurrency currency,
  }) {
    final walk = _walk(
      sessionId: sessionId,
      personId: personId,
      currency: currency,
    );
    final session = _session(sessionId);
    final periodStart = session?.dateTime;
    final periodEnd =
        session == null ? null : effectivePeriodEnd(session);
    final periodOver = session != null && periodEndedAt(session, DateTime.now());
    if (!walk.seen) {
      return RebateSnapshot.empty(
        currency,
        periodStart: periodStart,
        periodEnd: periodEnd,
        periodEnded: periodOver,
      );
    }

    final derivedPaid = walk.granted - walk.returned - walk.exposed;
    final grossLoss =
        walk.cashIn > walk.cashOut ? walk.cashIn - walk.cashOut : 0;
    final actualPaid = walk.cashOut - walk.clawback;
    final houseRetained = walk.cashIn - actualPaid;

    return RebateSnapshot(
      currency: currency,
      playerCashInMinor: walk.cashIn,
      playerCashOutMinor: walk.cashOut,
      grossLossMinor: grossLoss,
      grantedMinor: walk.granted,
      returnedMinor: walk.returned,
      clawbackMinor: walk.clawback,
      waivedMinor: walk.waived,
      paidOutMinor: derivedPaid < 0 ? 0 : derivedPaid,
      exposedMinor: walk.exposed < 0 ? 0 : walk.exposed,
      actualCashPaidMinor: actualPaid,
      houseRetainedMinor: houseRetained,
      chipGrantMinor: walk.chipGrant,
      cashGrantMinor: walk.cashGrant,
      originalLossMinor: walk.originalLoss,
      remainingLossMinor: walk.remainingLoss,
      remainingEntitlementMinor: walk.remainingEntitlement,
      grantPercent: walk.lastPercent,
      cycleIndex: walk.lastCycleIndex,
      cycleOpen: walk.cycleOpen,
      closeReason: walk.lastCloseReason,
      recorded: true,
      hasOwnCashOutEvent: walk.hasOwnCashOutEvent,
      periodStart: periodStart,
      periodEnd: periodEnd,
      periodEnded: periodOver,
    );
  }

  static RebateSuggestion suggest({
    required String sessionId,
    required String personId,
    required AppCurrency currency,
    bool bustRealized = false,
    bool chipCashOutWithoutFunding = false,
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

    // The Banker-defined Session/Discount period. Eligibility is decided
    // ONLY by the qualifying events' occurredAt values versus the period
    // end — never by the moment the Banker confirms the grant, and with
    // no invented time limit on recording. An event that occurred inside
    // the period stays eligible even when recorded after the end.
    final cutoff = effectivePeriodEnd(session);
    final now = DateTime.now();
    final periodOver = cutoff != null && !now.isBefore(cutoff);

    final walk = _walk(
      sessionId: sessionId,
      personId: personId,
      currency: currency,
      cutoff: cutoff,
    );
    final snapGross =
        walk.cashIn > walk.cashOut ? walk.cashIn - walk.cashOut : 0;
    final cycleLoss = walk.pendingLoss;
    final already = walk.closedCount > 0 || walk.cycleOpen;
    final nextIndex = walk.closedCount + (walk.cycleOpen ? 1 : 0) + 1;

    if (chipCashOutWithoutFunding &&
        walk.pendingOut == 0 &&
        !bustRealized) {
      return RebateSuggestion(
        eligibleLossMinor: 0,
        grantMinor: 0,
        grossLossMinor: snapGross,
        incrementalLossMinor: cycleLoss,
        alreadyQualified: already,
        cycleIndex: nextIndex,
        blockReason: 'Cash-out funding was not recorded. '
            'Review the cash-out before granting Discount.',
        periodStart: session.dateTime,
        periodEnd: cutoff,
        periodEnded: periodOver,
      );
    }
    if (walk.cycleOpen) {
      return RebateSuggestion(
        eligibleLossMinor: 0,
        grantMinor: 0,
        grossLossMinor: snapGross,
        incrementalLossMinor: cycleLoss,
        alreadyQualified: true,
        cycleIndex: walk.lastCycleIndex,
        lossRealized: true,
        blockReason: 'A Discount cycle is still open.',
        periodStart: session.dateTime,
        periodEnd: cutoff,
        periodEnded: periodOver,
      );
    }
    if (periodOver && cycleLoss <= 0) {
      return RebateSuggestion(
        eligibleLossMinor: 0,
        grantMinor: 0,
        grossLossMinor: snapGross,
        incrementalLossMinor: 0,
        alreadyQualified: already,
        cycleIndex: nextIndex,
        blockReason: 'The Session Discount period has ended. '
            'Activity after the period end creates no eligibility.',
        periodStart: session.dateTime,
        periodEnd: cutoff,
        periodEnded: true,
      );
    }
    final lossRealized = walk.pendingOut > 0 || bustRealized;
    if (!lossRealized) {
      return RebateSuggestion(
        eligibleLossMinor: 0,
        grantMinor: 0,
        grossLossMinor: snapGross,
        incrementalLossMinor: cycleLoss,
        alreadyQualified: already,
        cycleIndex: nextIndex,
        blockReason: 'No realized cash-out yet. '
            'Record a cash-out or a \$0 bust before granting Discount.',
        periodStart: session.dateTime,
        periodEnd: cutoff,
        periodEnded: periodOver,
      );
    }
    if (cycleLoss < cfg.minLossMinor) {
      return RebateSuggestion(
        eligibleLossMinor: 0,
        grantMinor: 0,
        grossLossMinor: snapGross,
        incrementalLossMinor: cycleLoss,
        alreadyQualified: already,
        cycleIndex: nextIndex,
        lossRealized: true,
        blockReason: 'Own-cash loss is below the session minimum.',
        periodStart: session.dateTime,
        periodEnd: cutoff,
        periodEnded: periodOver,
      );
    }
    if (cycleLoss <= 0) {
      return RebateSuggestion(
        eligibleLossMinor: 0,
        grantMinor: 0,
        grossLossMinor: snapGross,
        incrementalLossMinor: 0,
        alreadyQualified: already,
        cycleIndex: nextIndex,
        lossRealized: true,
        blockReason: 'No new own-cash loss to rebate.',
        periodStart: session.dateTime,
        periodEnd: cutoff,
        periodEnded: periodOver,
      );
    }
    final grant = _percentOf(cycleLoss, cfg.percent);
    if (grant <= 0) {
      return RebateSuggestion(
        eligibleLossMinor: cycleLoss,
        grantMinor: 0,
        grossLossMinor: snapGross,
        incrementalLossMinor: cycleLoss,
        alreadyQualified: already,
        cycleIndex: nextIndex,
        lossRealized: true,
        blockReason: 'Calculated Discount rounds to zero.',
        periodStart: session.dateTime,
        periodEnd: cutoff,
        periodEnded: periodOver,
      );
    }
    return RebateSuggestion(
      eligibleLossMinor: cycleLoss,
      grantMinor: grant,
      grossLossMinor: snapGross,
      incrementalLossMinor: cycleLoss,
      alreadyQualified: already,
      cycleIndex: nextIndex,
      lossRealized: true,
      periodStart: session.dateTime,
      periodEnd: cutoff,
      periodEnded: periodOver,
    );
  }

  /// Records a confirmed grant. Does not write chips; the caller does
  /// that through [issueGrantChips] / [grantAsChips] so a chip failure
  /// cannot invent cashInForChips.
  ///
  /// [asChips] only marks the event. The UI must call [grantAsChips]
  /// so `grantedAsChips = true` is never stored without a real issuance.
  static Future<FinancialEvent> grant({
    required String sessionId,
    required String personId,
    required AppCurrency currency,
    required bool asChips,
    String? note,
    bool bustRealized = false,
    bool chipCashOutWithoutFunding = false,
  }) async {
    final suggestion = suggest(
      sessionId: sessionId,
      personId: personId,
      currency: currency,
      bustRealized: bustRealized,
      chipCashOutWithoutFunding: chipCashOutWithoutFunding,
    );
    if (!suggestion.canGrant) {
      throw FinancialLedgerException(
        suggestion.blockReason ?? 'Cannot grant Discount.',
      );
    }
    final cfg = configFor(sessionId);
    return FinancialLedgerService.record(
      personId: personId,
      currency: currency,
      type: FinancialEventType.rebateGranted,
      amount: MoneyUnits.toMajor(currency, suggestion.grantMinor),
      sessionId: sessionId,
      note: note ?? (asChips ? 'Granted as chips' : 'Granted as cash'),
      baseLossMinor: suggestion.eligibleLossMinor,
      grantedAsChips: asChips,
      grantPercent: cfg.percent,
      cycleIndex: suggestion.cycleIndex,
    );
  }

  /// True when [distribution] actually issues at least one chip.
  static bool hasChipCounts(Map<String, int>? distribution) {
    if (distribution == null || distribution.isEmpty) return false;
    for (final n in distribution.values) {
      if (n > 0) return true;
    }
    return false;
  }

  /// Chip-form grant. Refuses to write `grantedAsChips = true` unless
  /// a non-empty denomination/count map is issued in the same call.
  static Future<FinancialEvent> grantAsChips({
    required String sessionId,
    required String personId,
    required AppCurrency currency,
    required String playerId,
    required Map<String, int> distribution,
    String? note,
    bool bustRealized = false,
    bool chipCashOutWithoutFunding = false,
  }) async {
    if (playerId.isEmpty || !hasChipCounts(distribution)) {
      throw FinancialLedgerException(
        'Cannot record a chip Discount without issuing chips.',
      );
    }
    final grant = await RebateService.grant(
      sessionId: sessionId,
      personId: personId,
      currency: currency,
      asChips: true,
      note: note,
      bustRealized: bustRealized,
      chipCashOutWithoutFunding: chipCashOutWithoutFunding,
    );
    try {
      await issueGrantChips(
        grantEvent: grant,
        playerId: playerId,
        distribution: distribution,
      );
    } catch (_) {
      await reverseGrant(grant.id);
      rethrow;
    }
    return grant;
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
    if (!hasChipCounts(distribution)) return Future.value(const []);
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
    final pending = unjournaledRealization(
      sessionId: sessionId,
      personId: personId,
      currency: currency,
    );
    if (pending != null) return pending;
    final walk = _walk(
      sessionId: sessionId,
      personId: personId,
      currency: currency,
    );
    if (!walk.cycleOpen || walk.openG <= 0) {
      return _realize(
        originalLossMinor: 0,
        exposed: 0,
        percent: 0,
        cashOutMinor: cashOutMinor,
      );
    }
    return _realize(
      originalLossMinor: walk.openL,
      exposed: walk.openG,
      percent: walk.openP,
      cashOutMinor: cashOutMinor,
    );
  }

  /// Cash-out that already closed the grant but has no type-9 row yet.
  static RebateRealization? unjournaledRealization({
    required String sessionId,
    required String personId,
    required AppCurrency currency,
  }) {
    final events = _activeChronological(
      sessionId: sessionId,
      personId: personId,
      currency: currency,
    );
    final fallback = configFor(sessionId).percent;
    FinancialEvent? open;
    RebateRealization? pending;
    for (final e in events) {
      switch (e.type) {
        case FinancialEventType.rebateGranted:
          open = e;
          pending = null;
          break;
        case FinancialEventType.cashOutForChips:
          if (open != null) {
            pending = _realize(
              originalLossMinor: open.baseLossMinor ?? 0,
              exposed: open.amountMinor,
              percent: _percentOfGrant(open, fallback),
              cashOutMinor: e.amountMinor,
            );
            open = null;
          }
          break;
        case FinancialEventType.rebateRecovered:
          pending = null;
          break;
        default:
          break;
      }
    }
    if (pending == null || !pending.hasJournalRow) return null;
    return pending;
  }

  /// Lost-in-play is always persisted. A cash reconciliation still
  /// needs confirm because that changes the cash handed to the player.
  /// Override is a separate persist path.
  static bool shouldPersistRealization(
    RebateRealization plan, {
    required bool? confirmed,
  }) {
    if (!plan.hasJournalRow) return false;
    if (plan.overrideApplied) return confirmed == true;
    if (plan.clawbackMinor > 0) return confirmed == true;
    return true;
  }

  /// Appends rebateRecovered when this cash-out returns Discount value
  /// to the house, or journals a Banker override waiver.
  ///
  /// Idempotent: a second call after the type-9 row exists writes nothing.
  static Future<FinancialEvent?> realizeCashOut({
    required String sessionId,
    required String personId,
    required AppCurrency currency,
    required int cashOutMinor,
    String? linkedTransactionId,
    bool override = false,
  }) async {
    final normal = previewRealization(
      sessionId: sessionId,
      personId: personId,
      currency: currency,
      cashOutMinor: cashOutMinor,
    );
    final plan = override ? normal.asOverride : normal;
    if (!plan.hasJournalRow) return null;
    final amount = override ? plan.waivedMinor : plan.returnedMinor;
    if (amount <= 0) return null;
    return FinancialLedgerService.record(
      personId: personId,
      currency: currency,
      type: FinancialEventType.rebateRecovered,
      amount: MoneyUnits.toMajor(currency, amount),
      sessionId: sessionId,
      linkedTransactionId: linkedTransactionId,
      reason: plan.recoveryKind,
      note: override
          ? 'Banker override: waived '
              '${MoneyUnits.toMajor(currency, plan.waivedMinor)}'
          : (plan.recoveryKind == RebateRecoveryKind.clawback
              ? 'Discount reconciliation at cash-out'
              : 'Lost in play'),
      baseLossMinor: plan.originalLossMinor > 0 ? plan.originalLossMinor : null,
      grantPercent: plan.grantPercent > 0 ? plan.grantPercent : null,
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

  /// Frozen poker books plus Discount chips as a reconciling item.
  ///
  /// Does not change SessionService.checkBalance. Residual of 0 means
  /// the raw discrepancy is fully explained by Discount chips issued.
  static DiscountChipReconciliation chipReconciliation({
    required String sessionId,
    required AppCurrency currency,
    required double rawDiscrepancy,
    required double moneyStillInPlay,
  }) {
    final issued = chipGrantsIssuedMinor(sessionId, currency);
    final issuedMajor = MoneyUnits.toMajor(currency, issued);
    return DiscountChipReconciliation(
      issuedMinor: issued,
      issuedMajor: issuedMajor,
      rawDiscrepancy: rawDiscrepancy,
      residualAfterDiscount: rawDiscrepancy + issuedMajor,
      impliedStillInPlay: moneyStillInPlay + issuedMajor,
    );
  }

  /// Null when this session issued no chip Discount. Callers use this
  /// so a missing overlay cannot invent promotional chips.
  static DiscountChipReconciliation? overlayFor({
    required String sessionId,
    required AppCurrency currency,
    required double rawDiscrepancy,
    required double moneyStillInPlay,
  }) {
    if (chipGrantsIssuedMinor(sessionId, currency) <= 0) return null;
    return chipReconciliation(
      sessionId: sessionId,
      currency: currency,
      rawDiscrepancy: rawDiscrepancy,
      moneyStillInPlay: moneyStillInPlay,
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

  static RebateRealization _realize({
    required int originalLossMinor,
    required int exposed,
    required double percent,
    required int cashOutMinor,
  }) {
    if (exposed <= 0) {
      return RebateRealization(
        cashOutMinor: cashOutMinor,
        exposedBeforeMinor: 0,
        originalLossMinor: originalLossMinor,
        remainingLossMinor: 0,
        remainingEntitlementMinor: 0,
        returnedMinor: 0,
        paidOutFromDiscountMinor: 0,
        clawbackMinor: 0,
        actualCashPaidMinor: cashOutMinor,
        grantPercent: percent,
      );
    }
    final remainingLoss = originalLossMinor > cashOutMinor
        ? originalLossMinor - cashOutMinor
        : 0;
    final remainingEntitlement = _percentOf(remainingLoss, percent);

    if (cashOutMinor <= exposed) {
      return RebateRealization(
        cashOutMinor: cashOutMinor,
        exposedBeforeMinor: exposed,
        originalLossMinor: originalLossMinor,
        remainingLossMinor: remainingLoss,
        remainingEntitlementMinor: remainingEntitlement,
        returnedMinor: exposed - cashOutMinor,
        paidOutFromDiscountMinor: cashOutMinor,
        clawbackMinor: 0,
        actualCashPaidMinor: cashOutMinor,
        grantPercent: percent,
        recoveryKind: cashOutMinor < exposed
            ? RebateRecoveryKind.lostInPlay
            : null,
      );
    }

    var recon = exposed - remainingEntitlement;
    if (recon < 0) recon = 0;
    if (recon > exposed) recon = exposed;

    return RebateRealization(
      cashOutMinor: cashOutMinor,
      exposedBeforeMinor: exposed,
      originalLossMinor: originalLossMinor,
      remainingLossMinor: remainingLoss,
      remainingEntitlementMinor: remainingEntitlement,
      returnedMinor: recon,
      paidOutFromDiscountMinor: 0,
      clawbackMinor: recon,
      actualCashPaidMinor: cashOutMinor - recon,
      grantPercent: percent,
      recoveryKind: RebateRecoveryKind.clawback,
    );
  }

  static _DiscountWalk _walk({
    required String sessionId,
    String? personId,
    required AppCurrency currency,
    DateTime? cutoff,
  }) {
    final events = _activeChronological(
      sessionId: sessionId,
      personId: personId,
      currency: currency,
    );
    final fallback = configFor(sessionId).percent;
    final w = _DiscountWalk();
    if (events.isEmpty) return w;
    w.seen = true;

    void closeOpen({required String? reason, RebateRealization? plan}) {
      if (!w.cycleOpen) return;
      w.cycleOpen = false;
      w.exposed = 0;
      w.closedCount += 1;
      w.lastCloseReason = reason;
      if (plan != null) {
        w.remainingLoss = plan.remainingLossMinor;
        w.remainingEntitlement = plan.remainingEntitlementMinor;
      }
      w.pendingIn = w.nextIn;
      w.pendingOut = w.nextOut;
      w.nextIn = 0;
      w.nextOut = 0;
      w.openGrant = null;
    }

    for (final e in events) {
      if (cutoff != null &&
          !w.cutoffApplied &&
          !e.occurredAt.isBefore(cutoff)) {
        // The Banker-defined Session/Discount period ended here. From
        // this event onward, cash flow cannot CREATE eligibility:
        // there is no next window and no next session, and neither an
        // expired loss nor an expired winning cushion carries forward.
        //
        // No state is discarded at the boundary itself: in-period
        // pending flow stays in the accumulators because occurredAt
        // determines eligibility — an event that occurred inside the
        // period remains eligible even when the Banker records or
        // confirms the Discount after the end. There is no time limit
        // on that recording; expiration only means post-period activity
        // can never create new eligibility.
        //
        // Expiration is never deletion: cumulative counters, grants,
        // recoveries and cycle state below keep processing every event.
        w.cutoffApplied = true;
      }
      switch (e.type) {
        case FinancialEventType.cashInForChips:
          w.cashIn += e.amountMinor;
          if (w.cutoffApplied) break;
          if (w.cycleOpen) {
            w.nextIn += e.amountMinor;
          } else {
            w.pendingIn += e.amountMinor;
          }
          break;
        case FinancialEventType.cashOutForChips:
          w.hasOwnCashOutEvent = true;
          w.cashOut += e.amountMinor;
          if (w.cycleOpen && w.openGrant != null) {
            final plan = _realize(
              originalLossMinor: w.openL,
              exposed: w.openG,
              percent: w.openP,
              cashOutMinor: e.amountMinor,
            );
            closeOpen(
              reason: plan.recoveryKind ?? RebateRecoveryKind.clawback,
              plan: plan,
            );
          } else if (!w.cutoffApplied) {
            w.pendingOut += e.amountMinor;
          }
          break;
        case FinancialEventType.rebateGranted:
          w.granted += e.amountMinor;
          w.exposed += e.amountMinor;
          w.originalLoss += e.baseLossMinor ?? 0;
          w.openGrant = e;
          w.openL = e.baseLossMinor ?? 0;
          w.openG = e.amountMinor;
          w.openP = _percentOfGrant(e, fallback);
          w.lastPercent = w.openP;
          w.lastCycleIndex = e.cycleIndex ?? (w.closedCount + 1);
          w.cycleOpen = true;
          w.pendingIn = 0;
          w.pendingOut = 0;
          if (e.grantedAsChips == true) {
            w.chipGrant += e.amountMinor;
          } else {
            w.cashGrant += e.amountMinor;
          }
          break;
        case FinancialEventType.rebateRecovered:
          if (e.reason == RebateRecoveryKind.override) {
            w.waived += e.amountMinor;
            closeOpen(reason: RebateRecoveryKind.override);
          } else {
            w.returned += e.amountMinor;
            if (e.reason == RebateRecoveryKind.clawback) {
              w.clawback += e.amountMinor;
            }
            if (w.cycleOpen) {
              closeOpen(reason: e.reason);
            }
          }
          break;
        default:
          break;
      }
    }

    if (w.cycleOpen) {
      w.remainingLoss = w.openL;
      w.remainingEntitlement = _percentOf(w.openL, w.openP);
    }
    return w;
  }

  /// Active (not reversed, not a reversal) events in occurrence order.
  static List<FinancialEvent> _activeChronological({
    required String sessionId,
    String? personId,
    required AppCurrency currency,
  }) {
    final events = FinancialLedgerService.eventsForSession(
      sessionId,
      personId: personId,
      currency: currency,
    );
    final reversed = events
        .where((e) => e.isReversal)
        .map((e) => e.reversesEventId!)
        .toSet();
    return events
        .where((e) => !e.isReversal && !reversed.contains(e.id))
        .toList()
      ..sort((a, b) {
        final byTime = a.occurredAt.compareTo(b.occurredAt);
        if (byTime != 0) return byTime;
        return a.createdAt.compareTo(b.createdAt);
      });
  }

  static double _percentOfGrant(FinancialEvent grant, double fallback) {
    if (grant.grantPercent != null && grant.grantPercent! > 0) {
      return grant.grantPercent!;
    }
    final loss = grant.baseLossMinor ?? 0;
    if (loss > 0 && grant.amountMinor > 0) {
      return grant.amountMinor * 100.0 / loss;
    }
    return fallback;
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

class _DiscountWalk {
  bool seen = false;
  int cashIn = 0;
  int cashOut = 0;
  int granted = 0;
  int returned = 0;
  int clawback = 0;
  int waived = 0;
  int exposed = 0;
  int chipGrant = 0;
  int cashGrant = 0;
  bool hasOwnCashOutEvent = false;
  bool cycleOpen = false;
  int pendingIn = 0;
  int pendingOut = 0;
  int nextIn = 0;
  int nextOut = 0;
  int openL = 0;
  int openG = 0;
  double openP = 0;
  int originalLoss = 0;
  int remainingLoss = 0;
  int remainingEntitlement = 0;
  double lastPercent = 0;
  int lastCycleIndex = 0;
  String? lastCloseReason;
  int closedCount = 0;
  FinancialEvent? openGrant;

  /// Set once the walk crosses the Banker-defined period end.
  /// Post-period cash flow still counts in the cumulative history
  /// counters above but never accumulates into eligibility.
  bool cutoffApplied = false;

  int get pendingLoss =>
      pendingIn > pendingOut ? pendingIn - pendingOut : 0;
}

/// Read-only overlay on frozen poker books. Never written into
/// SessionService totals.
class DiscountChipReconciliation {
  final int issuedMinor;
  final double issuedMajor;
  final double rawDiscrepancy;
  final double residualAfterDiscount;
  final double impliedStillInPlay;

  const DiscountChipReconciliation({
    required this.issuedMinor,
    required this.issuedMajor,
    required this.rawDiscrepancy,
    required this.residualAfterDiscount,
    required this.impliedStillInPlay,
  });

  bool get hasIssued => issuedMinor > 0;

  bool get explainsGap =>
      issuedMinor > 0 && residualAfterDiscount.abs() < 0.005;

  bool get booksBalancedWithPromoOut =>
      issuedMinor > 0 && rawDiscrepancy.abs() < 0.005;
}
