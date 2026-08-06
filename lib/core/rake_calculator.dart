import '../models/enums.dart';
import '../models/session.dart';

/// A single "pot below this amount uses this rake" rule.
class RakeTierRule {
  final double upperBound;
  final double rake;
  const RakeTierRule(this.upperBound, this.rake);

  Map<String, double> toMap() => {'upperBound': upperBound, 'rake': rake};
  static RakeTierRule fromMap(Map map) => RakeTierRule(
        (map['upperBound'] as num).toDouble(),
        (map['rake'] as num).toDouble(),
      );
}

/// Suggests a rake amount for a session, using whichever mode the
/// session is configured for. Always a *suggestion* the banker confirms
/// (and can override) before it's recorded — never applied silently.
///
/// Default tiered table (Toman house rule), used whenever a session
/// hasn't customized its own:
///   < 10,000,000              -> no rake
///   10,000,000 - 15,000,000   -> 1,000,000
///   15,000,000 - 20,000,000   -> 1,500,000
///   20,000,000 - 25,000,000   -> 2,000,000
///   25,000,000 - 30,000,000   -> 2,500,000
///   30,000,000 - 50,000,000   -> 3,000,000 (max)
///   >= 50,000,000              -> no rake (house stops applying rake)
class RakeCalculator {
  static const List<RakeTierRule> defaultTiers = [
    RakeTierRule(10000000, 0),
    RakeTierRule(15000000, 1000000),
    RakeTierRule(20000000, 1500000),
    RakeTierRule(25000000, 2000000),
    RakeTierRule(30000000, 2500000),
  ];
  static const double defaultMaxRake = 3000000;
  static const double defaultNoRakeAtOrAbove = 50000000;

  /// Tiered calculation using an explicit rule set (session-configurable).
  static double suggestTiered(
    double potAmount, {
    List<RakeTierRule> tiers = defaultTiers,
    double maxRake = defaultMaxRake,
    double noRakeAtOrAbove = defaultNoRakeAtOrAbove,
  }) {
    if (potAmount >= noRakeAtOrAbove) return 0;
    final sorted = [...tiers]..sort((a, b) => a.upperBound.compareTo(b.upperBound));
    for (final tier in sorted) {
      if (potAmount < tier.upperBound) return tier.rake;
    }
    return maxRake;
  }

  /// Kept for backward compatibility with earlier call sites — the
  /// house-default tiered table with no session customization.
  static double suggestRake(double potAmount) => suggestTiered(potAmount);

  /// Session-aware suggestion: dispatches to percentage/fixed/tiered based
  /// on how the session is configured. [potAmount] is ignored for fixed
  /// mode and required (may be 0) for the other two.
  static double suggestForSession(PokerSession session, double potAmount) {
    switch (session.rakeMode) {
      case RakeMode.percentage:
        return double.parse(
            (potAmount * (session.rakePercentage / 100)).toStringAsFixed(2));
      case RakeMode.fixed:
        return session.fixedRakeAmount ?? 0;
      case RakeMode.tiered:
        final tiers = session.tieredRakeRules == null
            ? defaultTiers
            : session.tieredRakeRules!.map(RakeTierRule.fromMap).toList();
        return suggestTiered(
          potAmount,
          tiers: tiers,
          maxRake: session.tieredMaxRake ?? defaultMaxRake,
          noRakeAtOrAbove: session.tieredNoRakeAtOrAbove ?? defaultNoRakeAtOrAbove,
        );
    }
  }
}
