// Step 0 — data safety: backup v5, player-registry inclusion, fail-loud
// identity/financial boxes, and D-2 identity conflict detection.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:poker_ledger/models/bank_count.dart';
import 'package:poker_ledger/models/chip_movement.dart';
import 'package:poker_ledger/models/chip_type.dart';
import 'package:poker_ledger/models/enums.dart';
import 'package:poker_ledger/models/financial_event.dart';
import 'package:poker_ledger/models/player.dart';
import 'package:poker_ledger/models/player_identity.dart';
import 'package:poker_ledger/models/session.dart';
import 'package:poker_ledger/models/transaction.dart';
import 'package:poker_ledger/services/backup_service.dart';
import 'package:poker_ledger/services/hive_service.dart';
import 'package:poker_ledger/services/player_identity_service.dart';
import 'package:poker_ledger/services/player_registry_service.dart';

import 'test_helper.dart';

late Directory _tmp;

Future<void> _open() async {
  _tmp = await Directory.systemTemp.createTemp('pl_backup_v5_');
  Hive.init(_tmp.path);
  registerTestAdapters();
  await Hive.openBox<PokerSession>(HiveService.sessionsBox);
  await Hive.openBox<Player>(HiveService.playersBox);
  await Hive.openBox<LedgerTransaction>(HiveService.transactionsBox);
  await Hive.openBox(HiveService.settingsBox);
  await Hive.openBox<ChipType>(HiveService.chipsBox);
  await Hive.openBox<ChipMovement>(HiveService.chipMovementsBox);
  await Hive.openBox<PlayerIdentity>(HiveService.playerIdentitiesBox);
  await Hive.openBox<FinancialEvent>(HiveService.financialEventsBox);
  await Hive.openBox<BankCount>(HiveService.bankCountsBox);
}

Future<void> _close() async {
  await Hive.deleteFromDisk();
  if (await _tmp.exists()) await _tmp.delete(recursive: true);
}

void main() {
  setUp(_open);
  tearDown(_close);

  group('format and whitelist', () {
    test('export is format version 8 (Phase 8: hands)', () {
      final payload = BackupService.exportPayload();
      expect(payload['formatVersion'], 8);
      expect(BackupService.formatVersion, 8);
      // Count sheets ride along for restore on a new device.
      expect(payload.containsKey('bankCounts'), isTrue);
      // Table participations ride along too (v7+).
      expect(payload.containsKey('participations'), isTrue);
      // Completed hands ride along (v8+).
      expect(payload.containsKey('hands'), isTrue);
    });

    test('export always includes identity and financial keys', () {
      final payload = BackupService.exportPayload();
      expect(payload.containsKey('playerIdentities'), isTrue);
      expect(payload.containsKey('financialEvents'), isTrue);
      expect(payload['playerIdentities'], isEmpty);
      expect(payload['financialEvents'], isEmpty);
    });

    test('portable settings include the player-registry keys', () {
      expect(
        BackupService.portableSettingKeys,
        containsAll([
          'language',
          'currency',
          'privacy_mode',
          'sound_effects_enabled',
          'player_blacklist',
          'player_tag_override',
          'player_blacklist_note',
        ]),
      );
    });

    test('PIN is still excluded from the portable whitelist', () {
      expect(BackupService.portableSettingKeys, isNot(contains('pin')));
      expect(BackupService.portableSettingKeys, isNot(contains('pin_hash')));
    });
  });

  group('C-4 player registry is no longer dropped', () {
    test('blacklist, note and tag override survive a backup round-trip',
        () async {
      await PlayerRegistryService.blacklist('Ali', note: 'owes from March');
      await PlayerRegistryService.setTagForName(
          'Ali', PlayerTag.problemPlayer);

      final payload = BackupService.exportPayload();
      final settings = payload['settings'] as Map;
      expect(settings.containsKey('player_blacklist'), isTrue);
      expect(settings.containsKey('player_tag_override'), isTrue);
      expect(settings.containsKey('player_blacklist_note'), isTrue);

      await HiveService.settings.clear();
      expect(PlayerRegistryService.isBlacklistedName('Ali'), isFalse);

      await BackupService.importPayload(payload);

      expect(PlayerRegistryService.isBlacklistedName('Ali'), isTrue);
      expect(PlayerRegistryService.blacklistNote('Ali'), 'owes from March');
      expect(PlayerRegistryService.tagForName('Ali'),
          PlayerTag.problemPlayer);
    });
  });

  group('identities export and restore', () {
    test('a clean identity round-trips', () async {
      final created = await PlayerIdentityService.createNew('Sara');
      final payload = BackupService.exportPayload();
      expect((payload['playerIdentities'] as List), hasLength(1));

      await HiveService.playerIdentities.clear();
      expect(PlayerIdentityService.byId(created!.id), isNull);

      final result = await BackupService.importPayload(payload);
      expect(result.identitiesImported, 1);
      expect(result.requiresIdentityResolution, isFalse);
      expect(PlayerIdentityService.byId(created.id)!.displayName, 'Sara');
    });

    test('a v4 backup without identities still restores', () async {
      final session = PokerSession(
        id: 's1',
        name: 'Old',
        location: 'Home',
        dateTime: DateTime(2024, 1, 1),
        smallBlind: 1,
        bigBlind: 2,
        tableNumber: '1',
      );
      final payload = {
        'formatVersion': 4,
        'sessions': [session.toJson()],
        'players': <Map<String, dynamic>>[],
        'transactions': <Map<String, dynamic>>[],
        'chips': <Map<String, dynamic>>[],
        'chipMovements': <Map<String, dynamic>>[],
        'settings': {'language': 'fa'},
      };

      final result = await BackupService.importPayload(payload);
      expect(result.formatVersion, 4);
      expect(result.sessionsImported, 1);
      expect(result.identitiesImported, 0);
      expect(HiveService.sessions.get('s1')!.name, 'Old');
      expect(HiveService.settings.get('language'), 'fa');
    });

    test('financial events in a file are counted, never written', () async {
      final payload = BackupService.exportPayload();
      payload['financialEvents'] = [
        {'id': 'fe-1', 'amount': 500},
      ];
      final result = await BackupService.importPayload(payload);
      expect(result.financialEventsReserved, 1);
      expect(HiveService.financialEvents.isEmpty, isTrue);
    });

    test('Discount grant fields survive backup export and restore', () async {
      final person = await PlayerIdentityService.createNew('Ali');
      final grant = FinancialEvent(
        id: 'grant-1',
        personId: person!.id,
        currency: AppCurrency.usd,
        type: FinancialEventType.rebateGranted,
        amountMinor: 15000,
        occurredAt: DateTime(2026, 8, 12, 21),
        createdAt: DateTime(2026, 8, 12, 21),
        sessionId: 'night',
        baseLossMinor: 150000,
        grantedAsChips: true,
        grantPercent: 10,
        cycleIndex: 1,
      );
      await HiveService.financialEvents.put(grant.id, grant);

      final payload = BackupService.exportPayload();
      final exported = (payload['financialEvents'] as List).single
          as Map<String, dynamic>;
      expect(exported['baseLossMinor'], 150000);
      expect(exported['grantedAsChips'], isTrue);
      expect(exported['grantPercent'], 10);
      expect(exported['cycleIndex'], 1);
      expect(exported['type'], FinancialEventType.rebateGranted.index);
      expect(exported['sessionId'], 'night');
      expect(exported['personId'], person.id);

      await HiveService.financialEvents.clear();
      final result = await BackupService.importPayload(payload);
      expect(result.financialEventsImported, 1);
      final restored = HiveService.financialEvents.get('grant-1')!;
      expect(restored.type, FinancialEventType.rebateGranted);
      expect(restored.amountMinor, 15000);
      expect(restored.baseLossMinor, 150000);
      expect(restored.grantedAsChips, isTrue);
      expect(restored.grantPercent, 10);
      expect(restored.cycleIndex, 1);
      expect(restored.sessionId, 'night');
      expect(restored.personId, person.id);
      expect(restored.currency, AppCurrency.usd);
      expect(restored.reversesEventId, isNull);
    });
  });

  group('D-2 identity conflicts are not auto-applied', () {
    test('same id + different name is a conflict and is not overwritten',
        () async {
      final local = PlayerIdentity(id: 'p-1', displayName: 'Ali');
      await HiveService.playerIdentities.put(local.id, local);

      final incoming = PlayerIdentity(id: 'p-1', displayName: 'Reza');
      final result = await BackupService.importPayload({
        'formatVersion': 5,
        'playerIdentities': [incoming.toJson()],
      });

      expect(result.requiresIdentityResolution, isTrue);
      expect(result.identityConflicts, hasLength(1));
      expect(result.identityConflicts.single.kind,
          IdentityConflictKind.sameIdDifferentName);
      expect(result.identitiesSkipped, 1);
      expect(HiveService.playerIdentities.get('p-1')!.displayName, 'Ali');
    });

    test('same name + different id is a conflict and is not imported',
        () async {
      final local = PlayerIdentity(id: 'local-1', displayName: 'Ali');
      await HiveService.playerIdentities.put(local.id, local);

      final incoming = PlayerIdentity(id: 'backup-1', displayName: ' ali ');
      final result = await BackupService.importPayload({
        'formatVersion': 5,
        'playerIdentities': [incoming.toJson()],
      });

      expect(result.identityConflicts, hasLength(1));
      expect(result.identityConflicts.single.kind,
          IdentityConflictKind.sameNameDifferentId);
      expect(HiveService.playerIdentities.get('backup-1'), isNull);
      expect(HiveService.playerIdentities.get('local-1'), isNotNull);
    });

    test('same id + same name is idempotent, not a conflict', () async {
      final local = PlayerIdentity(id: 'p-1', displayName: 'Ali');
      await HiveService.playerIdentities.put(local.id, local);

      final result = await BackupService.importPayload({
        'formatVersion': 5,
        'playerIdentities': [
          PlayerIdentity(id: 'p-1', displayName: 'ALI').toJson(),
        ],
      });

      expect(result.requiresIdentityResolution, isFalse);
      expect(result.identitiesImported, 1);
      expect(HiveService.playerIdentities.get('p-1')!.displayName, 'ALI');
    });

    test('takeBackup applies a same-id conflict without remapping', () async {
      final local = PlayerIdentity(id: 'p-1', displayName: 'Ali');
      await HiveService.playerIdentities.put(local.id, local);
      final incoming = PlayerIdentity(id: 'p-1', displayName: 'Reza');

      final result = await BackupService.importPayload({
        'formatVersion': 5,
        'playerIdentities': [incoming.toJson()],
      });
      await BackupService.applyIdentityResolutions([
        IdentityResolution(
          conflict: result.identityConflicts.single,
          action: IdentityResolutionAction.takeBackup,
        ),
      ]);

      expect(HiveService.playerIdentities.get('p-1')!.displayName, 'Reza');
      expect(HiveService.playerIdentities.length, 1);
    });

    test('keepBoth on a same-name conflict imports the second person',
        () async {
      final local = PlayerIdentity(id: 'local-1', displayName: 'Ali');
      await HiveService.playerIdentities.put(local.id, local);
      final incoming = PlayerIdentity(id: 'backup-1', displayName: 'Ali');

      final result = await BackupService.importPayload({
        'formatVersion': 5,
        'playerIdentities': [incoming.toJson()],
      });
      await BackupService.applyIdentityResolutions([
        IdentityResolution(
          conflict: result.identityConflicts.single,
          action: IdentityResolutionAction.keepBoth,
        ),
      ]);

      expect(HiveService.playerIdentities.length, 2);
      expect(HiveService.playerIdentities.get('local-1'), isNotNull);
      expect(HiveService.playerIdentities.get('backup-1'), isNotNull);
    });

    test('keepBoth on a same-id conflict is refused', () async {
      final local = PlayerIdentity(id: 'p-1', displayName: 'Ali');
      await HiveService.playerIdentities.put(local.id, local);
      final incoming = PlayerIdentity(id: 'p-1', displayName: 'Reza');

      final result = await BackupService.importPayload({
        'formatVersion': 5,
        'playerIdentities': [incoming.toJson()],
      });
      final applied = await BackupService.applyIdentityResolutions([
        IdentityResolution(
          conflict: result.identityConflicts.single,
          action: IdentityResolutionAction.keepBoth,
        ),
      ]);

      expect(applied, 0);
      expect(HiveService.playerIdentities.get('p-1')!.displayName, 'Ali');
    });
  });

  group('C-3 fail-loud boxes are never reset', () {
    test('failLoudBoxes lists identity, financial, counts, participations, hands',
        () {
      expect(HiveService.failLoudBoxes, {
        HiveService.playerIdentitiesBox,
        HiveService.financialEventsBox,
        HiveService.bankCountsBox,
        HiveService.participationsBox,
        HiveService.handsBox,
      });
      expect(HiveService.failLoudBoxes.contains(HiveService.sessionsBox),
          isFalse);
    });

    test('openBoxFailLoud leaves a corrupt file on disk and throws', () async {
      // Use an extremely long box name to force a FileSystemException (path too long)
      // which openBoxFailLoud must catch and wrap in StorageInitException.
      final name = 'a' * 300;

      Object? caught;
      try {
        await HiveService.openBoxFailLoud<PlayerIdentity>(name, typed: true);
      } catch (e) {
        caught = e;
      }

      expect(caught, isA<StorageInitException>());
    });
  });

  group('payload is JSON-encodable', () {
    test('a full export encodes and decodes', () async {
      await PlayerRegistryService.blacklist('Ali', note: 'note');
      await PlayerIdentityService.createNew('Sara');
      final encoded = jsonEncode(BackupService.exportPayload());
      final decoded = jsonDecode(encoded) as Map<String, dynamic>;
      expect(decoded['formatVersion'], 8);
      expect((decoded['playerIdentities'] as List), hasLength(1));
    });
  });
}
