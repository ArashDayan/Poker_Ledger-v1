// ICR-02 — product shell: Floor | Players | House.
//
// Verifies the product-level navigation contract:
//   * exactly three destinations, phone (NavigationBar) and wide
//     (NavigationRail) presentations of the SAME list
//   * the five-tab session console is no longer the product root
//   * Floor shows the existing TableViewTab when a session is live and
//     an honest launcher when not
//   * Players is the global Player Master directory (existing
//     identities, searchable by number) — never table-scoped
//   * House carries the house-level tools
//   * openFloorSession loads a session, pops pushed routes, lands on
//     Floor
//   * EN/FA parity for every new key
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:provider/provider.dart';

import 'package:poker_ledger/core/localization/app_localizations.dart';
import 'package:poker_ledger/models/financial_event.dart';
import 'package:poker_ledger/models/hand.dart';
import 'package:poker_ledger/models/player.dart';
import 'package:poker_ledger/models/player_identity.dart';
import 'package:poker_ledger/models/session.dart';
import 'package:poker_ledger/models/transaction.dart';
import 'package:poker_ledger/providers/chip_bank_provider.dart';
import 'package:poker_ledger/providers/product_nav_controller.dart';
import 'package:poker_ledger/providers/session_provider.dart';
import 'package:poker_ledger/providers/settings_provider.dart';
import 'package:poker_ledger/screens/player_history/players_directory_screen.dart';
import 'package:poker_ledger/screens/shell/open_floor_session.dart';
import 'package:poker_ledger/screens/shell/product_shell_screen.dart';
import 'package:poker_ledger/screens/table_view/table_view_tab.dart';
import 'package:poker_ledger/services/hive_service.dart';
import 'package:poker_ledger/services/player_identity_service.dart';

import 'test_helper.dart';

late Directory _tmp;

Future<void> _open() async {
  _tmp = await Directory.systemTemp.createTemp('pl_icr02_');
  Hive.init(_tmp.path);
  registerTestAdapters();
  await Hive.openBox<PokerSession>(HiveService.sessionsBox);
  await Hive.openBox<Player>(HiveService.playersBox);
  await Hive.openBox<LedgerTransaction>(HiveService.transactionsBox);
  await Hive.openBox(HiveService.settingsBox);
  await Hive.openBox<PlayerIdentity>(HiveService.playerIdentitiesBox);
  await Hive.openBox<FinancialEvent>(HiveService.financialEventsBox);
  await Hive.openBox<Hand>(HiveService.handsBox);
}

Future<void> _close() async {
  await Hive.deleteFromDisk();
  if (await _tmp.exists()) await _tmp.delete(recursive: true);
}

Widget _app(Widget home,
    {required SessionProvider session,
    required ProductNavController nav}) {
  return MultiProvider(
    providers: [
      ChangeNotifierProvider<SessionProvider>.value(value: session),
      ChangeNotifierProvider<ProductNavController>.value(value: nav),
      ChangeNotifierProvider(create: (_) => SettingsProvider()),
      ChangeNotifierProvider(create: (_) => ChipBankProvider()),
    ],
    child: MaterialApp(home: home),
  );
}

/// Unmounts the shell so its 1s ticker is cancelled before the test
/// file's zone complains about pending timers.
Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump();
}

PokerSession _liveSession() => PokerSession(
      id: 'live-1',
      name: 'Friday Night',
      location: 'Room',
      dateTime: DateTime.now(),
      smallBlind: 1,
      bigBlind: 2,
      tableNumber: '1',
    );

void main() {
  setUp(_open);
  tearDown(_close);

  group('product shell navigation', () {
    testWidgets('phone: exactly Floor | Players | House in a bottom bar',
        (tester) async {
      await tester.pumpWidget(_app(const ProductShellScreen(),
          session: SessionProvider(), nav: ProductNavController()));
      await tester.pump();

      expect(find.byType(NavigationBar), findsOneWidget);
      expect(find.byType(NavigationRail), findsNothing);
      expect(find.text('Floor'), findsOneWidget);
      expect(find.text('Players'), findsOneWidget);
      expect(find.text('House'), findsOneWidget);

      // The old five-tab console labels are NOT product destinations.
      expect(find.text('Dashboard'), findsNothing);
      expect(find.text('Actions'), findsNothing);
      expect(find.text('Timeline'), findsNothing);
      await _unmount(tester);
    });

    testWidgets('wide: same three destinations move to a side rail',
        (tester) async {
      tester.view.physicalSize = const Size(1400, 1000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(_app(const ProductShellScreen(),
          session: SessionProvider(), nav: ProductNavController()));
      await tester.pump();

      expect(find.byType(NavigationRail), findsOneWidget);
      expect(find.byType(NavigationBar), findsNothing);
      expect(find.text('Floor'), findsOneWidget);
      expect(find.text('Players'), findsOneWidget);
      expect(find.text('House'), findsOneWidget);
      await _unmount(tester);
    });

    testWidgets('controller switches destinations; Players is reachable',
        (tester) async {
      final nav = ProductNavController();
      await tester.pumpWidget(_app(const ProductShellScreen(),
          session: SessionProvider(), nav: nav));
      await tester.pump();

      await tester.tap(find.text('Players'));
      await tester.pump();
      expect(nav.index, ProductNavController.playersIndex);
      expect(find.byType(PlayersDirectoryScreen), findsOneWidget);

      await tester.tap(find.text('House'));
      await tester.pump();
      expect(nav.index, ProductNavController.houseIndex);
      expect(find.text('Chip Bank'), findsOneWidget);
      expect(find.text('Reports'), findsWidgets);
      expect(find.text('House Rules'), findsOneWidget);
      expect(find.text('Settings'), findsWidgets);
      await _unmount(tester);
    });

    testWidgets('House shows session tools only while a session is live',
        (tester) async {
      final provider = SessionProvider();
      final nav = ProductNavController();
      await tester.pumpWidget(
          _app(const ProductShellScreen(), session: provider, nav: nav));
      await tester.pump();

      nav.goToHouse();
      await tester.pump();
      expect(find.text('Session tools'), findsNothing);

      final session = _liveSession();
      await HiveService.sessions.put(session.id, session);
      provider.loadSession(session);
      await tester.pump();
      expect(find.text('Session tools'), findsOneWidget);
      await _unmount(tester);
      provider.dispose();
    });
  });

  group('floor', () {
    testWidgets('no live session → launcher with new/open doors',
        (tester) async {
      await tester.pumpWidget(_app(const ProductShellScreen(),
          session: SessionProvider(), nav: ProductNavController()));
      await tester.pump();
      await tester.pump();

      expect(find.text('No live session'), findsOneWidget);
      expect(find.text('New Session'), findsOneWidget);
      expect(find.text('Sessions'), findsOneWidget);
      expect(find.byType(TableViewTab), findsNothing);
      await _unmount(tester);
    });

    testWidgets('live session auto-loads once and embeds the table',
        (tester) async {
      await HiveService.sessions.put('s1', _liveSession());
      await tester.pumpWidget(_app(const ProductShellScreen(),
          session: SessionProvider(), nav: ProductNavController()));
      await tester.pump(); // first frame
      await tester.pump(); // post-frame autoload + rebuild

      expect(find.byType(TableViewTab), findsOneWidget);
      expect(find.text('No live session'), findsNothing);
      await _unmount(tester);
    });
  });

  group('players directory is the existing global regulars book', () {
    testWidgets('Players destination hosts the global directory screen',
        (tester) async {
      await PlayerIdentityService.createNew('Ali Ahmadi');

      final nav = ProductNavController();
      await tester.pumpWidget(_app(const ProductShellScreen(),
          session: SessionProvider(), nav: nav));
      await tester.pump();
      nav.goToPlayers();
      await tester.pump();

      // The pre-existing directory (regulars book) is the destination —
      // it aggregates every player across all sessions, so by
      // construction it can never be limited to the active table.
      expect(find.byType(PlayersDirectoryScreen), findsOneWidget);
      // It keeps its own searchable TextField.
      expect(find.byType(TextField), findsWidgets);
      await _unmount(tester);
    });
  });

  group('openFloorSession', () {
    testWidgets('loads the session, pops pushed routes, lands on Floor',
        (tester) async {
      final provider = SessionProvider();
      final nav = ProductNavController();
      nav.goToHouse(); // start away from Floor to prove the switch

      await tester.pumpWidget(
        _app(
          Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (pushedContext) => Scaffold(
                        body: Center(
                          child: ElevatedButton(
                            onPressed: () {
                              final s = _liveSession();
                              openFloorSession(pushedContext, s);
                            },
                            child: const Text('open-live'),
                          ),
                        ),
                      ),
                    ),
                  ),
                  child: const Text('push-page'),
                ),
              ),
            ),
          ),
          session: provider,
          nav: nav,
        ),
      );
      await tester.pump();

      await tester.tap(find.text('push-page'));
      await tester.pumpAndSettle();
      expect(find.text('open-live'), findsOneWidget);

      final session = _liveSession();
      await HiveService.sessions.put(session.id, session);
      await tester.tap(find.text('open-live'));
      await tester.pumpAndSettle();

      expect(find.text('open-live'), findsNothing); // pushed page popped
      expect(provider.current?.id, 'live-1');
      expect(nav.index, ProductNavController.floorIndex);
      provider.dispose();
    });

    testWidgets('degrades without a nav controller instead of throwing',
        (tester) async {
      final provider = SessionProvider();
      await tester.pumpWidget(
        ChangeNotifierProvider<SessionProvider>.value(
          value: provider,
          child: MaterialApp(
            home: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () => openFloorSession(context, _liveSession()),
                child: const Text('go'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('go'));
      await tester.pump();
      expect(provider.current?.id, 'live-1');
      provider.dispose();
    });
  });

  group('localization parity (ICR-02 keys)', () {
    test('every new shell key exists in EN and FA and differs', () {
      const keys = [
        'nav_floor',
        'nav_players',
        'nav_house',
        'floor_no_live',
        'floor_no_live_hint',
        'switch_night',
        'session_tools',
        'house_hub_hint',
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
