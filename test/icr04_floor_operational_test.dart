// ICR-04 — Floor/table operational workflow polish.
//
// Covers the small, non-accounting operational contract added in this
// phase:
//   1. Multi-table selector labels each table with an explicit
//      Active / Paused / Closed word next to the status dot (colour is
//      never the only signal).
//   2. Seat action sheet separates Money / Table / Player actions so an
//      operator does not have to infer which category the next tap
//      belongs to.
//   3. Unlinked occupied seat is presented as an explicit identity task
//      (banner + Link to existing player) before the action list.
//   4. Table Cash-out remains the visible, separate label — no session
//      cash-out or cage-redemption wording is substituted.
//   5. EN/FA parity for the new action-section labels.
//
// This file deliberately contains NO accounting formula, FinancialLedger,
// ChipTracking, Rebate, Discount, Marker, Table Exit or Backup logic.
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
import 'package:poker_ledger/screens/table_view/table_view_tab.dart';
import 'package:poker_ledger/services/hive_service.dart';
import 'package:poker_ledger/services/player_identity_service.dart';
import 'package:poker_ledger/services/table_service.dart';
import 'package:poker_ledger/widgets/poker_table_view.dart';
import 'package:poker_ledger/widgets/table_selector_bar.dart';

import 'test_helper.dart';

late Directory _tmp;

Future<void> _open() async {
  _tmp = await Directory.systemTemp.createTemp('pl_icr04_');
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
    id: 'session-icr04',
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

Widget _app(SessionProvider provider, Widget home) {
  return ChangeNotifierProvider<SessionProvider>.value(
    value: provider,
    child: MaterialApp(
      home: home,
      localizationsDelegates: const [
        AppLocalizationsDelegate(),
      ],
      supportedLocales: const [Locale('en'), Locale('fa')],
    ),
  );
}

Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump();
}

void main() {
  setUp(_open);
  tearDown(_close);

  group('localization', () {
    test('new ICR-04 action-section labels exist in EN and FA', () {
      expect(AppLocalizations.lookup('en', 'money_actions'),
          'Money Actions');
      expect(AppLocalizations.lookup('en', 'table_actions'),
          'Table Actions');
      expect(AppLocalizations.lookup('en', 'player_actions'),
          'Player Actions');
      expect(AppLocalizations.lookup('fa', 'money_actions'),
          'عملیات پول');
      expect(AppLocalizations.lookup('fa', 'table_actions'),
          'عملیات میز');
      expect(AppLocalizations.lookup('fa', 'player_actions'),
          'عملیات بازیکن');
    });
  });

  group('multi-table selector', () {
    testWidgets('shows explicit status word alongside the status dot',
        (tester) async {
      final provider = await _provider();
      await provider.addTable(name: 'Table 2');
      await tester.pumpWidget(_app(provider, const Scaffold(
        body: TableSelectorBar(),
      )));

      expect(find.byType(TableSelectorBar), findsOneWidget);
      expect(find.text('Active'), findsNWidgets(2));

      // Close one table; that table must now be labelled with a word,
      // not only a red dot.
      await provider.setTableStatus('table-2', TableStatus.closed);
      await tester.pump();
      expect(find.text('Closed'), findsOneWidget);
      expect(find.text('Active'), findsOneWidget);

      await _unmount(tester);
      provider.dispose();
    });

    testWidgets('paused table is labelled explicitly', (tester) async {
      final provider = await _provider();
      await provider.addTable(name: 'Table 2');
      await provider.setTableStatus('table-2', TableStatus.paused);
      await tester.pumpWidget(_app(provider, const Scaffold(
        body: TableSelectorBar(),
      )));

      expect(find.text('Paused'), findsOneWidget);
      expect(find.text('Active'), findsOneWidget);

      await _unmount(tester);
      provider.dispose();
    });
  });

  group('seat action sheet', () {
    testWidgets('sections separate Money / Table / Player actions',
        (tester) async {
      final provider = await _provider();
      final player = Player(
        id: 'player-1',
        sessionId: 'session-icr04',
        name: 'Ali',
        seatNumber: 1,
        personId: 'person-1',
        tableId: 'table-1',
        seated: true,
      );
      await HiveService.players.put(player.id, player);

      await tester.pumpWidget(_app(provider, const TableViewTab()));
      await tester.pump();

      await tester.tap(find.byType(SeatWidget).first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));

      expect(find.text('MONEY ACTIONS'), findsOneWidget);
      expect(find.text('TABLE ACTIONS'), findsOneWidget);
      expect(find.text('PLAYER ACTIONS'), findsOneWidget);
      expect(find.text('Table Cash-out'), findsOneWidget);
      expect(find.text('Record Hand'), findsOneWidget);

      await _unmount(tester);
      provider.dispose();
    });

    testWidgets('unlinked occupied seat surfaces identity task before actions',
        (tester) async {
      final provider = await _provider();
      final player = Player(
        id: 'player-unlinked',
        sessionId: 'session-icr04',
        name: 'Legacy Row',
        seatNumber: 1,
        tableId: 'table-1',
        seated: true,
      );
      await HiveService.players.put(player.id, player);

      await tester.pumpWidget(_app(provider, const TableViewTab()));
      await tester.pump();

      await tester.tap(find.byType(SeatWidget).first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));

      expect(find.text('This seat has no Player Identity link yet.'),
          findsOneWidget);
      expect(find.text('Link to existing player'), findsOneWidget);
      expect(find.text('MONEY ACTIONS'), findsOneWidget);

      await _unmount(tester);
      provider.dispose();
    });

    testWidgets('linked occupied seat does not show unlinked identity banner',
        (tester) async {
      final provider = await _provider();
      final identity = (await PlayerIdentityService.createNew('Sara'))!;
      final player = Player(
        id: 'player-linked',
        sessionId: 'session-icr04',
        name: 'Sara',
        seatNumber: 1,
        personId: identity.id,
        tableId: 'table-1',
        seated: true,
      );
      await HiveService.players.put(player.id, player);

      await tester.pumpWidget(_app(provider, const TableViewTab()));
      await tester.pump();

      await tester.tap(find.byType(SeatWidget).first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));

      expect(find.text('This seat has no Player Identity link yet.'),
          findsNothing);
      expect(find.text('Link to existing player'), findsNothing);
      expect(find.text('MONEY ACTIONS'), findsOneWidget);

      await _unmount(tester);
      provider.dispose();
    });
  });
}
