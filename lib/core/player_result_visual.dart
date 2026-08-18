import 'package:flutter/material.dart';

import 'theme/app_theme.dart';

/// Banker-facing seat / list state. Status (playing vs cashed out)
/// is separate from result (win / loss / even).
///
/// Result colours are applied ONLY after a cash-out exists. A live
/// buy-in that makes running P/L negative is still [playing].
enum PlayerResultVisual {
  empty,
  playing,
  cashedWinner,
  cashedLoser,
  cashedEven,
}

class PlayerResultVisuals {
  PlayerResultVisuals._();

  static PlayerResultVisual of({
    required bool occupied,
    required bool hasCashedOut,
    required double profitLoss,
  }) {
    if (!occupied) return PlayerResultVisual.empty;
    if (!hasCashedOut) return PlayerResultVisual.playing;
    if (profitLoss > 0) return PlayerResultVisual.cashedWinner;
    if (profitLoss < 0) return PlayerResultVisual.cashedLoser;
    return PlayerResultVisual.cashedEven;
  }

  static Color ringColor(PlayerResultVisual v) {
    switch (v) {
      case PlayerResultVisual.empty:
        return AppColors.divider;
      case PlayerResultVisual.playing:
        return AppColors.gold;
      case PlayerResultVisual.cashedWinner:
        return AppColors.accentGreen;
      case PlayerResultVisual.cashedLoser:
        return AppColors.danger;
      case PlayerResultVisual.cashedEven:
        return AppColors.textSecondary;
    }
  }

  static Color amountColor(PlayerResultVisual v) {
    switch (v) {
      case PlayerResultVisual.cashedWinner:
        return AppColors.accentGreen;
      case PlayerResultVisual.cashedLoser:
        return AppColors.danger;
      case PlayerResultVisual.playing:
      case PlayerResultVisual.cashedEven:
      case PlayerResultVisual.empty:
        return AppColors.textPrimary;
    }
  }
}
