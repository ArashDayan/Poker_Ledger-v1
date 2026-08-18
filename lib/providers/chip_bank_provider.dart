import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';

import '../models/chip_movement.dart';
import '../models/chip_type.dart';
import '../services/box_watch_hub.dart';
import '../services/chip_bank_service.dart';
import '../services/chip_tracking_service.dart';
import '../services/hive_service.dart';

/// Severity of a low-inventory warning.
enum ChipBankAlert {
  /// Half the starting inventory is gone.
  low,

  /// Only 30% or less remains — the banker may be unable to pay out.
  critical,
}

/// Exposes the chip inventory to the widget tree.
///
/// Thin by design, matching the other providers: all rules live in
/// [ChipBankService]. Independent of SessionProvider — it neither reads
/// nor notifies it, so chip edits can never trigger a ledger rebuild or
/// vice versa.
class ChipBankProvider extends ChangeNotifier {
  List<ChipType> _chips = const [];
  ChipBankSummary _summary = ChipBankSummary.empty;
  late final BoxWatchHub _watchHub;
  bool _disposed = false;

  ChipBankProvider({bool autoLoad = true}) {
    _watchHub = BoxWatchHub(onEvent: () {
      if (!_disposed) refresh();
    });
    attachWatchers();
    if (autoLoad) refresh();
  }

  bool get watchersHealthy =>
      _watchHub.isAttached('chips') && _watchHub.isAttached('chipMovements');

  Set<String> get failedWatcherNames => _watchHub.failedNames;

  bool attachWatchers() {
    if (_disposed) return false;
    _watchHub.attach('chips', () => HiveService.chips.watch());
    _watchHub.attach(
        'chipMovements', () => HiveService.chipMovements.watch());
    return watchersHealthy;
  }

  @override
  void dispose() {
    _disposed = true;
    _watchHub.dispose();
    super.dispose();
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

  // ---- Low-inventory alerts -------------------------------------
  //
  // Fired when the Bank's CURRENT total chip value crosses down through
  // 50% and then 30% of its STARTING value. Measured by value, not chip
  // count, so a case full of $5s cannot mask a drained bank.

  static const warnThreshold = 0.50;
  static const criticalThreshold = 0.30;

  static const _warnKey = 'chip_bank_warn_fired';
  static const _critKey = 'chip_bank_crit_fired';

  /// One-shot alert to show, or null. Consuming it clears it, so a
  /// rebuild cannot re-raise the same alert — the flag is persisted, so
  /// even an app restart will not spam the banker.
  ///
  /// If inventory later rises back above a threshold the flag resets, so
  /// crossing down again legitimately alerts again.
  /// Deliberately reads the fraction LIVE rather than from the cached
  /// [_summary]. Void, undo and edit apply their chip reversals through
  /// the service directly, without going via this provider, so the
  /// cached summary can legitimately be stale at the moment the ticker
  /// polls. Missing a genuine low-inventory crossing is a far worse
  /// failure than recomputing a fold over the movement log once a
  /// second on a home-game-sized dataset.
  ChipBankAlert? consumeAlert() {
    final fraction = ChipTrackingService.bankRemainingFraction();
    if (fraction == null) return null;

    final box = _settings;
    final warnFired = box?.get(_warnKey, defaultValue: false) as bool? ?? false;
    final critFired = box?.get(_critKey, defaultValue: false) as bool? ?? false;

    // Recovered above a threshold: re-arm it.
    if (fraction > warnThreshold && warnFired) box?.put(_warnKey, false);
    if (fraction > criticalThreshold && critFired) box?.put(_critKey, false);

    if (fraction <= criticalThreshold && !critFired) {
      box?.put(_critKey, true);
      // Crossing straight past 50% to 30% should not queue two alerts.
      box?.put(_warnKey, true);
      return ChipBankAlert.critical;
    }
    if (fraction <= warnThreshold && !warnFired) {
      box?.put(_warnKey, true);
      return ChipBankAlert.low;
    }
    return null;
  }

  Box? get _settings {
    try {
      return HiveService.settings;
    } catch (_) {
      return null; // boxes not open (unit tests) — alerts simply idle
    }
  }

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
