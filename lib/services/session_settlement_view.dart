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
  /// Phase 7: table cash-outs (money that left table play because a
  /// player left a table carrying counted chips — session money OUT,
  /// but not a cage redemption).
  final double tableCashOut;
  /// Phase 7: carried chips committed to tables by re-entry — session
  /// money IN, never a new purchase (totalBuyIn is untouched).
  final double reentry;
  final double rake;
  final double dealerTips;
  /// Phase 7: house-banked game revenue (e.g. roulette). NEVER merged
  /// with [rake] — the report shows both lines, and [hostProfit] is
  /// their sum.
  final double houseWin;
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
    required this.tableCashOut,
    required this.reentry,
    required this.rake,
    required this.dealerTips,
    required this.houseWin,
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
      tableCashOut: SessionService.totalTableCashOut(sessionId),
      reentry: SessionService.totalReentry(sessionId),
      rake: SessionService.totalRake(sessionId),
      dealerTips: SessionService.totalDealerTips(sessionId),
      houseWin: SessionService.totalHouseWin(sessionId),
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
