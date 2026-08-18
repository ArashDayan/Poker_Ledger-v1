// Step 1 — Player Identity foundation.
//
// personId is a permanent identity. Names are display only. A name
// match is only a suggestion; linking requires an explicit confirm.
// Nothing here reads or writes money.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:poker_ledger/models/player.dart';
import 'package:poker_ledger/models/player_identity.dart';
import 'package:poker_ledger/models/session.dart';
import 'package:poker_ledger/core/localization/app_localizations.dart';
import 'package:poker_ledger/models/transaction.dart';
import 'package:poker_ledger/providers/session_provider.dart';
import 'package:poker_ledger/services/hive_service.dart';
import 'package:poker_ledger/services/player_identity_service.dart';

import 'test_helper.dart';

late Directory _tmp;

Future<void> _open() async {
  _tmp = await Directory.systemTemp.createTemp('pl_identity_');
  Hive.init(_tmp.path);
  registerTestAdapters();
  await Hive.openBox<PokerSession>(HiveService.sessionsBox);
  await Hive.openBox<Player>(HiveService.playersBox);
  await Hive.openBox<LedgerTransaction>(HiveService.transactionsBox);
  await Hive.openBox(HiveService.settingsBox);
  await Hive.openBox<PlayerIdentity>(HiveService.playerIdentitiesBox);
}

Future<void> _close() async {
  await Hive.deleteFromDisk();
  if (await _tmp.exists()) await _tmp.delete(recursive: true);
}

Future<SessionProvider> _provider() async {
  final s = PokerSession(
    id: 'session-1',
    name: 'Friday',
    location: 'Home',
    dateTime: DateTime.now(),
    smallBlind: 1,
    bigBlind: 2,
    tableNumber: '1',
  );
  await HiveService.sessions.put(s.id, s);
  return SessionProvider()..loadSession(s);
}

void main() {
  setUp(_open);
  tearDown(_close);

  group('model is additive and money-free', () {
    test('a legacy player JSON without personId loads as unlinked', () {
      final p = Player.fromJson({
        'id': 'p1',
        'sessionId': 's1',
        'name': 'Ali',
        'seatNumber': 1,
        'tags': <int>[],
        'isActive': true,
        'isFavorite': false,
        'joinedAt': DateTime.now().toIso8601String(),
      });
      expect(p.personId, isNull);
    });

    test('personId round-trips through JSON', () {
      final p = Player(
        id: 'p1',
        sessionId: 's1',
        name: 'Ali',
        seatNumber: 1,
        personId: 'person-1',
      );
      final copy = Player.fromJson(p.toJson());
      expect(copy.personId, 'person-1');
      expect(copy.name, 'Ali');
    });

    test('PlayerIdentity JSON has no money fields', () {
      final i = PlayerIdentity(id: 'id-1', displayName: 'Ali');
      final json = i.toJson();
      expect(json.keys, containsAll(['id', 'displayName', 'createdAt', 'updatedAt']));
      expect(json.containsKey('balance'), isFalse);
      expect(json.containsKey('credit'), isFalse);
      expect(json.containsKey('frontMoney'), isFalse);
      expect(json.containsKey('currency'), isFalse);
    });

    test('Hive typeId 11 is PlayerIdentity', () {
      expect(PlayerIdentityAdapter().typeId, 11);
    });
  });

  group('suggest never auto-links', () {
    test('an unknown name produces no suggestion', () async {
      expect(PlayerIdentityService.suggest('Ali'), isEmpty);
    });

    test('an exact normalised name match is a suggestion, not a link', () async {
      final created = await PlayerIdentityService.createNew('Ali Reza');
      expect(created, isNotNull);

      final hits = PlayerIdentityService.suggest('  ali   reza ');
      expect(hits, hasLength(1));
      expect(hits.single.id, created!.id);

      // The identity box still has exactly one record — suggest did
      // not create, merge or attach anything.
      expect(HiveService.playerIdentities.length, 1);
    });

    test('two people with the same name stay two identities', () async {
      final a = await PlayerIdentityService.createNew('Ali');
      final b = await PlayerIdentityService.createNew('Ali');
      expect(a!.id, isNot(b!.id));
      expect(PlayerIdentityService.suggest('ali'), hasLength(2));
    });

    test('a close-but-different name is not suggested', () async {
      await PlayerIdentityService.createNew('Ali');
      expect(PlayerIdentityService.suggest('Ali K'), isEmpty);
      expect(PlayerIdentityService.suggest('Alireza'), isEmpty);
    });
  });

  group('resolveForSeating is confirm-only', () {
    test('no suggestion creates a new identity without asking', () async {
      var asked = false;
      final personId = await PlayerIdentityService.resolveForSeating(
        name: 'Sara',
        confirm: (_) async {
          asked = true;
          return const IdentityLinkResult.cancel();
        },
      );
      expect(asked, isFalse);
      expect(personId, isNotNull);
      expect(PlayerIdentityService.byId(personId!)!.displayName, 'Sara');
    });

    test('a suggestion + confirm link returns the existing id', () async {
      final existing = await PlayerIdentityService.createNew('Ali');
      final before = HiveService.playerIdentities.length;

      final personId = await PlayerIdentityService.resolveForSeating(
        name: 'Ali',
        confirm: (hits) async {
          expect(hits, hasLength(1));
          expect(hits.single.id, existing!.id);
          return IdentityLinkResult.link(hits.single.id);
        },
      );

      expect(personId, existing!.id);
      expect(HiveService.playerIdentities.length, before,
          reason: 'confirm-link must not create a second identity');
    });

    test('a suggestion + different person creates a NEW identity', () async {
      final existing = await PlayerIdentityService.createNew('Ali');

      final personId = await PlayerIdentityService.resolveForSeating(
        name: 'Ali',
        confirm: (_) async => const IdentityLinkResult.createNew(),
      );

      expect(personId, isNotNull);
      expect(personId, isNot(existing!.id));
      expect(HiveService.playerIdentities.length, 2);
    });

    test('a suggestion + cancel writes nothing and returns null', () async {
      await PlayerIdentityService.createNew('Ali');
      final before = HiveService.playerIdentities.length;

      final personId = await PlayerIdentityService.resolveForSeating(
        name: 'Ali',
        confirm: (_) async => const IdentityLinkResult.cancel(),
      );

      expect(personId, isNull);
      expect(HiveService.playerIdentities.length, before);
    });

    test('linking a personId that does not exist is refused', () async {
      await PlayerIdentityService.createNew('Ali');
      expect(
        () => PlayerIdentityService.resolveForSeating(
          name: 'Ali',
          confirm: (_) async => const IdentityLinkResult.link('missing'),
        ),
        throwsStateError,
      );
    });
  });

  group('seating stores personId only when told', () {
    test('addPlayer without personId leaves the seat unlinked', () async {
      final provider = await _provider();
      final p = await provider.addPlayer(name: 'Ali', seatNumber: 1);
      expect(p.personId, isNull);
      expect(HiveService.players.get(p.id)!.personId, isNull);
    });

    test('addPlayer with a confirmed personId stores it', () async {
      final provider = await _provider();
      final identity = await PlayerIdentityService.createNew('Ali');
      final p = await provider.addPlayer(
        name: 'Ali',
        seatNumber: 1,
        personId: identity!.id,
      );
      expect(HiveService.players.get(p.id)!.personId, identity.id);
    });

    test('renaming a linked player updates displayName, not the id', () async {
      final provider = await _provider();
      final identity = await PlayerIdentityService.createNew('Ali');
      final p = await provider.addPlayer(
        name: 'Ali',
        seatNumber: 1,
        personId: identity!.id,
      );
      p.name = 'Ali Reza';
      await provider.updatePlayer(p);

      final stored = PlayerIdentityService.byId(identity.id)!;
      expect(stored.id, identity.id);
      expect(stored.displayName, 'Ali Reza');
      expect(HiveService.players.get(p.id)!.personId, identity.id);
    });
  });

  group('localization parity', () {
    test('EN and FA identity keys match', () {
      const keys = [
        'identity_same_person_title',
        'identity_same_person_body',
        'identity_different_person',
        'identity_confirm_hint',
        'identity_last_seen',
        'identity_no_previous_seat',
        'identity_restore_conflict_title',
        'identity_restore_conflict_same_id',
        'identity_restore_conflict_same_name',
        'identity_keep_local',
        'identity_take_backup',
        'identity_keep_both',
        'identity_conflicts_resolved',
        'identity_conflicts_pending',
      ];
      for (final key in keys) {
        final en = AppLocalizations.lookup('en', key);
        final fa = AppLocalizations.lookup('fa', key);
        expect(en, isNot(key), reason: 'missing EN $key');
        expect(fa, isNot(key), reason: 'missing FA $key');
        expect(en, isNot(fa), reason: 'FA should not equal EN for $key');
      }
    });
  });

  group('attach refuses a missing identity', () {
    test('attach throws rather than inventing a person', () async {
      final player = Player(
        id: 'p1',
        sessionId: 'session-1',
        name: 'Ali',
        seatNumber: 1,
      );
      await HiveService.players.put(player.id, player);
      expect(
        () => PlayerIdentityService.attach(player, 'no-such-person'),
        throwsStateError,
      );
      expect(HiveService.players.get(player.id)!.personId, isNull);
    });
  });
}
