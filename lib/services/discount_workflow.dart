import '../models/enums.dart';
import 'rebate_service.dart';
import 'session_service.dart';

/// Banker-facing Discount status. Derived only from [RebateService]
/// and seating facts — does not change eligibility math.
enum DiscountWorkflowKind {
  /// Session Discount is off or percent/min is not usable.
  disabled,

  /// Seat has no personId, so there is no Financial / Discount account.
  noIdentity,

  /// Own-cash loss is not realized (no paid cash-out / $0 bust).
  needsCashOut,

  /// Chip cash-out exists but funding was not recorded as paid cash.
  fundingMissing,

  /// A grant is still open (realize first).
  cycleOpen,

  /// A grant was issued and the cycle is closed.
  realized,

  /// Suggest says the Banker may grant.
  eligible,

  /// Configured, but no grant is available (below min, no loss, …).
  notEligible,
}

class DiscountWorkflowView {
  final DiscountWorkflowKind kind;
  final RebateSuggestion suggestion;
  final RebateSnapshot snapshot;
  final RebateConfig config;

  const DiscountWorkflowView({
    required this.kind,
    required this.suggestion,
    required this.snapshot,
    required this.config,
  });

  bool get canOpenReview => kind != DiscountWorkflowKind.noIdentity;

  bool get canGrant => suggestion.canGrant;

  factory DiscountWorkflowView.inspect({
    required String sessionId,
    required AppCurrency currency,
    String? personId,
    String? playerId,
  }) {
    final config = RebateService.configFor(sessionId);
    final emptySnap = RebateSnapshot.empty(currency);
    final emptySug = const RebateSuggestion(
      eligibleLossMinor: 0,
      grantMinor: 0,
      grossLossMinor: 0,
      incrementalLossMinor: 0,
      alreadyQualified: false,
      blockReason: 'Discount is not enabled for this session.',
    );

    if (personId == null || personId.isEmpty) {
      return DiscountWorkflowView(
        kind: DiscountWorkflowKind.noIdentity,
        suggestion: emptySug,
        snapshot: emptySnap,
        config: config,
      );
    }

    var bustRealized = false;
    if (playerId != null && playerId.isNotEmpty) {
      bustRealized = SessionService.hasZeroBustOut(sessionId, playerId);
    }

    final suggestion = RebateService.suggest(
      sessionId: sessionId,
      personId: personId,
      currency: currency,
      bustRealized: bustRealized,
    );
    final snapshot = RebateService.snapshot(
      sessionId: sessionId,
      personId: personId,
      currency: currency,
    );

    if (!config.isUsable) {
      return DiscountWorkflowView(
        kind: DiscountWorkflowKind.disabled,
        suggestion: suggestion,
        snapshot: snapshot,
        config: config,
      );
    }
    if (suggestion.canGrant) {
      return DiscountWorkflowView(
        kind: DiscountWorkflowKind.eligible,
        suggestion: suggestion,
        snapshot: snapshot,
        config: config,
      );
    }

    final reason = suggestion.blockReason ?? '';
    DiscountWorkflowKind kind;
    if (reason.contains('not recorded') ||
        reason.contains('Cash-out funding')) {
      kind = DiscountWorkflowKind.fundingMissing;
    } else if (reason.contains('No realized cash-out') ||
        reason.contains('\$0 bust')) {
      kind = DiscountWorkflowKind.needsCashOut;
    } else if (reason.contains('still open') || snapshot.cycleOpen) {
      kind = DiscountWorkflowKind.cycleOpen;
    } else if (snapshot.grantedMinor > 0 && !snapshot.cycleOpen) {
      kind = DiscountWorkflowKind.realized;
    } else {
      kind = DiscountWorkflowKind.notEligible;
    }

    return DiscountWorkflowView(
      kind: kind,
      suggestion: suggestion,
      snapshot: snapshot,
      config: config,
    );
  }

  String statusKey() {
    switch (kind) {
      case DiscountWorkflowKind.disabled:
        return 'discount_status_disabled';
      case DiscountWorkflowKind.noIdentity:
        return 'discount_status_no_identity';
      case DiscountWorkflowKind.needsCashOut:
        return 'discount_status_needs_cashout';
      case DiscountWorkflowKind.fundingMissing:
        return 'discount_status_funding';
      case DiscountWorkflowKind.cycleOpen:
        return 'discount_status_open';
      case DiscountWorkflowKind.realized:
        return 'discount_status_realized';
      case DiscountWorkflowKind.eligible:
        return 'discount_status_eligible';
      case DiscountWorkflowKind.notEligible:
        return 'discount_status_not_eligible';
    }
  }
}
