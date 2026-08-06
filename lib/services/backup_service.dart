import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import '../models/chip_movement.dart';
import '../models/chip_type.dart';
import '../models/player.dart';
import '../models/session.dart';
import '../models/transaction.dart';
import 'hive_service.dart';

/// Full local backup/restore, independent of PDF/CSV reports (those are
/// per-session and lossy by design — signatures, voided transactions,
/// etc. are dropped for readability). This is the "everything, exactly
/// as stored" backup, meant to move data between devices or recover from
/// an accidental data-clear.
class BackupService {
  /// Bumped to 4 when the physical chip movement log was added. Older
  /// backups still restore correctly — a missing block is simply skipped
  /// and the current data for it is left alone.
  static const _formatVersion = 4;

  /// Settings keys that are safe and useful to carry between devices.
  /// The PIN hash is deliberately EXCLUDED: restoring someone else's
  /// backup must never silently change the lock on this device, and a
  /// hash in a plain-text JSON file is an unnecessary exposure.
  static const _portableSettingKeys = [
    'language',
    'currency',
    'privacy_mode',
    'sound_effects_enabled',
  ];

  static Future<File> exportBackup() async {
    final data = {
      'formatVersion': _formatVersion,
      'exportedAt': DateTime.now().toIso8601String(),
      'sessions': HiveService.sessions.values.map((s) => s.toJson()).toList(),
      'players': HiveService.players.values.map((p) => p.toJson()).toList(),
      'transactions':
          HiveService.transactions.values.map((t) => t.toJson()).toList(),
      // Physical chip inventory. Included so a banker moving to a new
      // phone does not have to recount their case by hand.
      'chips': HiveService.chips.values.map((c) => c.toJson()).toList(),
      // The physical movement audit log. Included so the chip trail
      // survives a device move — an audit you can lose is not an audit.
      'chipMovements':
          HiveService.chipMovements.values.map((m) => m.toJson()).toList(),
      // Session JSON already carries tables, house rules, quick-rake
      // slots and timer state; player JSON carries seat, table id and
      // the sample signature; transaction JSON carries the captured
      // signature, notes, edit and void flags. So "everything" here is
      // those three collections plus app-level preferences.
      'settings': {
        for (final k in _portableSettingKeys)
          if (HiveService.settings.get(k) != null) k: HiveService.settings.get(k),
      },
    };
    final dir = await getApplicationDocumentsDirectory();
    final stamp = DateTime.now().toIso8601String().replaceAll(RegExp(r'[:.]'), '-');
    final file = File('${dir.path}/poker_ledger_backup_$stamp.json');
    await file.writeAsString(const JsonEncoder.withIndent('  ').convert(data));
    return file;
  }

  /// Restores from a backup file. Uses `put` with each record's own id,
  /// so re-importing the same backup twice is safe (idempotent) rather
  /// than creating duplicates. Existing data with different ids is kept,
  /// not cleared — this is a merge, not a wipe.
  static Future<BackupImportResult> importBackup(File file) async {
    final raw = await file.readAsString();
    final Map<String, dynamic> data = jsonDecode(raw) as Map<String, dynamic>;

    final sessions = (data['sessions'] as List? ?? [])
        .cast<Map<String, dynamic>>()
        .map(PokerSession.fromJson)
        .toList();
    final players = (data['players'] as List? ?? [])
        .cast<Map<String, dynamic>>()
        .map(Player.fromJson)
        .toList();
    final transactions = (data['transactions'] as List? ?? [])
        .cast<Map<String, dynamic>>()
        .map(LedgerTransaction.fromJson)
        .toList();

    for (final s in sessions) {
      await HiveService.sessions.put(s.id, s);
    }
    for (final p in players) {
      await HiveService.players.put(p.id, p);
    }
    for (final t in transactions) {
      await HiveService.transactions.put(t.id, t);
    }

    // Chip inventory (v3+ backups). Absent in older files, in which case
    // the existing inventory is left exactly as it is.
    final chips = (data['chips'] as List? ?? [])
        .cast<Map<String, dynamic>>()
        .map(ChipType.fromJson)
        .toList();
    for (final c in chips) {
      await HiveService.chips.put(c.id, c);
    }

    // Chip movement log (v4+ backups).
    final movements = (data['chipMovements'] as List? ?? [])
        .cast<Map<String, dynamic>>()
        .map(ChipMovement.fromJson)
        .toList();
    for (final m in movements) {
      await HiveService.chipMovements.put(m.id, m);
    }

    // Preferences (v2+ backups only). Restoring an older backup leaves
    // the current settings untouched rather than resetting them.
    var settingsImported = 0;
    final settings = data['settings'];
    if (settings is Map) {
      for (final k in _portableSettingKeys) {
        if (!settings.containsKey(k)) continue;
        await HiveService.settings.put(k, settings[k]);
        settingsImported++;
      }
    }

    return BackupImportResult(
      sessionsImported: sessions.length,
      playersImported: players.length,
      transactionsImported: transactions.length,
      settingsImported: settingsImported,
      chipsImported: chips.length,
      chipMovementsImported: movements.length,
    );
  }
}

class BackupImportResult {
  final int sessionsImported;
  final int playersImported;
  final int transactionsImported;
  final int settingsImported;
  final int chipsImported;
  final int chipMovementsImported;
  const BackupImportResult({
    required this.sessionsImported,
    required this.playersImported,
    required this.transactionsImported,
    this.settingsImported = 0,
    this.chipsImported = 0,
    this.chipMovementsImported = 0,
  });
}
