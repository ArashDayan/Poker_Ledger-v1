import '../models/enums.dart';
import '../models/player.dart';
import 'financial_ledger_service.dart';
import 'session_service.dart';

/// Read-only settlement picture for one session.
///
/// Three layers, never mixed:
///   * Chip books from [SessionService] (frozen formulas)
///   * Session financial snapshot from [FinancialLedgerService]
///   * Per-player chip P/L plus session Deposit / financial lines
///
/// This file does not write anything and does not change either engine.
class SessionSettlementView {
  final String sessionId;
  final AppCurrency currency;
  final BalanceResult chipBalance;
  final double buyIn;
  final double rebuy;
  final double cashOut;
  final double rake;
  final double dealerTips;
  final double hostProfit;
  final double moneyStillInPlay;
  final double cashDrop;
  final SessionFinancialSnapshot financial;
  final List<PlayerSettlementRow> players;

  const SessionSettlementView({
    required this.sessionId,
    required this.currency,
    required this.chipBalance,
    required this.buyIn,
    required this.rebuy,
    required this.cashOut,
    required this.rake,
    required this.dealerTips,
    required this.hostProfit,
    required this.moneyStillInPlay,
    required this.cashDrop,
    required this.financial,
    required this.players,
  });

  factory SessionSettlementView.load(
    String sessionId,
    AppCurrency currency,
  ) {
    final players = SessionService.playersFor(sessionId);
    return SessionSettlementView(
      sessionId: sessionId,
      currency: currency,
      chipBalance: SessionService.checkBalance(sessionId),
      buyIn: SessionService.totalBuyIn(sessionId),
      rebuy: SessionService.totalRebuy(sessionId),
      cashOut: SessionService.totalCashOut(sessionId),
      rake: SessionService.totalRake(sessionId),
      dealerTips: SessionService.totalDealerTips(sessionId),
      hostProfit: SessionService.hostProfit(sessionId),
      moneyStillInPlay: SessionService.moneyStillInPlay(sessionId),
      cashDrop: SessionService.totalCashDrop(sessionId),
      financial: FinancialLedgerService.snapshotForSession(
        sessionId,
        currency: currency,
      ),
      players: [
        for (final p in players) PlayerSettlementRow.load(sessionId, currency, p),
      ],
    );
  }
}

class PlayerSettlementRow {
  final Player player;
  final double buyIn;
  final double rebuy;
  final double cashOut;
  final double chipProfitLoss;
  final bool hasCashedOut;
  final SessionFinancialSnapshot financial;

  const PlayerSettlementRow({
    required this.player,
    required this.buyIn,
    required this.rebuy,
    required this.cashOut,
    required this.chipProfitLoss,
    required this.hasCashedOut,
    required this.financial,
  });

  factory PlayerSettlementRow.load(
    String sessionId,
    AppCurrency currency,
    Player player,
  ) {
    final personId = player.personId;
    return PlayerSettlementRow(
      player: player,
      buyIn: SessionService.playerBuyInOnly(sessionId, player.id),
      rebuy: SessionService.playerRebuyOnly(sessionId, player.id),
      cashOut: SessionService.playerTotalCashOut(sessionId, player.id),
      chipProfitLoss: SessionService.playerProfitLoss(sessionId, player.id),
      hasCashedOut: SessionService.hasCashedOut(sessionId, player.id),
      financial: personId == null || personId.isEmpty
          ? SessionFinancialSnapshot.empty(currency)
          : FinancialLedgerService.snapshotForSession(
              sessionId,
              currency: currency,
              personId: personId,
            ),
    );
  }
}
