import '../models/chip_movement.dart';
import '../models/enums.dart';
import '../models/financial_event.dart';
import '../models/player.dart';
import '../models/transaction.dart';
import 'chip_tracking_service.dart';
import 'financial_capture.dart';
import 'financial_ledger_service.dart';
import 'session_service.dart';

/// One explicit banker action: convert Deposit into chips.
///
/// Writes, in order:
///   1. a normal Chip Ledger buy-in/rebuy (SessionService)
///   2. frontMoneyOut (reduces remaining Deposit)
///   3. cashInForChips (the converted cash is now playing money)
///
/// Both financial events carry [LedgerTransaction.id] as
/// [FinancialEvent.linkedTransactionId] (audit only).
///
/// A Deposit is never inferred as payment. The banker must call this.
/// FinancialLedgerService is not imported into SessionService; this
/// file is the only bridge.
class DepositToChipsResult {
  final LedgerTransaction chipTransaction;
  final FinancialEvent frontMoneyOut;
  final FinancialEvent cashInForChips;

  const DepositToChipsResult({
    required this.chipTransaction,
    required this.frontMoneyOut,
    required this.cashInForChips,
  });
}

/// Result of a seat-free wallet chip issuance (Phase 4).
class WalletIssuanceResult {
  /// The deposit draw: `frontMoneyOut` (audit signature recorded).
  final FinancialEvent frontMoneyOut;

  /// The person's own cash becoming playing money.
  final FinancialEvent cashInForChips;

  /// The physical chips that left the case into the person's holding.
  final List<ChipMovement> movements;

  /// Value recorded on the financial pair (the draw amount).
  final double issuedAmount;

  const WalletIssuanceResult({
    required this.frontMoneyOut,
    required this.cashInForChips,
    required this.movements,
    required this.issuedAmount,
  });
}

/// Seat-free wallet chip issuance (Phase 4).
///
/// The cage issues chips from a deposit draw directly to the PERSON —
/// no seat, no table, no session required (session-optional, C-1).
/// This is the approved flow step "cashier issues chips from the
/// wallet"; the person later commits chips to a table with a real
/// table buy-in (a later phase).
///
/// WRITES (and nothing else)
///   1. `frontMoneyOut` — the draw from the deposit (audit signature).
///   2. `cashInForChips` — the person's cash becomes playing money.
///   3. Chip movements `bank -> player(personId)`, reason
///      `depositIssuance` — person-scoped, never a seat, never P2P.
/// NO [LedgerTransaction] is written: there is no seat to buy in at.
///
/// RULES (all previously approved — none reinterpreted)
///   * The DEPOSIT is the funding source: the draw cannot exceed the
///     deposit held (the existing `Cannot use more deposit than is
///     held` guard in [FinancialCapture] enforces this).
///   * Person-scoped chip ownership: the movement targets personId.
///   * No P2P: chips come from the bank, from the person, nowhere else.
///   * Audit: the banker signature is required and recorded on both
///     financial events (the seat-free path has no transaction to
///     carry it).
///   * Bank cover: the composition cannot exceed what the case holds.
class DepositToChips {
  DepositToChips._();

  /// Seat in [sessionId] linked to [personId], or null.
  ///
  /// Requires an ACTUAL seat: the seated deposit-to-chips path
  /// ([convert]) needs a table to record the buy-in on. A person who
  /// is registered but not yet seated uses [issueToWallet] instead —
  /// null from this method is "use the wallet path", not an error.
  static Player? seatedPlayer(String sessionId, String personId) =>
      SessionService.seatedForSession(sessionId, personId);

  static Future<DepositToChipsResult> convert({
    required String personId,
    required String sessionId,
    required String playerId,
    required AppCurrency currency,
    required double amount,
    required String hostSignatureBase64,
  }) async {
    if (personId.isEmpty) {
      throw FinancialLedgerException('personId is required.');
    }
    if (amount <= 0) {
      throw FinancialLedgerException('Amount must be positive.');
    }
    final held = FinancialLedgerService.depositHeldMinor(personId, currency);
    final want = MoneyUnits.toMinor(currency, amount);
    if (held <= 0 || want > held) {
      throw FinancialLedgerException(
        'Cannot use more deposit than is held.',
      );
    }

    final alreadyIn = SessionService.playerBuyInOnly(sessionId, playerId);
    final type =
        alreadyIn > 0 ? TransactionType.rebuy : TransactionType.buyIn;

    final tx = await SessionService.recordTransaction(
      sessionId: sessionId,
      playerId: playerId,
      type: type,
      amount: amount,
      hostSignatureBase64: hostSignatureBase64,
      note: 'From deposit',
    );

    final pair = await FinancialCapture.useDepositForChips(
      personId: personId,
      currency: currency,
      amount: amount,
      sessionId: sessionId,
      linkedTransactionId: tx.id,
    );
    if (pair == null) {
      throw FinancialLedgerException(
        'Chip buy-in was saved. The deposit conversion failed.',
      );
    }
    return DepositToChipsResult(
      chipTransaction: tx,
      frontMoneyOut: pair.frontMoneyOut,
      cashInForChips: pair.cashInForChips,
    );
  }

  /// Issues chips from a deposit draw to the PERSON's holding — no
  /// seat, no table, no session required (session-optional, C-1).
  ///
  /// See the class docs above for the write set and the approved
  /// rules. [amount] is the recorded draw (the financial pair's
  /// amount); [composition] is the physical chips that leave the case
  /// (recorded as-is; its value may differ from [amount], the same
  /// discipline as the seated path, where the money record and the
  /// physical record are linked by person + time and reviewed in the
  /// audit log).
  static Future<WalletIssuanceResult> issueToWallet({
    required String personId,
    required AppCurrency currency,
    required double amount,
    required Map<String, int> composition,
    required String hostSignatureBase64,
    String? sessionId,
  }) async {
    if (personId.isEmpty) {
      throw FinancialLedgerException('personId is required.');
    }
    if (amount <= 0) {
      throw FinancialLedgerException('Amount must be positive.');
    }
    if (hostSignatureBase64.isEmpty) {
      throw FinancialLedgerException(
          'A banker signature is required to issue chips from a deposit.');
    }
    final cleaned = {
      for (final e in composition.entries)
        if (e.value > 0) e.key: e.value,
    };
    if (cleaned.isEmpty) {
      throw FinancialLedgerException('A chip composition is required.');
    }
    // Bank cover: the case cannot issue chips it does not hold.
    if (!ChipTrackingService.bankCanCover(cleaned)) {
      throw FinancialLedgerException(
          'The bank does not hold the issued chip composition.');
    }

    // 1+2: the approved financial pair, session-optional, with the
    // audit signature on both events. The deposit cap
    // ("Cannot use more deposit than is held") is enforced inside
    // FinancialCapture BEFORE any write.
    final pair = await FinancialCapture.useDepositForChips(
      personId: personId,
      currency: currency,
      amount: amount,
      sessionId: sessionId,
      linkedTransactionId: null, // no transaction: no seat, no table
      signatureBase64: hostSignatureBase64,
    );
    if (pair == null) {
      throw FinancialLedgerException('Deposit draw could not be recorded.');
    }

    // 3: the physical chips enter the PERSON's holding — person-scoped,
    // never a seat, never P2P.
    final movements = await ChipTrackingService.recordDistribution(
      distribution: cleaned,
      from: ChipLocation.bank,
      to: ChipLocation.player(personId),
      reason: ChipMovementReason.depositIssuance,
      sessionId: sessionId,
      note: 'deposit issuance',
    );

    return WalletIssuanceResult(
      frontMoneyOut: pair.frontMoneyOut,
      cashInForChips: pair.cashInForChips,
      movements: movements,
      issuedAmount: amount,
    );
  }

  /// Issues chips against a MARKER (Phase 5) — a wallet draw that the
  /// player signs as an IOU. Seat-free, like [issueToWallet]:
  /// no seat, no table, no session required, NO [LedgerTransaction].
  ///
  /// APPROVED RULES (E2 / W-2 — implemented, not reinterpreted)
  ///   * FUNDING: the marker is a draw on the person's AVAILABLE
  ///     DEPOSIT and can never exceed it. The cap is the SAME
  ///     `depositHeld` guard the deposit issuance uses (enforced
  ///     inside FinancialCapture before any write) — the wallet
  ///     logic is shared, not forked.
  ///   * The draw REDUCES the available deposit: it is recorded as
  ///     `frontMoneyOut`, so `depositHeld` (and therefore
  ///     `availableMarkerBalance`) drop by the marker amount.
  ///   * The IOU is `creditIssued` — the player owes the casino.
  ///     Repayment is the existing `creditRepaid` operation.
  ///   * SIGNATURE: a marker is credit plus a signature (existing
  ///     rule) — the PLAYER's signature is required and recorded on
  ///     both events.
  ///   * Person-scoped chip ownership; no P2P; no participation.
  ///
  /// WRITES (and nothing else)
  ///   1. `frontMoneyOut` — the wallet draw (player signature).
  ///   2. `creditIssued` — the IOU (player signature). If this write
  ///      fails, the draw is reversed (compensating, audit-kept).
  ///   3. Chip movements `bank -> player(personId)`, reason
  ///      `markerIssuance`.
  static Future<MarkerIssuanceResult> issueMarker({
    required String personId,
    required AppCurrency currency,
    required double amount,
    required Map<String, int> composition,
    required String playerSignatureBase64,
    String? sessionId,
  }) async {
    if (personId.isEmpty) {
      throw FinancialLedgerException('personId is required.');
    }
    if (amount <= 0) {
      throw FinancialLedgerException('Amount must be positive.');
    }
    if (playerSignatureBase64.isEmpty) {
      throw FinancialLedgerException(
          'A marker requires the player\'s signature.');
    }
    final cleaned = {
      for (final e in composition.entries)
        if (e.value > 0) e.key: e.value,
    };
    if (cleaned.isEmpty) {
      throw FinancialLedgerException('A chip composition is required.');
    }
    // Bank cover: the case cannot issue chips it does not hold.
    if (!ChipTrackingService.bankCanCover(cleaned)) {
      throw FinancialLedgerException(
          'The bank does not hold the issued chip composition.');
    }

    // 1: the wallet draw. The AVAILABLE-DEPOSIT CAP is enforced here
    // (depositHeld guard) BEFORE anything is written — the marker can
    // never exceed the available deposit (E2/W-2).
    final draw = await FinancialCapture.recordFrontMoneyOut(
      personId: personId,
      currency: currency,
      amount: amount,
      sessionId: sessionId,
      note: 'Marker draw',
      signatureBase64: playerSignatureBase64,
    );
    if (draw == null) {
      throw FinancialLedgerException('Marker draw could not be recorded.');
    }

    // 2: the IOU. Compensating reversal of the draw if this fails, so
    // the deposit is never drawn without the credit existing.
    final credit = await (() async {
      try {
        return await FinancialLedgerService.record(
          personId: personId,
          currency: currency,
          type: FinancialEventType.creditIssued,
          amount: amount,
          sessionId: sessionId,
          signatureBase64: playerSignatureBase64,
          note: 'Marker',
        );
      } catch (e) {
        await FinancialLedgerService.reverse(
          draw.id,
          reason: 'Marker credit failed — draw reversed',
        );
        rethrow;
      }
    })();

    // 3: the physical chips enter the PERSON's holding — person-scoped,
    // never a seat, never P2P, never a participation.
    final movements = await ChipTrackingService.recordDistribution(
      distribution: cleaned,
      from: ChipLocation.bank,
      to: ChipLocation.player(personId),
      reason: ChipMovementReason.markerIssuance,
      sessionId: sessionId,
      note: 'marker issuance',
    );

    return MarkerIssuanceResult(
      frontMoneyOut: draw,
      creditIssued: credit,
      movements: movements,
      issuedAmount: amount,
    );
  }
}

/// Result of a seat-free marker (wallet draw) issuance (Phase 5).
class MarkerIssuanceResult {
  /// The wallet draw: the amount taken from the available deposit.
  final FinancialEvent frontMoneyOut;

  /// The IOU: the player now owes the casino this amount.
  final FinancialEvent creditIssued;

  /// The physical chips that left the case into the person's holding.
  final List<ChipMovement> movements;

  /// Value recorded on the marker (the draw amount).
  final double issuedAmount;

  const MarkerIssuanceResult({
    required this.frontMoneyOut,
    required this.creditIssued,
    required this.movements,
    required this.issuedAmount,
  });
}
