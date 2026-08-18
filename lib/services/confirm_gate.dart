import '../models/enums.dart';
import 'financial_capture.dart';

/// Interprets a required confirmation sheet.
///
/// A dismissed / Back / Cancel result is [null]. That is abort — never a
/// silent default such as [ChipFunding.notRecorded].
///
/// An explicit tap that returns a value (including "Skip — not recorded")
/// is a confirmed choice and may proceed to commit.
class ConfirmGate {
  ConfirmGate._();

  /// True when the banker left a required sheet without choosing.
  static bool aborted(Object? sheetResult) => sheetResult == null;

  /// Buy-in / rebuy / cash-out of a positive amount need an explicit
  /// funding choice before any ledger write. A $0 cash-out (bust) has
  /// nothing to fund and does not open the sheet.
  static bool fundingRequired(TransactionType type, double amount) {
    if (amount <= 0) return false;
    return type == TransactionType.buyIn ||
        type == TransactionType.rebuy ||
        type == TransactionType.cashOut;
  }
}

/// Funding collected BEFORE any Session / Chip / Financial write.
///
/// [aborted] means Back/Cancel/dismiss on a required sheet — callers
/// must not commit anything.
class CollectedFunding {
  final ChipFundingChoice? buyIn;
  final ChipCashOutFunding? cashOut;
  final bool aborted;

  const CollectedFunding._({
    this.buyIn,
    this.cashOut,
    this.aborted = false,
  });

  const CollectedFunding.none() : this._();

  const CollectedFunding.buyIn(ChipFundingChoice choice)
      : this._(buyIn: choice);

  const CollectedFunding.cashOut(ChipCashOutFunding choice)
      : this._(cashOut: choice);

  const CollectedFunding.abort() : this._(aborted: true);

  /// $0 bust: no funding sheet, no financial cash-out row.
  const CollectedFunding.zeroCashOut()
      : this._(cashOut: ChipCashOutFunding.notRecorded);

  bool get shouldCommit => !aborted;
}

/// Pure commit decision for tests and for UI callers that must not write
/// until every required confirmation is in hand.
class ChipMoneyCommitPlan {
  final TransactionType type;
  final double amount;
  final CollectedFunding funding;
  final Map<String, int>? chipDistribution;

  const ChipMoneyCommitPlan({
    required this.type,
    required this.amount,
    required this.funding,
    this.chipDistribution,
  });

  /// Builds a plan from the raw sheet results. A null required-funding
  /// result is abort. Chip distribution is optional: null/empty = skip
  /// chips, never abort.
  factory ChipMoneyCommitPlan.fromSheetResults({
    required TransactionType type,
    required double amount,
    ChipFundingChoice? buyInFunding,
    ChipCashOutFunding? cashOutFunding,
    bool fundingSheetDismissed = false,
    Map<String, int>? chipDistribution,
  }) {
    if (ConfirmGate.fundingRequired(type, amount) &&
        (fundingSheetDismissed ||
            (type == TransactionType.cashOut && cashOutFunding == null) ||
            ((type == TransactionType.buyIn || type == TransactionType.rebuy) &&
                buyInFunding == null))) {
      return ChipMoneyCommitPlan(
        type: type,
        amount: amount,
        funding: const CollectedFunding.abort(),
        chipDistribution: chipDistribution,
      );
    }
    if (type == TransactionType.cashOut && amount <= 0) {
      return ChipMoneyCommitPlan(
        type: type,
        amount: amount,
        funding: const CollectedFunding.zeroCashOut(),
        chipDistribution: chipDistribution,
      );
    }
    if (type == TransactionType.cashOut) {
      return ChipMoneyCommitPlan(
        type: type,
        amount: amount,
        funding: CollectedFunding.cashOut(cashOutFunding!),
        chipDistribution: chipDistribution,
      );
    }
    if (type == TransactionType.buyIn || type == TransactionType.rebuy) {
      if (amount <= 0) {
        return ChipMoneyCommitPlan(
          type: type,
          amount: amount,
          funding: const CollectedFunding.none(),
          chipDistribution: chipDistribution,
        );
      }
      return ChipMoneyCommitPlan(
        type: type,
        amount: amount,
        funding: CollectedFunding.buyIn(buyInFunding!),
        chipDistribution: chipDistribution,
      );
    }
    return ChipMoneyCommitPlan(
      type: type,
      amount: amount,
      funding: const CollectedFunding.none(),
      chipDistribution: chipDistribution,
    );
  }

  bool get shouldCommit => funding.shouldCommit;

  bool get writesFinancialBuyIn =>
      shouldCommit &&
      buyInFunding != null &&
      FinancialCapture.typeForFunding(buyInFunding!) != null;

  ChipFunding? get buyInFunding => funding.buyIn?.funding;

  ChipCashOutFunding? get cashOutFunding => funding.cashOut;

  bool get writesFinancialCashOut =>
      shouldCommit &&
      cashOutFunding != null &&
      FinancialCapture.typeForCashOut(cashOutFunding!) != null;

  bool get writesChipDistribution {
    if (!shouldCommit) return false;
    final d = chipDistribution;
    if (d == null || d.isEmpty) return false;
    return d.values.any((q) => q > 0);
  }
}
