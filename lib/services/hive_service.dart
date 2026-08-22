import 'package:hive_flutter/hive_flutter.dart';
import 'package:flutter/foundation.dart' show debugPrint;

import '../models/bank_count.dart';
import '../models/chip_movement.dart';
import '../models/chip_type.dart';
import '../models/financial_event.dart';
import '../models/hand.dart';
import '../models/player.dart';
import '../models/player_identity.dart';
import '../models/session.dart';
import '../models/table_participation.dart';
import '../models/transaction.dart';
import 'chip_migration.dart';
import 'chip_tracking_service.dart';

/// Thrown when local storage genuinely cannot be initialized even after
/// attempting per-box recovery — surfaced to the UI as a clear, honest
/// error screen instead of letting the app crash silently on launch.
class StorageInitException implements Exception {
  final String message;
  StorageInitException(this.message);
  @override
  String toString() => message;
}

/// Central place that owns all Hive boxes.
/// Offline-first by design: everything lives on-device. Swapping this
/// service out for a Firebase-backed one later is the only change needed
/// to move online, since screens/providers only ever talk to this class.
class HiveService {
  static const sessionsBox = 'sessions_box';
  static const playersBox = 'players_box';
  static const transactionsBox = 'transactions_box';
  static const settingsBox = 'settings_box';

  /// Physical chip inventory. Its own box so the banker's chip case is
  /// never entangled with ledger data — a corrupted or reset inventory
  /// cannot affect a single transaction.
  static const chipsBox = 'chips_box';

  /// Append-only physical chip movement log. Separate box again: the
  /// audit trail must survive even if the inventory itself is reset.
  static const chipMovementsBox = 'chip_movements_box';

  /// Permanent player identities (`personId`). Fail-loud on corruption —
  /// silently wiping this box would orphan every linked seat and, later,
  /// every financial event attached to those ids.
  static const playerIdentitiesBox = 'player_identities_box';

  /// Append-only Financial Ledger. Fail-loud on corruption — a silent
  /// wipe would erase who owes whom. typeIds 12–14 live here.
  static const financialEventsBox = 'financial_events_box';

  /// Physical case count sheets (Phase 2b). Fail-loud on corruption —
  /// a silent wipe would destroy the baseline history of the case
  /// ledger. typeId 17 lives here.
  static const bankCountsBox = 'bank_counts_box';

  /// Table participations (Phase 6). Fail-loud on corruption — a
  /// silent wipe would orphan the participation links on the money
  /// legs. typeId 15 (plus 18/19 enums) lives here.
  static const participationsBox = 'participations_box';

  /// Completed hands (Phase 8). Fail-loud on corruption — a silent
  /// wipe would erase pot history. typeIds 20–22 live here.
  static const handsBox = 'hands_box';

  /// Boxes that must never be deleted to "recover". A corrupted identity,
  /// financial, count-sheet, participation or hand-history file is
  /// surfaced to the banker; the bytes stay on disk so a backup can
  /// still be taken off the device.
  static const Set<String> failLoudBoxes = {
    playerIdentitiesBox,
    financialEventsBox,
    bankCountsBox,
    participationsBox,
    handsBox,
  };

  static Future<void> init() async {
    try {
      await Hive.initFlutter();
    } catch (e) {
      // Nothing works if this fails — no box to recover, no partial
      // start possible. Surface it plainly rather than crash unexplained.
      throw StorageInitException(
        'Could not initialize local storage on this device: $e',
      );
    }

    Hive.registerAdapter(PlayerTagAdapter());
    Hive.registerAdapter(TransactionTypeAdapter());
    Hive.registerAdapter(SessionStatusAdapter());
    Hive.registerAdapter(AppCurrencyAdapter());
    Hive.registerAdapter(RakeModeAdapter());
    Hive.registerAdapter(SessionModeAdapter());
    Hive.registerAdapter(PlayerAdapter());
    Hive.registerAdapter(LedgerTransactionAdapter());
    Hive.registerAdapter(PokerSessionAdapter());
    Hive.registerAdapter(ChipTypeAdapter());
    Hive.registerAdapter(ChipMovementAdapter());
    Hive.registerAdapter(PlayerIdentityAdapter());
    Hive.registerAdapter(FinancialEventTypeAdapter());
    Hive.registerAdapter(PaymentMethodAdapter());
    Hive.registerAdapter(FinancialEventAdapter());
    Hive.registerAdapter(TableParticipationAdapter());
    Hive.registerAdapter(ParticipationStatusAdapter());
    Hive.registerAdapter(ParticipationCloseReasonAdapter());
    Hive.registerAdapter(BankCountAdapter());
    Hive.registerAdapter(HandKindAdapter());
    Hive.registerAdapter(HandStatusAdapter());
    Hive.registerAdapter(HandAdapter());

    // Each box is opened independently and, if corrupted, individually
    // reset — a bad write killed mid-save in one box (e.g. a phone dying
    // during a save) should not take the whole app down, and should not
    // force wiping data that was actually fine. This is real recovery,
    // not just a caught exception: the app still launches successfully
    // afterward, at the cost of only the specific corrupted box's data.
    await _openBoxSafely<PokerSession>(sessionsBox, typed: true);
    await _openBoxSafely<Player>(playersBox, typed: true);
    await _openBoxSafely<LedgerTransaction>(transactionsBox, typed: true);
    await _openBoxSafely<dynamic>(settingsBox, typed: false);
    await _openBoxSafely<ChipType>(chipsBox, typed: true);
    await _openBoxSafely<ChipMovement>(chipMovementsBox, typed: true);

    // Identity and (later) financial data are not recoverable by wiping.
    // If either file is unreadable the app stops and tells the banker,
    // leaving the file untouched.
    await openBoxFailLoud<PlayerIdentity>(playerIdentitiesBox, typed: true);
    await openBoxFailLoud<FinancialEvent>(financialEventsBox, typed: true);
    await openBoxFailLoud<BankCount>(bankCountsBox, typed: true);
    await openBoxFailLoud<TableParticipation>(participationsBox, typed: true);
    await openBoxFailLoud<Hand>(handsBox, typed: true);

    // The Chip Bank screen must show what is LEFT in the case, not the
    // starting count. This teaches ChipBankService to fold the movement
    // log; done here (rather than by an import) to avoid a cycle.
    ChipTrackingService.installBankResolver();

    // Phase 2a — converging seat→person chip-reference migration.
    //
    // ROLLOUT SEAM (D2): per the approved Phase 0 design the pass runs
    // automatically at startup, idempotently, with an automatic
    // pre-migration backup on the first run. If the rollout control is
    // changed to a one-time user-confirmed gate, move this single call
    // behind that confirmation (optionally keeping a pending-state
    // banner) — the engine is rollout-neutral.
    //
    // A failure must never block launch: the data stays fully
    // consistent and the pass re-runs on the next start.
    try {
      await ChipMigration.run();
    } catch (e) {
      // Surfaced through the stored report (chip audit screen).
      debugPrint('ChipMigration.run() failed: $e');
    }
  }

  static Future<void> _openBoxSafely<T>(String name, {required bool typed}) async {
    try {
      if (typed) {
        await Hive.openBox<T>(name);
      } else {
        await Hive.openBox(name);
      }
    } catch (_) {
      // Corrupted box on disk — delete just this one and start it fresh.
      try {
        await Hive.deleteBoxFromDisk(name);
        if (typed) {
          await Hive.openBox<T>(name);
        } else {
          await Hive.openBox(name);
        }
      } catch (e) {
        throw StorageInitException(
          "Local storage for '$name' could not be opened or recovered: $e",
        );
      }
    }
  }

  /// Opens a box. On failure the existing file is left untouched and a
  /// [StorageInitException] is thrown. Used for identity and financial
  /// storage — those must never be silently wiped (C-3).
  static Future<void> openBoxFailLoud<T>(
    String name, {
    required bool typed,
  }) async {
    try {
      if (typed) {
        await Hive.openBox<T>(name);
      } else {
        await Hive.openBox(name);
      }
    } catch (e) {
      throw StorageInitException(
        "Local storage for '$name' could not be opened. "
        'The existing file was left untouched so no data is lost. '
        'Copy it off the device or restore from a backup before retrying. '
        'Detail: $e',
      );
    }
  }

  static bool isOpen(String name) => Hive.isBoxOpen(name);

  static Box<PokerSession> get sessions => Hive.box<PokerSession>(sessionsBox);
  static Box<Player> get players => Hive.box<Player>(playersBox);
  static Box<LedgerTransaction> get transactions =>
      Hive.box<LedgerTransaction>(transactionsBox);
  static Box get settings => Hive.box(settingsBox);
  static Box<ChipType> get chips => Hive.box<ChipType>(chipsBox);
  static Box<ChipMovement> get chipMovements =>
      Hive.box<ChipMovement>(chipMovementsBox);
  static Box<PlayerIdentity> get playerIdentities =>
      Hive.box<PlayerIdentity>(playerIdentitiesBox);
  static Box<FinancialEvent> get financialEvents =>
      Hive.box<FinancialEvent>(financialEventsBox);
  static Box<BankCount> get bankCounts => Hive.box<BankCount>(bankCountsBox);
  static Box<TableParticipation> get participations =>
      Hive.box<TableParticipation>(participationsBox);
  static Box<Hand> get hands => Hive.box<Hand>(handsBox);
}
