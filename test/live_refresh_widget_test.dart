// Phase 6 widget test: a fresh SessionProvider + a table-like list
// must show a player the moment addPlayer completes — no navigation.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:poker_ledger/models/financial_event.dart';
import 'package:poker_ledger/models/hand.dart';
import 'package:poker_ledger/models/player.dart';
import 'package:poker_ledger/models/session.dart';
import 'package:poker_ledger/models/transaction.dart';
import 'package:poker_ledger/providers/session_provider.dart';
import 'package:poker_ledger/services/hive_service.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';

import 'test_helper.dart';

const _uuid = Uuid();

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('pl_phase6_w_');
    Hive.init(tmp.path);
    registerTestAdapters();
    await Hive.openBox<PokerSession>(HiveService.sessionsBox);
    await Hive.openBox<Player>(HiveService.playersBox);
    await Hive.openBox<LedgerTransaction>(HiveService.transactionsBox);
    await Hive.openBox(HiveService.settingsBox);
    await Hive.openBox<FinancialEvent>(HiveService.financialEventsBox);
    await Hive.openBox<Hand>(HiveService.handsBox);
  });

  tearDown(() async {
    await Hive.deleteFromDisk();
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  testWidgets('add Player → table list updates on a fresh Provider',
      (tester) async {
    final provider = SessionProvider();
    final session = PokerSession(
      id: _uuid.v4(),
      name: 'Live',
      location: 'Room',
      dateTime: DateTime.now(),
      smallBlind: 1,
      bigBlind: 2,
      tableNumber: '1',
    );
    await HiveService.sessions.put(session.id, session);
    provider.loadSession(session);

    await tester.pumpWidget(
      ChangeNotifierProvider<SessionProvider>.value(
        value: provider,
        child: const MaterialApp(home: _TableProbe()),
      ),
    );

    expect(find.text('empty-table'), findsOneWidget);

    await provider.addPlayer(name: 'Hank', seatNumber: 2);
    await tester.pump();

    expect(find.text('Hank'), findsOneWidget);
    expect(find.text('empty-table'), findsNothing);
    provider.dispose();
  });
}

class _TableProbe extends StatelessWidget {
  const _TableProbe();

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<SessionProvider>();
    final seated = provider.playersAtActiveTable;
    if (seated.isEmpty) {
      return const Scaffold(body: Text('empty-table'));
    }
    return Scaffold(
      body: ListView(
        children: [
          for (final p in seated) Text(p.name),
        ],
      ),
    );
  }
}
