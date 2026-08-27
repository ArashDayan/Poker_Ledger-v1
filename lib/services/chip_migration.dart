import '../models/chip_movement.dart';
import 'backup_service.dart';
import 'hive_service.dart';

/// One unlinked legacy seat still carrying chip movements.
class UnmigratedSeat {
  final String seatId;
  final String name;
  final String sessionId;
  final int movementCount;
  final double totalValue;

  const UnmigratedSeat({
    required this.seatId,
    required this.name,
    required this.sessionId,
    required this.movementCount,
    required this.totalValue,
  });

  Map<String, dynamic> toMap() => {
        'seatId': seatId,
        'name': name,
        'sessionId': sessionId,
        'movementCount': movementCount,
        'totalValue': totalValue,
      };

  static UnmigratedSeat fromMap(Map<String, dynamic> m) => UnmigratedSeat(
        seatId: m['seatId'] as String,
        name: m['name'] as String? ?? '',
        sessionId: m['sessionId'] as String? ?? '',
        movementCount: (m['movementCount'] as num?)?.toInt() ?? 0,
        totalValue: (m['totalValue'] as num?)?.toDouble() ?? 0,
      );
}

/// Result of one converging migration pass.
class ChipMigrationReport {
  /// Movements re-keyed by THIS run (0 on an already-converged device).
  final int rekeyedThisRun;

  /// Movements re-keyed in total (rows carrying a legacy reference).
  final int totalRekeyed;

  /// Seats with chip movements but NO personId — never re-keyable
  /// automatically. Identities are never invented; the banker links the
  /// seat to an identity later and the next pass picks the rows up.
  final List<UnmigratedSeat> unmigrated;

  /// Set when this run finished a pass that was interrupted by a crash.
  final bool recoveredFromInterruptedRun;

  /// Where the automatic pre-migration backup was written (first run
  /// only). Null afterwards (or when the backup could not be written).
  final String? preMigrationBackupPath;

  /// Set when the automatic pre-migration backup could not be written.
  /// NON-FATAL on purpose: a backup failure (full disk, missing platform
  /// path) must never block the converging pass — but it is reported so
  /// the banker can take a manual backup.
  final String? backupWarning;

  /// Last error, if the pass failed part-way (the app still launches;
  /// the pass is re-run on the next start — it is idempotent).
  final String? error;

  final DateTime ranAt;

  ChipMigrationReport({
    required this.rekeyedThisRun,
    required this.totalRekeyed,
    required this.unmigrated,
    required this.recoveredFromInterruptedRun,
    required this.preMigrationBackupPath,
    this.backupWarning,
    required this.error,
    DateTime? ranAt,
  }) : ranAt = ranAt ?? DateTime.now();

  bool get hasUnmigrated => unmigrated.isNotEmpty;

  Map<String, dynamic> toMap() => {
        'rekeyedThisRun': rekeyedThisRun,
        'totalRekeyed': totalRekeyed,
        'unmigrated': unmigrated.map((u) => u.toMap()).toList(),
        'recoveredFromInterruptedRun': recoveredFromInterruptedRun,
        'preMigrationBackupPath': preMigrationBackupPath,
        'backupWarning': backupWarning,
        'error': error,
        'ranAt': ranAt.toIso8601String(),
      };

  static ChipMigrationReport fromMap(Map<String, dynamic> m) =>
      ChipMigrationReport(
        rekeyedThisRun: (m['rekeyedThisRun'] as num?)?.toInt() ?? 0,
        totalRekeyed: (m['totalRekeyed'] as num?)?.toInt() ?? 0,
        unmigrated: (m['unmigrated'] as List? ?? [])
            .map((e) => UnmigratedSeat.fromMap(e as Map<String, dynamic>))
            .toList(),
        recoveredFromInterruptedRun:
            m['recoveredFromInterruptedRun'] as bool? ?? false,
        preMigrationBackupPath: m['preMigrationBackupPath'] as String?,
        backupWarning: m['backupWarning'] as String?,
        error: m['error'] as String?,
        ranAt: DateTime.tryParse(m['ranAt']?.toString() ?? '') ??
            DateTime.now(),
      );
}

/// Phase 2a — one-shot, converging seat→person chip-reference migration.
///
/// WHY IT IS CONVERGING (not just one-shot)
/// The pass re-keys every chip movement whose holder reference is a
/// session SEAT that is linked to a person. It is idempotent (rows
/// already re-keyed carry their original reference in `legacyFrom` /
/// `legacyTo` and are skipped) and may safely run again on any start —
/// which also covers the downgrade-and-re-upgrade path, where an older
/// app version may have written fresh seat-scoped rows.
///
/// SAFETY
///   * A pre-migration backup is written automatically before the FIRST
///     pass touches data (kept on disk; path recorded in the report).
///   * A `chip_migration_in_progress` marker is set before the first
///     write and cleared after the last; a crash in between leaves the
///     marker, and the next start re-runs the pass to completion.
///   * Each row's re-key is a single record update; the ORIGINAL
///     reference is stored permanently on the record (audit).
///   * Unlinked seats (no personId) are NEVER re-keyed and never
///     assigned an identity — they are reported, not invented.
///   * The pass never changes chip quantities, values, reasons,
///     sessions or any financial record. The case fold is provably
///     unchanged (only `player:` holder references move).
///
/// ROLLOUT
/// Per the approved Phase 0 design the pass runs automatically at
/// startup. If the rollout control (D2) is changed to a user-confirmed
/// gate, the single call site in `HiveService.init()` moves behind the
/// confirmation — the engine itself is rollout-neutral.
class ChipMigration {
  ChipMigration._();

  static const versionKey = 'chip_schema_version';
  static const inProgressKey = 'chip_migration_in_progress';
  static const reportKey = 'chip_migration_report';

  static const legacyVersion = 1;
  static const currentVersion = 2;

  /// Runs one converging pass. Safe to call on every start.
  static Future<ChipMigrationReport> run() async {
    final settings = HiveService.settings;
    final interruptedBefore = settings.get(inProgressKey) == true;
    settings.put(inProgressKey, true);
    String? backupPath;
    String? backupWarning;
    try {
      final version = (settings.get(versionKey) as num?)?.toInt() ??
          legacyVersion;
      if (version < currentVersion) {
        // First pass on this device: back up BEFORE touching anything.
        // A backup failure is NON-FATAL (the pass still converges), but
        // it is reported so a manual backup can be taken.
        try {
          final backup = await BackupService.exportBackup();
          backupPath = backup.path;
        } catch (e) {
          backupWarning = 'Pre-migration backup failed: $e';
        }
        settings.put(versionKey, currentVersion);
      }

      // Seat → person map. Only LINKED seats are re-keyable.
      final seatToPerson = <String, String>{};
      final seatName = <String, String>{};
      final seatSession = <String, String>{};
      for (final p in HiveService.players.values) {
        if (p.personId == null || p.personId!.isEmpty) continue;
        seatToPerson[p.id] = p.personId!;
        seatName[p.id] = p.name;
        seatSession[p.id] = p.sessionId;
      }

      var rekeyedThisRun = 0;
      for (final m in HiveService.chipMovements.values.toList()) {
        if (m.legacyFrom != null || m.legacyTo != null) continue;
        final from = ChipLocation.decode(m.fromLocation);
        final to = ChipLocation.decode(m.toLocation);
        final fromPerson =
            from.isPlayer ? seatToPerson[from.refId] : null;
        final toPerson = to.isPlayer ? seatToPerson[to.refId] : null;
        if (fromPerson == null && toPerson == null) continue;

        // Reference refinement only: the physical movement is
        // unchanged; the original reference is kept on the record.
        if (fromPerson != null) {
          m.legacyFrom = m.fromLocation;
          m.fromLocation = 'player:$fromPerson';
        }
        if (toPerson != null) {
          m.legacyTo = m.toLocation;
          m.toLocation = 'player:$toPerson';
        }
        await m.save();
        rekeyedThisRun++;
      }

      var totalRekeyed = 0;
      for (final m in HiveService.chipMovements.values) {
        if (m.legacyFrom != null || m.legacyTo != null) totalRekeyed++;
      }

      final unmigrated = _unmigratedSeats();

      final report = ChipMigrationReport(
        rekeyedThisRun: rekeyedThisRun,
        totalRekeyed: totalRekeyed,
        unmigrated: unmigrated,
        recoveredFromInterruptedRun: interruptedBefore,
        preMigrationBackupPath: backupPath,
        backupWarning: backupWarning,
        error: null,
      );
      settings.put(reportKey, report.toMap());
      settings.put(inProgressKey, false);
      return report;
    } catch (e) {
      // The marker stays set on purpose: the next start re-runs the
      // pass. The app must still launch — the banker keeps working on
      // the (still fully consistent) data, and the error is reported.
      final report = ChipMigrationReport(
        rekeyedThisRun: 0,
        totalRekeyed: 0,
        unmigrated: _unmigratedSeats(),
        recoveredFromInterruptedRun: interruptedBefore,
        preMigrationBackupPath: null,
        backupWarning: backupWarning,
        error: '$e',
      );
      try {
        settings.put(reportKey, report.toMap());
      } catch (_) {}
      rethrow;
    }
  }

  /// Seats with player-kind movements but no personId — the parts of
  /// the history no automatic pass can re-key.
  static List<UnmigratedSeat> _unmigratedSeats() {
    final unlinkedSeats = <String, ({String name, String session})>{};
    for (final p in HiveService.players.values) {
      if (p.personId != null && p.personId!.isNotEmpty) continue;
      unlinkedSeats[p.id] = (name: p.name, session: p.sessionId);
    }
    if (unlinkedSeats.isEmpty) return const [];

    final counts = <String, int>{};
    final values = <String, double>{};
    for (final m in HiveService.chipMovements.values) {
      for (final loc in [ChipLocation.decode(m.fromLocation),
          ChipLocation.decode(m.toLocation)]) {
        if (!loc.isPlayer || loc.refId == null) continue;
        final seatId = loc.refId!;
        if (!unlinkedSeats.containsKey(seatId)) continue;
        counts[seatId] = (counts[seatId] ?? 0) + 1;
        values[seatId] = (values[seatId] ?? 0) + m.totalValue;
      }
    }
    return unlinkedSeats.entries
        .where((e) => (counts[e.key] ?? 0) > 0)
        .map((e) => UnmigratedSeat(
              seatId: e.key,
              name: e.value.name,
              sessionId: e.value.session,
              movementCount: counts[e.key]!,
              totalValue: values[e.key]!,
            ))
        .toList()
      ..sort((a, b) => b.totalValue.compareTo(a.totalValue));
  }

  /// The stored report, if any.
  static ChipMigrationReport? storedReport() {
    final raw = HiveService.settings.get(reportKey);
    if (raw is Map) return ChipMigrationReport.fromMap(Map.from(raw));
    return null;
  }

  /// True while a pass was interrupted (crash) and not yet completed.
  static bool get interruptedRunPending =>
      HiveService.settings.get(inProgressKey) == true;

  /// Whether any unlinked legacy seat still carries chip movements.
  static bool get hasUnmigratedLegacy => _unmigratedSeats().isNotEmpty;

  /// The unlinked seats still carrying chip movements (report data).
  static List<UnmigratedSeat> unmigratedSeats() => _unmigratedSeats();
}
