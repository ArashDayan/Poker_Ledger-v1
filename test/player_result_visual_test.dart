import 'package:flutter_test/flutter_test.dart';
import 'package:poker_ledger/core/player_result_visual.dart';
import 'package:poker_ledger/core/theme/app_theme.dart';

void main() {
  test('1. active with negative P/L is playing, not loser red', () {
    final v = PlayerResultVisuals.of(
      occupied: true,
      hasCashedOut: false,
      profitLoss: -2000,
    );
    expect(v, PlayerResultVisual.playing);
    expect(PlayerResultVisuals.ringColor(v), AppColors.gold);
    expect(PlayerResultVisuals.amountColor(v), isNot(AppColors.danger));
  });

  test('2. active with positive P/L is playing, not winner green', () {
    final v = PlayerResultVisuals.of(
      occupied: true,
      hasCashedOut: false,
      profitLoss: 500,
    );
    expect(v, PlayerResultVisual.playing);
    expect(PlayerResultVisuals.ringColor(v), isNot(AppColors.accentGreen));
  });

  test('3. cashed-out winner is green', () {
    final v = PlayerResultVisuals.of(
      occupied: true,
      hasCashedOut: true,
      profitLoss: 300,
    );
    expect(v, PlayerResultVisual.cashedWinner);
    expect(PlayerResultVisuals.ringColor(v), AppColors.accentGreen);
  });

  test('4. cashed-out loser is red', () {
    final v = PlayerResultVisuals.of(
      occupied: true,
      hasCashedOut: true,
      profitLoss: -100,
    );
    expect(v, PlayerResultVisual.cashedLoser);
    expect(PlayerResultVisuals.ringColor(v), AppColors.danger);
  });

  test('5. cashed-out even is neutral', () {
    final v = PlayerResultVisuals.of(
      occupied: true,
      hasCashedOut: true,
      profitLoss: 0,
    );
    expect(v, PlayerResultVisual.cashedEven);
    expect(PlayerResultVisuals.ringColor(v), AppColors.textSecondary);
  });

  test('6. empty seat is empty / divider', () {
    final v = PlayerResultVisuals.of(
      occupied: false,
      hasCashedOut: false,
      profitLoss: 0,
    );
    expect(v, PlayerResultVisual.empty);
    expect(PlayerResultVisuals.ringColor(v), AppColors.divider);
  });

  test('8. settlement amount colour matches table/list (no loser red while playing)',
      () {
    final playing = PlayerResultVisuals.of(
      occupied: true,
      hasCashedOut: false,
      profitLoss: -400,
    );
    expect(PlayerResultVisuals.amountColor(playing), isNot(AppColors.danger));
    final cashed = PlayerResultVisuals.of(
      occupied: true,
      hasCashedOut: true,
      profitLoss: -400,
    );
    expect(PlayerResultVisuals.amountColor(cashed), AppColors.danger);
  });

  test('7. table and list use the same mapping function', () {
    const cases = [
      (true, false, -1.0, PlayerResultVisual.playing),
      (true, true, 1.0, PlayerResultVisual.cashedWinner),
      (true, true, -1.0, PlayerResultVisual.cashedLoser),
      (false, false, 0.0, PlayerResultVisual.empty),
    ];
    for (final c in cases) {
      expect(
        PlayerResultVisuals.of(
          occupied: c.$1,
          hasCashedOut: c.$2,
          profitLoss: c.$3,
        ),
        c.$4,
      );
    }
  });
}
