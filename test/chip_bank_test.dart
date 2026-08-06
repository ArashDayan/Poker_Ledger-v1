// Chip Bank: physical chip inventory.
//
// Covers the maths, the optional-field rules (colour and name must be
// genuinely optional), CRUD, and — most importantly — that none of it
// can touch the ledger.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:poker_ledger/models/chip_type.dart';
import 'package:poker_ledger/models/player.dart';
import 'package:poker_ledger/models/session.dart';
import 'package:poker_ledger/models/transaction.dart';
import 'package:poker_ledger/services/chip_bank_service.dart';
import 'package:poker_ledger/services/hive_service.dart';
import 'package:poker_ledger/services/session_service.dart';
import 'test_helper.dart';

late Directory _tmp;

Future<void> _open() async {
  _tmp = await Directory.systemTemp.createTemp('pl_chipbank_');
  Hive.init(_tmp.path);
  registerTestAdapters();
  await Hive.openBox<PokerSession>(HiveService.sessionsBox);
  await Hive.openBox<Player>(HiveService.playersBox);
  await Hive.openBox<LedgerTransaction>(HiveService.transactionsBox);
  await Hive.openBox(HiveService.settingsBox);
  await Hive.openBox<ChipType>(HiveService.chipsBox);
}

Future<void> _close() async {
  await Hive.deleteFromDisk();
  if (await _tmp.exists()) await _tmp.delete(recursive: true);
}

void main() {
  setUp(_open);
  tearDown(_close);

  group('calculations', () {
    test('the example from the spec totals correctly', () async {
      // 200 x 100  =  20,000
      // 1000 x 500 = 500,000
      //            = 520,000
      await ChipBankService.addChip(value: 200, quantity: 100);
      await ChipBankService.addChip(value: 1000, quantity: 500);

      final s = ChipBankService.summary();
      expect(s.totalValue, 520000);
      expect(s.totalChips, 600);
      expect(s.typeCount, 2);
    });

    test('per-type total is value x quantity', () async {
      final chip =
          await ChipBankService.addChip(value: 5000, quantity: 50);
      expect(chip.totalValue, 250000);
    });

    test('an empty bank totals zero, not null', () {
      final s = ChipBankService.summary();
      expect(s.totalValue, 0);
      expect(s.totalChips, 0);
      expect(s.typeCount, 0);
    });

    test('a zero quantity contributes nothing but still exists', () async {
      await ChipBankService.addChip(value: 100, quantity: 0);
      final s = ChipBankService.summary();
      expect(s.totalValue, 0);
      expect(s.totalChips, 0);
      expect(s.typeCount, 1);
    });

    test('fractional denominations are handled', () async {
      await ChipBankService.addChip(value: 0.25, quantity: 400);
      expect(ChipBankService.summary().totalValue, closeTo(100, 1e-9));
    });

    test('totals update after an edit', () async {
      final chip =
          await ChipBankService.addChip(value: 200, quantity: 100);
      expect(ChipBankService.summary().totalValue, 20000);

      await ChipBankService.setQuantity(chip.id, 80);
      expect(ChipBankService.summary().totalValue, 16000);

      await ChipBankService.updateChip(chip.id, value: 500);
      expect(ChipBankService.summary().totalValue, 40000);
    });
  });

  group('colour and name are optional', () {
    test('a chip needs only value and quantity', () async {
      final chip = await ChipBankService.addChip(value: 200, quantity: 100);
      expect(chip.colorValue, isNull);
      expect(chip.name, isNull);
      expect(chip.hasColor, isFalse);
      expect(chip.hasName, isFalse);
      expect(chip.totalValue, 20000);
    });

    test('an entire inventory works with no colours at all', () async {
      await ChipBankService.addChip(value: 200, quantity: 100);
      await ChipBankService.addChip(value: 1000, quantity: 500);
      await ChipBankService.addChip(value: 5000, quantity: 50);

      final chips = ChipBankService.allChips();
      expect(chips.every((c) => !c.hasColor), isTrue);
      expect(ChipBankService.summary().totalValue, 770000);
    });

    test('blank name and note are stored as null, not empty strings',
        () async {
      final chip = await ChipBankService.addChip(
          value: 100, quantity: 1, name: '   ', note: '  ');
      expect(chip.name, isNull);
      expect(chip.note, isNull);
    });

    test('a colour can be set and then removed again', () async {
      final chip = await ChipBankService.addChip(
          value: 500, quantity: 300, colorValue: 0xFFE74C3C);
      expect(ChipBankService.byId(chip.id)!.hasColor, isTrue);

      await ChipBankService.updateChip(chip.id, clearColor: true);
      expect(ChipBankService.byId(chip.id)!.hasColor, isFalse);
      // Removing the colour must not disturb the numbers.
      expect(ChipBankService.byId(chip.id)!.totalValue, 150000);
    });

    test('a name can be cleared without touching value or quantity',
        () async {
      final chip = await ChipBankService.addChip(
          value: 200, quantity: 100, name: 'High Value Chip');
      await ChipBankService.updateChip(chip.id, clearName: true);

      final after = ChipBankService.byId(chip.id)!;
      expect(after.name, isNull);
      expect(after.value, 200);
      expect(after.quantity, 100);
    });
  });

  group('banker control', () {
    test('chips can be added, edited and removed', () async {
      final a = await ChipBankService.addChip(value: 200, quantity: 100);
      final b = await ChipBankService.addChip(value: 1000, quantity: 500);
      expect(ChipBankService.allChips().length, 2);

      await ChipBankService.removeChip(a.id);
      expect(ChipBankService.allChips().length, 1);
      expect(ChipBankService.byId(a.id), isNull);
      expect(ChipBankService.byId(b.id), isNotNull);
      expect(ChipBankService.summary().totalValue, 500000);
    });

    test('the day-to-day recount from the spec', () async {
      // Today: 100 x 200, 500 x 1000
      final a = await ChipBankService.addChip(value: 200, quantity: 100);
      final b = await ChipBankService.addChip(value: 1000, quantity: 500);
      expect(ChipBankService.summary().totalValue, 520000);

      // Tomorrow: 80 x 200, 700 x 1000
      await ChipBankService.setQuantity(a.id, 80);
      await ChipBankService.setQuantity(b.id, 700);

      final s = ChipBankService.summary();
      expect(s.totalValue, 716000); // 16,000 + 700,000
      expect(s.totalChips, 780);
    });

    test('quantity can be nudged up and down', () async {
      final chip = await ChipBankService.addChip(value: 100, quantity: 10);
      await ChipBankService.adjustQuantity(chip.id, 5);
      expect(ChipBankService.byId(chip.id)!.quantity, 15);
      await ChipBankService.adjustQuantity(chip.id, -3);
      expect(ChipBankService.byId(chip.id)!.quantity, 12);
    });

    test('quantity can never go negative', () async {
      final chip = await ChipBankService.addChip(value: 100, quantity: 5);
      await ChipBankService.adjustQuantity(chip.id, -50);
      expect(ChipBankService.byId(chip.id)!.quantity, 0);

      await ChipBankService.addChip(value: 50, quantity: -10);
      expect(ChipBankService.allChips().last.quantity, greaterThanOrEqualTo(0));
    });

    test('editing an unknown id is a no-op rather than a crash', () async {
      await ChipBankService.updateChip('does-not-exist', quantity: 5);
      expect(ChipBankService.allChips(), isEmpty);
    });

    test('chips are listed highest denomination first', () async {
      await ChipBankService.addChip(value: 200, quantity: 1);
      await ChipBankService.addChip(value: 5000, quantity: 1);
      await ChipBankService.addChip(value: 1000, quantity: 1);

      expect(ChipBankService.allChips().map((c) => c.value).toList(),
          [5000, 1000, 200]);
    });

    test('updatedAt moves when the banker corrects a count', () async {
      final chip = await ChipBankService.addChip(value: 100, quantity: 10);
      final before = chip.updatedAt;
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await ChipBankService.setQuantity(chip.id, 20);
      expect(ChipBankService.byId(chip.id)!.updatedAt.isAfter(before), isTrue);
    });
  });

  group('persistence', () {
    test('a chip survives a reload through its adapter', () async {
      final chip = await ChipBankService.addChip(
        value: 1000,
        quantity: 500,
        name: 'Premium Chip',
        colorValue: 0xFF2E86DE,
        note: 'spare case',
      );

      await Hive.box<ChipType>(HiveService.chipsBox).close();
      await Hive.openBox<ChipType>(HiveService.chipsBox);

      final loaded = ChipBankService.byId(chip.id)!;
      expect(loaded.value, 1000);
      expect(loaded.quantity, 500);
      expect(loaded.name, 'Premium Chip');
      expect(loaded.colorValue, 0xFF2E86DE);
      expect(loaded.note, 'spare case');
      expect(loaded.assignedToTables, 0);
      expect(loaded.totalValue, 500000);
    });

    test('a colourless chip round-trips with a null colour', () async {
      final chip = await ChipBankService.addChip(value: 25, quantity: 8);
      await Hive.box<ChipType>(HiveService.chipsBox).close();
      await Hive.openBox<ChipType>(HiveService.chipsBox);

      final loaded = ChipBankService.byId(chip.id)!;
      expect(loaded.colorValue, isNull);
      expect(loaded.name, isNull);
    });

    test('json round-trip preserves every field', () async {
      final chip = await ChipBankService.addChip(
          value: 200, quantity: 100, name: 'X', colorValue: 0xFFE74C3C);
      final copy = ChipType.fromJson(chip.toJson());

      expect(copy.id, chip.id);
      expect(copy.value, chip.value);
      expect(copy.quantity, chip.quantity);
      expect(copy.name, chip.name);
      expect(copy.colorValue, chip.colorValue);
    });
  });

  group('future integration seams are read-only', () {
    test('availableQuantity equals quantity while unassigned', () async {
      final chip = await ChipBankService.addChip(value: 100, quantity: 40);
      expect(chip.availableQuantity, 40);
    });

    test('sufficiency checks compute without mutating anything', () async {
      await ChipBankService.addChip(value: 200, quantity: 100);

      expect(ChipBankService.hasEnoughValue(15000), isTrue);
      expect(ChipBankService.hasEnoughValue(25000), isFalse);
      expect(ChipBankService.availableValue(), 20000);
      expect(ChipBankService.shortfallFor(30000), 10000);
      expect(ChipBankService.shortfallFor(5000), 0);

      // Nothing was deducted — the spec explicitly forbids automatic
      // deduction for now.
      expect(ChipBankService.summary().totalChips, 100);
      expect(ChipBankService.summary().totalValue, 20000);
    });
  });

  group('the ledger is never affected', () {
    test('chip operations leave sessions, players and transactions alone',
        () async {
      await HiveService.players.put(
        'p1',
        Player(id: 'p1', sessionId: 's1', name: 'Ali', seatNumber: 1),
      );
      await HiveService.sessions.put(
        's1',
        PokerSession(
          id: 's1',
          name: 'Friday Game',
          location: 'Home',
          dateTime: DateTime.now(),
          smallBlind: 1,
          bigBlind: 2,
          tableNumber: '1',
        ),
      );
      await HiveService.transactions.put(
        't1',
        LedgerTransaction(
          id: 't1',
          sessionId: 's1',
          playerId: 'p1',
          type: TransactionType.buyIn,
          amount: 100,
        ),
      );

      final chip = await ChipBankService.addChip(value: 200, quantity: 100);
      await ChipBankService.setQuantity(chip.id, 80);
      await ChipBankService.adjustQuantity(chip.id, 5);
      await ChipBankService.removeChip(chip.id);

      expect(HiveService.players.length, 1);
      expect(HiveService.sessions.length, 1);
      expect(HiveService.transactions.length, 1);
      expect(HiveService.players.get('p1')!.name, 'Ali');
      expect(HiveService.transactions.get('t1')!.amount, 100);
    });

    test('settlement is identical with and without a chip inventory',
        () async {
      final session = PokerSession(
        id: 's1',
        name: 'Game',
        location: 'Home',
        dateTime: DateTime.now(),
        smallBlind: 1,
        bigBlind: 2,
        tableNumber: '1',
      );
      await HiveService.sessions.put(session.id, session);
      await HiveService.players.put(
        'p1',
        Player(id: 'p1', sessionId: 's1', name: 'Ali', seatNumber: 1),
      );
      await HiveService.transactions.put(
        't1',
        LedgerTransaction(
          id: 't1',
          sessionId: 's1',
          playerId: 'p1',
          type: TransactionType.buyIn,
          amount: 100,
        ),
      );

      final before = SessionService.checkBalance(session.id);

      await ChipBankService.addChip(value: 200, quantity: 100);
      await ChipBankService.addChip(value: 1000, quantity: 500);

      final after = SessionService.checkBalance(session.id);

      expect(after.moneyIn, before.moneyIn);
      expect(after.moneyOut, before.moneyOut);
      expect(after.discrepancy, before.discrepancy);
      expect(after.isBalanced, before.isBalanced);
      // And the ledger figures themselves are unchanged.
      expect(SessionService.totalBuyIn(session.id), 100);
    });

    test('the chip box is separate from every ledger box', () async {
      await ChipBankService.addChip(value: 200, quantity: 100);
      expect(HiveService.chips.length, 1);
      expect(HiveService.players.length, 0);
      expect(HiveService.sessions.length, 0);
      expect(HiveService.transactions.length, 0);
    });
  });
}
