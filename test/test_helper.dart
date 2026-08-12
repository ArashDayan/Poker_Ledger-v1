import 'package:hive/hive.dart';
import 'package:poker_ledger/models/chip_movement.dart';
import 'package:poker_ledger/models/chip_type.dart';
import 'package:poker_ledger/models/financial_event.dart';
import 'package:poker_ledger/models/player.dart';
import 'package:poker_ledger/models/player_identity.dart';
import 'package:poker_ledger/models/session.dart';
import 'package:poker_ledger/models/transaction.dart';

/// Registers all Hive adapters safely for testing, ensuring each is only
/// registered once even if multiple test suites run in the same process.
void registerTestAdapters() {
  if (!Hive.isAdapterRegistered(0)) Hive.registerAdapter(PlayerTagAdapter());
  if (!Hive.isAdapterRegistered(1)) Hive.registerAdapter(TransactionTypeAdapter());
  if (!Hive.isAdapterRegistered(2)) Hive.registerAdapter(SessionStatusAdapter());
  if (!Hive.isAdapterRegistered(3)) Hive.registerAdapter(AppCurrencyAdapter());
  if (!Hive.isAdapterRegistered(7)) Hive.registerAdapter(RakeModeAdapter());
  if (!Hive.isAdapterRegistered(8)) Hive.registerAdapter(SessionModeAdapter());
  if (!Hive.isAdapterRegistered(4)) Hive.registerAdapter(PlayerAdapter());
  if (!Hive.isAdapterRegistered(5)) Hive.registerAdapter(LedgerTransactionAdapter());
  if (!Hive.isAdapterRegistered(6)) Hive.registerAdapter(PokerSessionAdapter());
  if (!Hive.isAdapterRegistered(9)) Hive.registerAdapter(ChipTypeAdapter());
  if (!Hive.isAdapterRegistered(10)) Hive.registerAdapter(ChipMovementAdapter());
  if (!Hive.isAdapterRegistered(11)) Hive.registerAdapter(PlayerIdentityAdapter());
}
