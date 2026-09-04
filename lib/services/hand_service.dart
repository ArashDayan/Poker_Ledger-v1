import 'package:uuid/uuid.dart';

import '../models/chip_movement.dart';
import '../models/enums.dart';
import '../models/hand.dart';
import '../models/player.dart';
import '../models/transaction.dart';
import 'chip_tracking_service.dart';
import 'hive_service.dart';
import 'player_operation_guard.dart';
import 'session_service.dart';
import 'table_service.dart';

const _uuid = Uuid();

/// Raised when a completed hand cannot be recorded or voided.
class HandException implements Exception {
  final String message;
  HandException(this.message);
  @override
  String toString() => message;
}

/// One seated player's net chip change, as entered by the banker.
class HandResultDraft {
  final String seatPlayerId;
  final double chipChange;

  const HandResultDraft({
    required this.seatPlayerId,
    required this.chipChange,
  });
}

/// Operational pot history. Completing a hand may write the existing
/// rake / house-win session legs so last-hand and the session books
/// agree — it never writes buy-in, re-entry, table cash-out,
/// redemption, Discount, or a cashier P2P transfer.
class HandService {
  HandService._();

  static const _eps = 0.005;

  static bool get _boxOpen {
    try {
      HiveService.hands;
      return true;
    } catch (_) {
      return false;
    }
  }

  static List<Hand> forSession(String sessionId, {bool includeVoided = false}) {
    if (!_boxOpen) return const [];
    final list = HiveService.hands.values
        .where((h) =>
            h.sessionId == sessionId && (includeVoided || !h.isVoided))
        .toList()
      ..sort((a, b) {
        final byTime = a.completedAt.compareTo(b.completedAt);
        if (byTime != 0) return byTime;
        return a.handNumber.compareTo(b.handNumber);
      });
    return list;
  }

  static List<Hand> forTable(
    String sessionId,
    String tableId, {
    bool includeVoided = false,
  }) {
    return forSession(sessionId, includeVoided: includeVoided)
        .where((h) => h.tableId == tableId)
        .toList();
  }

  /// Latest non-voided hand at this table — the Last Hand.
  static Hand? lastForTable(String sessionId, String tableId) {
    final list = forTable(sessionId, tableId);
    if (list.isEmpty) return null;
    return list.last;
  }

  static List<Hand> forPlayer(
    String sessionId,
    String seatPlayerId, {
    bool includeVoided = false,
  }) {
    return forSession(sessionId, includeVoided: includeVoided)
        .where((h) => h.resultFor(seatPlayerId) != null)
        .toList();
  }

  static int nextHandNumber(String sessionId, String tableId) {
    var max = 0;
    for (final h in forTable(sessionId, tableId, includeVoided: true)) {
      if (h.handNumber > max) max = h.handNumber;
    }
    return max + 1;
  }

  /// Records a completed pot after it has been pushed.
  ///
  /// [postHandCounts] is optional and denomination-level. Values are
  /// always required. Missing counts never invent chip compositions.
  static Future<Hand> record({
    required String sessionId,
    required String tableId,
    required HandKind kind,
    required List<HandResultDraft> drafts,
    double? potAmount,
    double rakeAmount = 0,
    double houseWinAmount = 0,
    String? note,
    String? hostSignatureBase64,
    String? secondVerifierName,
    String? secondVerifierSignature,
    Map<String, Map<String, int>>? postHandCounts,
    Map<String, int>? rakeChips,
    Map<String, Map<String, int>>? houseWinChipsByPlayer,
  }) async {
    if (!_boxOpen) {
      throw HandException('Hand history is unavailable.');
    }
    SessionService.assertSessionActive(sessionId);

    final session = HiveService.sessions.get(sessionId);
    if (session == null) {
      throw HandException('Session not found.');
    }
    final table = TableService.tableById(session, tableId);
    if (table.status.isClosed) {
      throw HandException(
          '${table.name} is closed. Reopen it to record a hand.');
    }

    if (rakeAmount < 0 || houseWinAmount < 0) {
      throw HandException('Rake and house win cannot be negative.');
    }
    if (kind == HandKind.poker && houseWinAmount > _eps) {
      throw HandException('A poker hand cannot record a house win.');
    }
    if (kind == HandKind.houseGame && rakeAmount > _eps) {
      throw HandException('A house-game hand cannot record poker rake.');
    }

    final seated = {
      for (final p in TableService.playersAt(session, tableId)) p.id: p,
    };
    if (drafts.isEmpty) {
      throw HandException('A hand needs at least one seated player.');
    }

    final seen = <String>{};
    final built = <HandResult>[];
    var changeSum = 0.0;
    var potFromLosers = 0.0;
    for (final d in drafts) {
      if (!seen.add(d.seatPlayerId)) {
        throw HandException('A player cannot appear twice on one hand.');
      }
      final player = seated[d.seatPlayerId];
      if (player == null) {
        throw HandException(
            'Only players seated at this table can be on the hand.');
      }
      if (!player.seated) {
        throw HandException(
            '${player.name} is not seated — held chips are not in a hand.');
      }
      changeSum += d.chipChange;
      if (d.chipChange < 0) potFromLosers += -d.chipChange;
      built.add(HandResult(
        seatPlayerId: player.id,
        personId: player.personId,
        nameSnapshot: player.name,
        seatNumber: player.seatNumber,
        chipChange: d.chipChange,
        isWinner: d.chipChange > 0,
      ));
    }

    final conservation = changeSum + rakeAmount + houseWinAmount;
    if (conservation.abs() > _eps) {
      throw HandException(
          'Hand does not conserve chips: player changes + rake + '
          'house win must equal 0.');
    }

    final derivedPot = potFromLosers;
    if (potAmount != null && (potAmount - derivedPot).abs() > _eps) {
      throw HandException(
          'Pot must equal the chips lost by the losing player(s).');
    }
    final pot = potAmount ?? derivedPot;

    final hasActivity = pot > _eps ||
        rakeAmount > _eps ||
        houseWinAmount > _eps ||
        built.any((r) => r.chipChange.abs() > _eps);
    if (!hasActivity) {
      throw HandException('A hand with no chip change is not a pot.');
    }

    if (houseWinAmount > _eps &&
        (hostSignatureBase64 == null || hostSignatureBase64.isEmpty)) {
      throw HandException(
          'A house win requires the host signature.');
    }

    LedgerTransaction? rakeTx;
    LedgerTransaction? houseTx;
    final movementIds = <String>[];
    try {
      if (rakeAmount > _eps) {
        rakeTx = await SessionService.recordTransaction(
          sessionId: sessionId,
          type: TransactionType.rakeCollection,
          amount: rakeAmount,
          tableId: tableId,
          note: note ?? 'Hand #$table rake',
          secondVerifierName: secondVerifierName,
          secondVerifierSignature: secondVerifierSignature,
        );
        if (rakeChips != null && rakeChips.isNotEmpty) {
          final made = await ChipTrackingService.recordDistribution(
            distribution: rakeChips,
            from: ChipLocation.table(tableId),
            to: ChipLocation.bank,
            reason: ChipMovementReason.rake,
            sessionId: sessionId,
            transactionId: rakeTx.id,
            note: 'hand rake',
          );
          movementIds.addAll(made.map((m) => m.id));
        }
      }

      if (houseWinAmount > _eps) {
        final loser = _primaryLoser(built);
        PlayerOperationGuard.requireRegistered(
            loser, 'a hand house win');
        houseTx = await SessionService.recordTransaction(
          sessionId: sessionId,
          playerId: loser?.seatPlayerId,
          type: TransactionType.houseWin,
          amount: houseWinAmount,
          hostSignatureBase64: hostSignatureBase64,
          tableId: tableId,
          note: note ?? 'Hand house win',
          secondVerifierName: secondVerifierName,
          secondVerifierSignature: secondVerifierSignature,
        );
        if (houseWinChipsByPlayer != null) {
          for (final entry in houseWinChipsByPlayer.entries) {
            if (entry.value.isEmpty) continue;
            final player = seated[entry.key];
            final holder = ChipTrackingService.holderRef(
              playerId: entry.key,
              personId: player?.personId,
            );
            final made = await ChipTrackingService.recordDistribution(
              distribution: entry.value,
              from: ChipLocation.player(holder),
              to: ChipLocation.bank,
              reason: ChipMovementReason.houseWin,
              sessionId: sessionId,
              transactionId: houseTx.id,
              note: 'hand house win',
            );
            movementIds.addAll(made.map((m) => m.id));
          }
        }
      }

      if (postHandCounts != null) {
        for (final entry in postHandCounts.entries) {
          if (entry.value.isEmpty) continue;
          final player = seated[entry.key];
          final holder = ChipTrackingService.holderRef(
            playerId: entry.key,
            personId: player?.personId,
          );
          final made = await ChipTrackingService.adjustPlayerHoldingToCount(
            playerId: holder,
            counted: entry.value,
            sessionId: sessionId,
            note: 'hand stack count',
          );
          movementIds.addAll(made.map((m) => m.id));
        }
      }

      final hand = Hand(
        id: _uuid.v4(),
        sessionId: sessionId,
        tableId: tableId,
        handNumber: nextHandNumber(sessionId, tableId),
        kind: kind,
        potAmount: pot,
        rakeAmount: rakeAmount,
        houseWinAmount: houseWinAmount,
        note: note,
        rakeTransactionId: rakeTx?.id,
        houseWinTransactionId: houseTx?.id,
        chipMovementIds: movementIds,
      );
      hand.results = built;
      await HiveService.hands.put(hand.id, hand);
      return hand;
    } catch (e) {
      if (rakeTx != null) {
        await SessionService.voidTransaction(
          rakeTx.id,
          secondVerifierName: secondVerifierName,
          secondVerifierSignature: secondVerifierSignature,
        );
        await ChipTrackingService.reverseForTransaction(rakeTx.id,
            note: 'hand record failed');
      }
      if (houseTx != null) {
        await SessionService.voidTransaction(
          houseTx.id,
          secondVerifierName: secondVerifierName,
          secondVerifierSignature: secondVerifierSignature,
        );
        await ChipTrackingService.reverseForTransaction(houseTx.id,
            note: 'hand record failed');
      }
      await _reverseCountAdjustments(movementIds, note: 'hand record failed');
      if (e is HandException || e is SessionEndedException) rethrow;
      throw HandException('$e');
    }
  }

  static Future<Hand> voidHand(
    String handId, {
    String? secondVerifierName,
    String? secondVerifierSignature,
  }) async {
    if (!_boxOpen) {
      throw HandException('Hand history is unavailable.');
    }
    final hand = HiveService.hands.get(handId);
    if (hand == null) {
      throw HandException('Hand not found.');
    }
    SessionService.assertSessionActive(hand.sessionId);
    if (hand.isVoided) return hand;

    final rakeId = hand.rakeTransactionId;
    if (rakeId != null && rakeId.isNotEmpty) {
      final tx = HiveService.transactions.get(rakeId);
      if (tx != null && !tx.isVoided) {
        await SessionService.voidTransaction(
          rakeId,
          secondVerifierName: secondVerifierName,
          secondVerifierSignature: secondVerifierSignature,
        );
      }
      await ChipTrackingService.reverseForTransaction(rakeId, note: 'void hand');
    }
    final houseId = hand.houseWinTransactionId;
    if (houseId != null && houseId.isNotEmpty) {
      final tx = HiveService.transactions.get(houseId);
      if (tx != null && !tx.isVoided) {
        await SessionService.voidTransaction(
          houseId,
          secondVerifierName: secondVerifierName,
          secondVerifierSignature: secondVerifierSignature,
        );
      }
      await ChipTrackingService.reverseForTransaction(houseId,
          note: 'void hand');
    }
    await _reverseCountAdjustments(hand.movementIds, note: 'void hand');

    hand.status = HandStatus.voided;
    await hand.save();
    return hand;
  }

  /// Reverses optional post-hand physical count adjustments stored on
  /// the hand. Rake/house-win movements are reversed via their
  /// transaction ids; this only mirrors [ChipMovementReason.adjustment]
  /// legs (append-only, never P2P, never a cashier transfer).
  static Future<void> _reverseCountAdjustments(
    List<String> movementIds, {
    required String note,
  }) async {
    for (final id in movementIds) {
      ChipMovement? m;
      try {
        m = HiveService.chipMovements.get(id);
      } catch (_) {
        continue;
      }
      if (m == null) continue;
      if (m.reasonEnum != ChipMovementReason.adjustment) continue;
      await ChipTrackingService.record(
        chipTypeId: m.chipTypeId,
        quantity: m.quantity,
        from: m.to,
        to: m.from,
        reason: ChipMovementReason.reversal,
        sessionId: m.sessionId,
        note: note,
        chipValueOverride: m.chipValue,
      );
    }
  }

  static HandResult? _primaryLoser(List<HandResult> results) {
    HandResult? best;
    for (final r in results) {
      if (r.chipChange >= 0) continue;
      if (best == null || r.chipChange < best.chipChange) best = r;
    }
    return best;
  }
}
