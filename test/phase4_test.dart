// Phase 4: two-sample signature profiles, chip sound variations, and a
// migration check that existing data still opens.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:poker_ledger/models/player.dart';
import 'package:poker_ledger/models/session.dart';
import 'package:poker_ledger/models/transaction.dart';
import 'package:poker_ledger/services/hive_service.dart';
import 'package:poker_ledger/services/session_service.dart';
import 'package:poker_ledger/services/sound_service.dart';
import 'package:uuid/uuid.dart';
import 'test_helper.dart';

const _uuid = Uuid();
late Directory _tmp;

Future<void> _open() async {
  _tmp = await Directory.systemTemp.createTemp('pl_phase4_');
  Hive.init(_tmp.path);
  registerTestAdapters();
  await Hive.openBox<PokerSession>(HiveService.sessionsBox);
  await Hive.openBox<Player>(HiveService.playersBox);
  await Hive.openBox<LedgerTransaction>(HiveService.transactionsBox);
  await Hive.openBox(HiveService.settingsBox);
}

Future<void> _close() async {
  await Hive.deleteFromDisk();
  if (await _tmp.exists()) await _tmp.delete(recursive: true);
}

PokerSession _session() {
  final s = PokerSession(
    id: _uuid.v4(),
    name: 'S',
    location: 'R',
    dateTime: DateTime.now(),
    smallBlind: 1,
    bigBlind: 2,
    tableNumber: '1',
  );
  HiveService.sessions.put(s.id, s);
  return s;
}

void main() {
  setUp(_open);
  tearDown(_close);

  group('Two-sample signature profile', () {
    test('a player can hold two independent samples', () async {
      final s = _session();
      final p = Player(
          id: _uuid.v4(), sessionId: s.id, name: 'Ari', seatNumber: 1);
      p.sampleSignatureBase64 = 'AAA';
      p.sampleSignatureAt = DateTime(2026, 1, 1);
      p.sampleSignature2Base64 = 'BBB';
      p.sampleSignature2At = DateTime(2026, 1, 2);
      await HiveService.players.put(p.id, p);

      final r = HiveService.players.get(p.id)!;
      expect(r.hasSampleSignature, isTrue);
      expect(r.hasSecondSample, isTrue);
      expect(r.signatureSamples, ['AAA', 'BBB']);
    });

    test('one sample still works — the second is optional', () {
      final p = Player(
          id: _uuid.v4(), sessionId: 'x', name: 'Solo', seatNumber: 1);
      p.sampleSignatureBase64 = 'AAA';
      expect(p.hasSecondSample, isFalse);
      expect(p.signatureSamples, ['AAA']);
    });

    test('a player with no samples is never blocked', () {
      final p = Player(
          id: _uuid.v4(), sessionId: 'x', name: 'None', seatNumber: 1);
      expect(p.signatureSamples, isEmpty);
      expect(p.hasSampleSignature, isFalse);
    });

    test('samples survive a backup json round trip', () {
      final p = Player(
          id: _uuid.v4(), sessionId: 'x', name: 'Ari', seatNumber: 1);
      p.sampleSignatureBase64 = 'AAA';
      p.sampleSignature2Base64 = 'BBB';
      p.sampleSignature2At = DateTime(2026, 3, 4);
      final restored = Player.fromJson(p.toJson());
      expect(restored.sampleSignature2Base64, 'BBB');
      expect(restored.sampleSignature2At, DateTime(2026, 3, 4));
    });
  });

  group('Chip sound variations', () {
    test('between 4 and 6 selectable options ship', () {
      expect(kChipSamples.length, greaterThanOrEqualTo(4));
      expect(kChipSamples.length, lessThanOrEqualTo(6));
    });

    test('every declared sample file exists on disk', () {
      // A declared-but-missing asset fails SILENTLY at runtime — the app
      // plays nothing and never errors — so it must be caught here.
      for (final s in kChipSamples) {
        final f = File('assets/${s.asset}');
        expect(f.existsSync(), isTrue, reason: '${s.asset} is missing');
        expect(f.lengthSync(), greaterThan(1000));
      }
    });

    test('the master recording still ships', () {
      expect(File('assets/${AppSounds.masterRecording}').existsSync(), isTrue);
    });

    test('no synthesised audio remains — only the master and its cuts', () {
      final wavs = Directory('assets/sounds')
          .listSync()
          .whereType<File>()
          .map((f) => f.uri.pathSegments.last)
          .where((n) => n.toLowerCase().endsWith('.wav'))
          .toList()
        ..sort();
      final expected = [
        'Chip_sound.wav',
        'timer_alarm.wav',
        ...kChipSamples.map((s) => s.asset.split('/').last),
      ]..sort();
      expect(wavs, expected);
    });

    test('ids and titles are unique so the picker is unambiguous', () {
      final ids = kChipSamples.map((s) => s.id).toList();
      final titles = kChipSamples.map((s) => s.title).toList();
      expect(ids.toSet().length, ids.length);
      expect(titles.toSet().length, titles.length);
    });

    test('asset paths omit the assets/ prefix audioplayers adds', () {
      for (final s in kChipSamples) {
        expect(s.asset.startsWith('assets/'), isFalse);
        expect(s.asset.startsWith('sounds/'), isTrue);
      }
    });

    test('an unknown stored id falls back instead of silencing the app',
        () {
      AppSounds.setSample('does_not_exist');
      expect(kChipSamples.any((s) => s.id == AppSounds.selectedSampleId),
          isTrue);
    });

    test('every sample is short enough for a button tap', () {
      for (final s in kChipSamples) {
        expect(s.duration, greaterThan(0.1));
        expect(s.duration, lessThan(1.5));
      }
    });
  });

  group('Migration safety', () {
    test('a player saved without the new fields still loads', () {
      // Simulates data written by an earlier build.
      final json = {
        'id': 'p1',
        'sessionId': 's1',
        'name': 'Legacy',
        'seatNumber': 3,
        'tags': <int>[],
        'isActive': true,
        'isFavorite': false,
        'joinedAt': DateTime(2026, 1, 1).toIso8601String(),
      };
      final p = Player.fromJson(json);
      expect(p.name, 'Legacy');
      expect(p.hasSecondSample, isFalse);
      expect(p.tableId, isNull);
      expect(p.finishPosition, isNull);
    });

    test('a legacy session and its ledger still reconcile', () async {
      final s = _session();
      final p = Player(
          id: _uuid.v4(), sessionId: s.id, name: 'A', seatNumber: 1);
      await HiveService.players.put(p.id, p);
      await SessionService.recordTransaction(
        sessionId: s.id,
        playerId: p.id,
        type: TransactionType.buyIn,
        amount: 500,
        hostSignatureBase64: 'sig',
      );
      await SessionService.recordTransaction(
        sessionId: s.id,
        playerId: p.id,
        type: TransactionType.cashOut,
        amount: 500,
        hostSignatureBase64: 'sig',
      );
      final bal = SessionService.checkBalance(s.id);
      expect(bal.isBalanced, isTrue);
      expect(bal.moneyIn, 500);
    });
  });
}
