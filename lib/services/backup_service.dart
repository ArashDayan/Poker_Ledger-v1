import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import '../models/chip_movement.dart';
import '../models/chip_type.dart';
import '../models/player.dart';
import '../models/player_identity.dart';
import '../models/session.dart';
import '../models/transaction.dart';
import 'hive_service.dart';
import 'player_history_service.dart';
import 'player_registry_service.dart';

/// Why a restored identity cannot be applied automatically.
enum IdentityConflictKind {
  /// Same `personId` already exists locally, but the display name
  /// (normalised) does not match. Overwriting would relabel a person;
  /// skipping would drop the backup spelling. The banker must choose.
  sameIdDifferentName,

  /// Backup identity has a different id than a local identity that
  /// shares the same normalised name. Auto-merging those ids would
  /// combine two financial accounts later. They stay separate unless
  /// the banker says they are different people (import both) or that
  /// the incoming one should be skipped.
  sameNameDifferentId,
}

/// One identity the restore refused to apply without a decision.
class IdentityConflict {
  final IdentityConflictKind kind;
  final PlayerIdentity incoming;
  final PlayerIdentity local;

  const IdentityConflict({
    required this.kind,
    required this.incoming,
    required this.local,
  });
}

/// What the banker chose for one [IdentityConflict].
enum IdentityResolutionAction {
  /// Leave the local identity as it is. Incoming is discarded.
  keepLocal,

  /// Write the backup identity. For [IdentityConflictKind.sameIdDifferentName]
  /// this overwrites the local record (same id). For
  /// [IdentityConflictKind.sameNameDifferentId] this imports the incoming
  /// identity as a second person — it does NOT remapping-merge the ids.
  takeBackup,

  /// Import the incoming identity alongside the local one. Only valid
  /// for [IdentityConflictKind.sameNameDifferentId] (two people, same
  /// name). Same-id conflicts cannot be "both".
  keepBoth,
}

class IdentityResolution {
  final IdentityConflict conflict;
  final IdentityResolutionAction action;

  const IdentityResolution({
    required this.conflict,
    required this.action,
  });
}

/// Full local backup/restore, independent of PDF/CSV reports (those are
/// per-session and lossy by design — signatures, voided transactions,
/// etc. are dropped for readability). This is the "everything, exactly
/// as stored" backup, meant to move data between devices or recover from
/// an accidental data-clear.
class BackupService {
  /// Bumped to 5 when player identities and the player-registry
  /// (blacklist / classification) were added to the portable payload.
  /// Older backups still restore correctly — a missing block is simply
  /// skipped and the current data for it is left alone.
  static const formatVersion = 5;

  /// Kept so existing call sites that read the private-looking name
  /// still compile if any were copied; the public name is [formatVersion].
  static const _formatVersion = formatVersion;

  /// Settings keys that are safe and useful to carry between devices.
  /// The PIN hash is deliberately EXCLUDED: restoring someone else's
  /// backup must never silently change the lock on this device, and a
  /// hash in a plain-text JSON file is an unnecessary exposure.
  ///
  /// Player-registry maps live in the settings box and were previously
  /// omitted, so every backup taken before v5 silently dropped the
  /// blacklist and person-level classification (C-4).
  static const portableSettingKeys = [
    'language',
    'currency',
    'privacy_mode',
    'sound_effects_enabled',
    PlayerRegistryService.blacklistKey,
    PlayerRegistryService.tagKey,
    PlayerRegistryService.noteKey,
  ];

  static const _portableSettingKeys = portableSettingKeys;

  /// Builds the JSON payload without touching the filesystem. Tests use
  /// this directly so they do not need path_provider.
  static Map<String, dynamic> exportPayload() {
    return {
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
      // Permanent identities. Separate from player rows so a seat can
      // be restored even when the identity needs a conflict decision.
      'playerIdentities': _exportIdentities(),
      // Reserved for Step 2. Always present from v5 so a financial
      // backup from a future build is a known key, never a surprise
      // field that an older restore would drop on the floor unnoticed.
      // Step 0/1 never writes financial records, so this is empty.
      'financialEvents': _exportFinancialEvents(),
      // Session JSON already carries tables, house rules, quick-rake
      // slots and timer state; player JSON carries seat, table id and
      // the sample signature; transaction JSON carries the captured
      // signature, notes, edit and void flags. So "everything" here is
      // those three collections plus app-level preferences.
      'settings': {
        for (final k in _portableSettingKeys)
          if (HiveService.settings.get(k) != null) k: _jsonSafe(HiveService.settings.get(k)),
      },
    };
  }

  static List<Map<String, dynamic>> _exportIdentities() {
    try {
      return HiveService.playerIdentities.values
          .map((i) => i.toJson())
          .toList();
    } catch (_) {
      return const [];
    }
  }

  static List<Map<String, dynamic>> _exportFinancialEvents() {
    // Step 2 will replace this with FinancialEvent.toJson(). Until that
    // type exists we refuse to serialise whatever happens to sit in the
    // reserved box — writing untyped maps now would poison a later
    // typed open.
    try {
      if (HiveService.financialEvents.isEmpty) return const [];
    } catch (_) {
      return const [];
    }
    return const [];
  }

  /// Hive maps are not always JSON-encodable (internal types). Copy
  /// through JSON so a blacklist map of string→bool survives a file
  /// round-trip rather than throwing at encode time.
  static dynamic _jsonSafe(dynamic value) {
    if (value == null) return null;
    if (value is num || value is String || value is bool) return value;
    if (value is Map) {
      return {
        for (final e in value.entries) e.key.toString(): _jsonSafe(e.value),
      };
    }
    if (value is Iterable) return value.map(_jsonSafe).toList();
    return value.toString();
  }

  static Future<File> exportBackup() async {
    final data = exportPayload();
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
  ///
  /// Identities are the exception (D-2): a conflicting identity is NOT
  /// written. The result lists the conflicts and the caller must apply
  /// an explicit [IdentityResolution] for each one.
  static Future<BackupImportResult> importBackup(File file) async {
    final raw = await file.readAsString();
    final Map<String, dynamic> data = jsonDecode(raw) as Map<String, dynamic>;
    return importPayload(data);
  }

  static Future<BackupImportResult> importPayload(
    Map<String, dynamic> data,
  ) async {
    final version = (data['formatVersion'] as num?)?.toInt() ?? 1;

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

    final identityOutcome = await _importIdentities(
      (data['playerIdentities'] as List? ?? []).cast<Map<String, dynamic>>(),
    );

    // Financial events are reserved. Until FinancialEvent exists we
    // must not write untyped maps into the fail-loud box — a typed
    // open in Step 2 would then fail loud and lock the banker out.
    final financialReserved =
        (data['financialEvents'] as List? ?? []).length;

    return BackupImportResult(
      formatVersion: version,
      sessionsImported: sessions.length,
      playersImported: players.length,
      transactionsImported: transactions.length,
      settingsImported: settingsImported,
      chipsImported: chips.length,
      chipMovementsImported: movements.length,
      identitiesImported: identityOutcome.imported,
      identitiesSkipped: identityOutcome.skipped,
      identityConflicts: identityOutcome.conflicts,
      financialEventsReserved: financialReserved,
    );
  }

  static Future<_IdentityImport> _importIdentities(
    List<Map<String, dynamic>> raw,
  ) async {
    if (raw.isEmpty) {
      return const _IdentityImport(imported: 0, skipped: 0, conflicts: []);
    }

    final incoming = raw.map(PlayerIdentity.fromJson).toList();
    final conflicts = detectIdentityConflicts(incoming);

    final conflictIds = conflicts.map((c) => c.incoming.id).toSet();
    var imported = 0;
    var skipped = 0;

    try {
      for (final identity in incoming) {
        if (conflictIds.contains(identity.id)) {
          skipped++;
          continue;
        }
        await HiveService.playerIdentities.put(identity.id, identity);
        imported++;
      }
    } catch (_) {
      // Identity box not open (degraded tests). Treat everything as
      // skipped rather than crashing a chip-only restore.
      return _IdentityImport(
        imported: 0,
        skipped: incoming.length,
        conflicts: conflicts,
      );
    }

    return _IdentityImport(
      imported: imported,
      skipped: skipped,
      conflicts: conflicts,
    );
  }

  /// Pure detection so tests (and the restore UI) can inspect conflicts
  /// without writing anything.
  static List<IdentityConflict> detectIdentityConflicts(
    List<PlayerIdentity> incoming,
  ) {
    final conflicts = <IdentityConflict>[];
    Map<String, PlayerIdentity> localById = {};
    try {
      for (final i in HiveService.playerIdentities.values) {
        localById[i.id] = i;
      }
    } catch (_) {
      return const [];
    }

    final localByName = <String, PlayerIdentity>{};
    for (final i in localById.values) {
      final key = PlayerHistoryService.normaliseName(i.displayName);
      if (key.isEmpty) continue;
      localByName.putIfAbsent(key, () => i);
    }

    for (final incomingIdentity in incoming) {
      final localSameId = localById[incomingIdentity.id];
      if (localSameId != null) {
        final localKey =
            PlayerHistoryService.normaliseName(localSameId.displayName);
        final incomingKey =
            PlayerHistoryService.normaliseName(incomingIdentity.displayName);
        if (localKey != incomingKey) {
          conflicts.add(IdentityConflict(
            kind: IdentityConflictKind.sameIdDifferentName,
            incoming: incomingIdentity,
            local: localSameId,
          ));
        }
        // Same id + same normalised name: idempotent overwrite is safe
        // and is applied by the import loop (not a conflict).
        continue;
      }

      final key =
          PlayerHistoryService.normaliseName(incomingIdentity.displayName);
      final localSameName = key.isEmpty ? null : localByName[key];
      if (localSameName != null && localSameName.id != incomingIdentity.id) {
        conflicts.add(IdentityConflict(
          kind: IdentityConflictKind.sameNameDifferentId,
          incoming: incomingIdentity,
          local: localSameName,
        ));
      }
    }
    return conflicts;
  }

  /// Applies banker decisions for identities that [importPayload] left
  /// unwritten. Never remaps a local personId onto a different id —
  /// that would be a silent merge.
  static Future<int> applyIdentityResolutions(
    List<IdentityResolution> resolutions,
  ) async {
    var applied = 0;
    for (final resolution in resolutions) {
      final incoming = resolution.conflict.incoming;
      switch (resolution.action) {
        case IdentityResolutionAction.keepLocal:
          break;
        case IdentityResolutionAction.takeBackup:
          await HiveService.playerIdentities.put(incoming.id, incoming);
          applied++;
          break;
        case IdentityResolutionAction.keepBoth:
          if (resolution.conflict.kind ==
              IdentityConflictKind.sameIdDifferentName) {
            // Same id cannot be two people. Refuse rather than invent
            // a new id — inventing one would detach restored seats.
            break;
          }
          await HiveService.playerIdentities.put(incoming.id, incoming);
          applied++;
          break;
      }
    }
    return applied;
  }
}

class _IdentityImport {
  final int imported;
  final int skipped;
  final List<IdentityConflict> conflicts;
  const _IdentityImport({
    required this.imported,
    required this.skipped,
    required this.conflicts,
  });
}

class BackupImportResult {
  final int formatVersion;
  final int sessionsImported;
  final int playersImported;
  final int transactionsImported;
  final int settingsImported;
  final int chipsImported;
  final int chipMovementsImported;
  final int identitiesImported;
  final int identitiesSkipped;
  final List<IdentityConflict> identityConflicts;
  /// Count of financial events present in the file but not written.
  /// Step 2 will persist these; writing them now would poison the box.
  final int financialEventsReserved;

  const BackupImportResult({
    this.formatVersion = 0,
    required this.sessionsImported,
    required this.playersImported,
    required this.transactionsImported,
    this.settingsImported = 0,
    this.chipsImported = 0,
    this.chipMovementsImported = 0,
    this.identitiesImported = 0,
    this.identitiesSkipped = 0,
    this.identityConflicts = const [],
    this.financialEventsReserved = 0,
  });

  bool get requiresIdentityResolution => identityConflicts.isNotEmpty;
}
