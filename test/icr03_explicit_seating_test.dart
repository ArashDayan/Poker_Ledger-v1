// ICR-03 — explicit Player Selection → Seating.
//
// Covers the hard workflow contract:
//   1. Search existing Player by Player Number.
//   2. Search existing Player by name.
//   3. Explicit existing-Player selection + Seat action.
//   4. Register New creates identity only (no seat / chips / money).
//   5. Back/dismiss before the final Seat action produces zero writes.
//   6. Duplicate active participation is blocked.
//   7. Existing unlinked seat can be explicitly linked to a Player.
//   8. No silent identity creation remains in the seating paths.
//   9. Unassigned Player Number is never presented as a real number.
//  10. EN/FA localization key parity.
//
// No accounting formula, FinancialLedger, ChipTracking, Rebate,
// Discount, Marker, Table Exit or Backup logic is written here.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:provider/provider.dart';

import 'package:poker_ledger/core/localization/app_localizations.dart';
import 'package:poker_ledger/models/chip_movement.dart';
import 'package:poker_ledger/models/chip_type.dart';
import 'package:poker_ledger/models/financial_event.dart';
import 'package:poker_ledger/models/hand.dart';
import 'package:poker_ledger/models/player.dart';
import 'package:poker_ledger/models/player_identity.dart';
import 'package:poker_ledger/models/session.dart';
import 'package:poker_ledger/models/transaction.dart';
import 'package:poker_ledger/providers/session_provider.dart';
import 'package:poker_ledger/services/hive_service.dart';
import 'package:poker_ledger/services/player_identity_service.dart';
import 'package:poker_ledger/services/seating_service.dart';
import 'package:poker_ledger/services/table_service.dart';
import 'package:poker_ledger/widgets/select_player_sheet.dart';

import 'test_helper.dart';

late Directory _tmp;

Future<void> _open() async {
  _tmp = await Directory.systemTemp.createTemp('pl_icr03_');
  Hive.init(_tmp.path);
  registerTestAdapters();
  await Hive.openBox<PokerSession>(HiveService.sessionsBox);
  await Hive.openBox<Player>(HiveService.playersBox);
  await Hive.openBox<LedgerTransaction>(HiveService.transactionsBox);
  await Hive.openBox(HiveService.settingsBox);
  await Hive.openBox<PlayerIdentity>(HiveService.playerIdentitiesBox);
  await Hive.openBox<FinancialEvent>(HiveService.financialEventsBox);
  await Hive.openBox<Hand>(HiveService.handsBox);
  await Hive.openBox<ChipType>(HiveService.chipsBox);
  await Hive.openBox<ChipMovement>(HiveService.chipMovementsBox);
}

Future<void> _close() async {
  await Hive.deleteFromDisk();
  if (await _tmp.exists()) await _tmp.delete(recursive: true);
}

Future<SessionProvider> _provider() async {
  final session = PokerSession(
    id: 'session-1',
    name: 'Friday',
    location: 'Home',
    dateTime: DateTime.now(),
    smallBlind: 1,
    bigBlind: 2,
    tableNumber: '1',
  );
  await HiveService.sessions.put(session.id, session);
  return SessionProvider()..loadSession(session);
}

Player _stored(String id) => HiveService.players.get(id)!;

void main() {
  setUp(_open);
  tearDown(_close);

  group('search and Player Number display', () {
    test('searches by exact Player Number and by # prefix', () async {
      final a = (await PlayerIdentityService.createNew('Ali Ahmadi'))!;
      final b = (await PlayerIdentityService.createNew('Sara Karimi'))!;
      a.idNumber = 'PP-1';
      b.idNumber = 'PP-2';
      await a.save();
      await b.save();

      expect(PlayerIdentityService.search('101').single.id, a.id);
      expect(PlayerIdentityService.search('#101').single.id, a.id);
    });

    test('searches by first, last and display name', () async {
      final a = (await PlayerIdentityService.createNew('Ali Ahmadi'))!;
      final b = (await PlayerIdentityService.createNew('Sara Karimi'))!;
      expect(PlayerIdentityService.search('ali').single.id, a.id);
      expect(PlayerIdentityService.search('ahmadi').single.id, a.id);
      expect(PlayerIdentityService.search('ali ahmadi').single.id, a.id);
      expect(PlayerIdentityService.search('sara').single.id, b.id);
    });

    test('empty query returns all, ordered by assigned number', () async {
      final a = (await PlayerIdentityService.createNew('Ali Ahmadi'))!;
      final b = (await PlayerIdentityService.createNew('Sara Karimi'))!;
      final found = PlayerIdentityService.search('');
      expect(found.map((i) => i.id), [a.id, b.id]);
    });

    test('unassigned number is displayed as em dash, never as 0', () {
      expect(PlayerIdentityService.numberLabel(0), '—');
      expect(PlayerIdentityService.numberLabel(101), '101');
      expect(PlayerIdentityService.numberLabel(99), '—');
    });

    test('searching 0 never treats unassigned as a real number', () async {
      await HiveService.playerIdentities.put(
        'legacy-unassigned',
        PlayerIdentity(
          id: 'legacy-unassigned',
          displayName: 'Unassigned Person',
        ),
      );
      expect(PlayerIdentityService.search('0'), isEmpty);
    });

    test('no match returns empty list', () async {
      await PlayerIdentityService.createNew('Ali Ahmadi');
      expect(PlayerIdentityService.search('Nobody Here'), isEmpty);
    });
  });

  group('no silent identity creation', () {
    test('cancel writes no identity even when no suggestion exists',
        () async {
      final before = HiveService.playerIdentities.length;
      final id = await PlayerIdentityService.resolveForSeating(
        name: 'Completely Unknown',
        confirm: (_) async => const IdentityLinkResult.cancel(),
      );
      expect(id, isNull);
      expect(HiveService.playerIdentities.length, before);
    });

    test('explicit Register New writes one identity; cancel after never '
        'seats', () async {
      final id = await PlayerIdentityService.resolveForSeating(
        name: 'Explicit New',
        confirm: (_) async => const IdentityLinkResult.createNew(),
      );
      expect(id, isNotNull);
      expect(HiveService.playerIdentities.length, 1);
      expect(HiveService.players.length, 0);
      expect(HiveService.transactions.length, 0);
    });

    test('link-only confirm returns the existing id without creating', () async {
      final existing = await PlayerIdentityService.createNew('Ali Ahmadi');
      final id = await PlayerIdentityService.resolveForSeating(
        name: 'ali ahmadi',
        confirm: (suggestions) async =>
            IdentityLinkResult.link(suggestions.single.id),
      );
      expect(id, existing!.id);
      expect(HiveService.playerIdentities.length, 1);
    });
  });

  group('registration vs seating separation', () {
    test('Register New writes identity only', () async {
      final created = await PlayerIdentityService.createNew('Mahsa Noor');
      expect(created, isNotNull);
      expect(HiveService.playerIdentities.length, 1);
      expect(HiveService.players.length, 0);
      expect(HiveService.transactions.length, 0);
      expect(HiveService.financialEvents.length, 0);
      expect(HiveService.chipMovements.length, 0);
    });

    test('explicit Seat action writes one player row and no money/chips',
        () async {
      final provider = await _provider();
      final identity = (await PlayerIdentityService.createNew('Ali Ahmadi'))!;
      final result = await SeatingService.seatPlayerAt(
        provider: provider,
        personId: identity.id,
        tableId: TableService.defaultTableId,
        seatNumber: 3,
      );
      expect(result.succeeded, isTrue);
      final player = _stored(result.player!.id);
      expect(player.personId, identity.id);
      expect(player.seated, isTrue);
      expect(player.seatNumber, 3);
      expect(TableService.tableForPlayer(provider.current!, player).id,
          TableService.defaultTableId);
      expect(HiveService.transactions.length, 0);
      expect(HiveService.financialEvents.length, 0);
      expect(HiveService.chipMovements.length, 0);
      provider.dispose();
    });

    test('already-registered-unseated person is moved onto the seat, not '
        'duplicated', () async {
      final provider = await _provider();
      final identity = (await PlayerIdentityService.createNew('Sara Karimi'))!;
      final registered = await provider.registerPlayer(
          personId: identity.id, name: identity.displayName);
      expect(registered.seated, isFalse);

      final result = await SeatingService.seatPlayerAt(
        provider: provider,
        personId: identity.id,
        tableId: TableService.defaultTableId,
        seatNumber: 2,
      );
      expect(result.succeeded, isTrue);
      expect(result.player!.id, registered.id);
      expect(HiveService.players.length, 1);
      expect(_stored(registered.id).seated, isTrue);
      expect(HiveService.transactions.length, 0);
      provider.dispose();
    });
  });

  group('duplicate active participation', () {
    test('a person already seated elsewhere is blocked and no second seat '
        'is created', () async {
      final provider = await _provider();
      final identity = (await PlayerIdentityService.createNew('Reza Mohseni'))!;
      final t1 = TableService.defaultTableId;
      final t2 = await provider.addTable(name: 'Table 2');

      final first = await SeatingService.seatPlayerAt(
        provider: provider,
        personId: identity.id,
        tableId: t1,
        seatNumber: 1,
      );
      expect(first.succeeded, isTrue);

      final second = await SeatingService.seatPlayerAt(
        provider: provider,
        personId: identity.id,
        tableId: t2,
        seatNumber: 1,
      );
      expect(second.succeeded, isFalse);
      expect(
          second.block.reason, SeatingBlockReason.duplicateActiveParticipation);
      expect(second.block.existingParticipation, isNotNull);
      expect(second.block.existingParticipation!.id, first.player!.id);
      expect(HiveService.players.length, 1);
      expect(HiveService.transactions.length, 0);
      provider.dispose();
    });
  });

  group('existing unlinked seat', () {
    test('link to existing player is explicit and does not create a person',
        () async {
      final provider = await _provider();
      final identity = (await PlayerIdentityService.createNew('Leila Sadeghi'))!;
      final unlinked = await provider.addPlayer(
          name: 'Leila Sadeghi', seatNumber: 4);
      expect(unlinked.personId, isNull);

      final block = SeatingService.linkBlocker(
        session: provider.current!,
        seat: unlinked,
        personId: identity.id,
      );
      expect(block.ok, isTrue);

      await SeatingService.linkPlayer(unlinked, identity.id);
      expect(_stored(unlinked.id).personId, identity.id);
      expect(HiveService.playerIdentities.length, 1);
      expect(HiveService.players.length, 1);
      expect(HiveService.transactions.length, 0);
      provider.dispose();
    });

    test('linking a person who already has a session row is blocked', () async {
      final provider = await _provider();
      final identity = (await PlayerIdentityService.createNew('Nima Tehrani'))!;
      final unlinked = await provider.addPlayer(
          name: 'Nima Tehrani', seatNumber: 5);
      await provider.registerPlayer(
          personId: identity.id, name: identity.displayName);

      final block = SeatingService.linkBlocker(
        session: provider.current!,
        seat: unlinked,
        personId: identity.id,
      );
      expect(block.ok, isFalse);
      expect(
          block.reason, SeatingBlockReason.duplicateActiveParticipation);
      provider.dispose();
    });
  });

  group('explicit sheet', () {
    testWidgets('dismiss / back before Seat writes nothing',
        (tester) async {
      final provider = await _provider();
      await tester.pumpWidget(
        ChangeNotifierProvider<SessionProvider>.value(
          value: provider,
          child: MaterialApp(
            home: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () => showSeatPlayerSheet(
                  context,
                  presetTableId: TableService.defaultTableId,
                  presetSeat: 1,
                ),
                child: const Text('open-seat'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open-seat'));
      await tester.pumpAndSettle();
      expect(find.text('Select player'), findsOneWidget);

      await tester.tap(find.byTooltip('Cancel'));
      await tester.pumpAndSettle();

      expect(HiveService.playerIdentities.length, 0);
      expect(HiveService.players.length, 0);
      expect(HiveService.transactions.length, 0);
      expect(HiveService.financialEvents.length, 0);
      provider.dispose();
    });

    testWidgets('Register New creates identity only; no seat after save',
        (tester) async {
      final provider = await _provider();
      await tester.pumpWidget(
        ChangeNotifierProvider<SessionProvider>.value(
          value: provider,
          child: MaterialApp(
            home: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () => showSeatPlayerSheet(
                  context,
                  presetTableId: TableService.defaultTableId,
                  presetSeat: 1,
                ),
                child: const Text('open-seat'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open-seat'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Register new'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, 'New Person');
      await tester.tap(find.text('Save identity'));
      await tester.pumpAndSettle();

      expect(HiveService.playerIdentities.length, 1);
      expect(HiveService.players.length, 0);
      expect(HiveService.transactions.length, 0);

      // Operator still has to choose/confirm Seat. Cancel now = no seat.
      await tester.tap(find.byTooltip('Cancel'));
      await tester.pumpAndSettle();
      expect(HiveService.players.length, 0);
      provider.dispose();
    });

    testWidgets('select existing player then Seat creates the participation',
        (tester) async {
      final provider = await _provider();
      final identity = await PlayerIdentityService.createNew('Ali Ahmadi');
      await tester.pumpWidget(
        ChangeNotifierProvider<SessionProvider>.value(
          value: provider,
          child: MaterialApp(
            home: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () => showSeatPlayerSheet(
                  context,
                  presetTableId: TableService.defaultTableId,
                  presetSeat: 1,
                ),
                child: const Text('open-seat'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open-seat'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Ali Ahmadi'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ElevatedButton, 'Seat'));
      await tester.pumpAndSettle();

      final players = HiveService.players.values.toList();
      expect(players.length, 1);
      expect(players.single.personId, identity!.id);
      expect(players.single.seated, isTrue);
      expect(HiveService.transactions.length, 0);
      provider.dispose();
    });
  });

  group('localization parity (ICR-03 keys)', () {
    test('every new key exists in EN and FA and is translated', () {
      const keys = [
        'identity_new_person_title',
        'identity_new_person_body',
        'register_new_player',
        'name_required',
        'identity_created',
        'identity_create_failed',
        'select_table_and_seat',
        'select_table_seat_hint',
        'select_player_hint',
        'search_player_number_or_name',
        'no_identity_match',
        'no_match_link_hint',
        'confirm_seat_player',
        'confirm_link_player',
        'link_occupied_seat_hint',
        'link_to_existing_player',
        'unlinked_seat_hint',
        'seat_no_money_note',
        'seat_blocked',
        'duplicate_active_title',
        'duplicate_active_body',
        'already_registered_title',
        'already_registered_unseated_body',
        'go_to_seat',
        'register_new_identity',
        'register_new_only_note',
        'register_new_hint',
        'display_name',
        'first_name_optional',
        'last_name_optional',
        'id_number_optional',
        'id_number',
        'identity_specimen_on_file',
        'saving',
        'change_player',
        'linked_to_seat',
        'all_tables_full',
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
}
