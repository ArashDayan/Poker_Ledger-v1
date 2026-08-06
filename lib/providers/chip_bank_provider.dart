import 'package:flutter/foundation.dart';

import '../models/chip_movement.dart';
import '../models/chip_type.dart';
import '../services/chip_bank_service.dart';
import '../services/chip_tracking_service.dart';

/// Exposes the chip inventory to the widget tree.
///
/// Thin by design, matching the other providers: all rules live in
/// [ChipBankService]. Independent of SessionProvider — it neither reads
/// nor notifies it, so chip edits can never trigger a ledger rebuild or
/// vice versa.
class ChipBankProvider extends ChangeNotifier {
  List<ChipType> _chips = const [];
  ChipBankSummary _summary = ChipBankSummary.empty;

  ChipBankProvider({bool autoLoad = true}) {
    if (autoLoad) refresh();
  }

  List<ChipType> get chips => _chips;
  ChipBankSummary get summary => _summary;
  bool get isEmpty => _chips.isEmpty;

  /// Live physical distribution, derived from the movement log.
  ChipHolding get bankHolding => ChipTrackingService.bankHolding();
  ChipHolding get removedHolding => ChipTrackingService.removedHolding();

  Map<String, ChipHolding> tableHoldings({String? sessionId}) =>
      ChipTrackingService.allTableHoldings(sessionId: sessionId);

  Map<String, ChipHolding> playerHoldings({String? sessionId}) =>
      ChipTrackingService.allPlayerHoldings(sessionId: sessionId);

  void refresh() {
    _chips = ChipBankService.allChips();
    _summary = ChipBankService.summary();
    notifyListeners();
  }

  /// Records a physical movement and refreshes derived figures.
  ///
  /// Chip movements are the ONLY thing this touches — no transaction, no
  /// player balance, no settlement.
  Future<void> recordMovement({
    required String chipTypeId,
    required int quantity,
    required ChipLocation from,
    required ChipLocation to,
    required ChipMovementReason reason,
    String? sessionId,
    String? transactionId,
    String? note,
  }) async {
    await ChipTrackingService.record(
      chipTypeId: chipTypeId,
      quantity: quantity,
      from: from,
      to: to,
      reason: reason,
      sessionId: sessionId,
      transactionId: transactionId,
      note: note,
    );
    refresh();
  }

  Future<void> recordDistribution({
    required Map<String, int> distribution,
    required ChipLocation from,
    required ChipLocation to,
    required ChipMovementReason reason,
    String? sessionId,
    String? transactionId,
    String? note,
  }) async {
    await ChipTrackingService.recordDistribution(
      distribution: distribution,
      from: from,
      to: to,
      reason: reason,
      sessionId: sessionId,
      transactionId: transactionId,
      note: note,
    );
    refresh();
  }

  Future<void> addChip({
    required double value,
    required int quantity,
    String? name,
    int? colorValue,
    String? note,
  }) async {
    await ChipBankService.addChip(
      value: value,
      quantity: quantity,
      name: name,
      colorValue: colorValue,
      note: note,
    );
    refresh();
  }

  Future<void> updateChip(
    String id, {
    double? value,
    int? quantity,
    String? name,
    int? colorValue,
    String? note,
    bool clearName = false,
    bool clearColor = false,
    bool clearNote = false,
  }) async {
    await ChipBankService.updateChip(
      id,
      value: value,
      quantity: quantity,
      name: name,
      colorValue: colorValue,
      note: note,
      clearName: clearName,
      clearColor: clearColor,
      clearNote: clearNote,
    );
    refresh();
  }

  Future<void> adjustQuantity(String id, int delta) async {
    await ChipBankService.adjustQuantity(id, delta);
    refresh();
  }

  Future<void> removeChip(String id) async {
    await ChipBankService.removeChip(id);
    refresh();
  }
}
