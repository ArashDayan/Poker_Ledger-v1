// GENERATED CODE - mirrors what `flutter pub run build_runner build`
// would produce for the @HiveType enums in enums.dart.
// Run build_runner after any enum change to keep this in sync.
part of 'enums.dart';

class PlayerTagAdapter extends TypeAdapter<PlayerTag> {
  @override
  final int typeId = 0;

  @override
  PlayerTag read(BinaryReader reader) {
    switch (reader.readByte()) {
      case 0:
        return PlayerTag.vip;
      case 1:
        return PlayerTag.regular;
      case 2:
        return PlayerTag.problemPlayer;
      case 3:
        return PlayerTag.tilt;
      default:
        return PlayerTag.regular;
    }
  }

  @override
  void write(BinaryWriter writer, PlayerTag obj) {
    switch (obj) {
      case PlayerTag.vip:
        writer.writeByte(0);
        break;
      case PlayerTag.regular:
        writer.writeByte(1);
        break;
      case PlayerTag.problemPlayer:
        writer.writeByte(2);
        break;
      case PlayerTag.tilt:
        writer.writeByte(3);
        break;
    }
  }
}

class TransactionTypeAdapter extends TypeAdapter<TransactionType> {
  @override
  final int typeId = 1;

  @override
  TransactionType read(BinaryReader reader) {
    switch (reader.readByte()) {
      case 0:
        return TransactionType.buyIn;
      case 1:
        return TransactionType.rebuy;
      case 2:
        return TransactionType.cashOut;
      case 3:
        return TransactionType.rakeCollection;
      case 4:
        return TransactionType.cashDrop;
      case 5:
        return TransactionType.transferOut;
      case 6:
        return TransactionType.transferIn;
      default:
        return TransactionType.buyIn;
    }
  }

  @override
  void write(BinaryWriter writer, TransactionType obj) {
    switch (obj) {
      case TransactionType.buyIn:
        writer.writeByte(0);
        break;
      case TransactionType.rebuy:
        writer.writeByte(1);
        break;
      case TransactionType.cashOut:
        writer.writeByte(2);
        break;
      case TransactionType.rakeCollection:
        writer.writeByte(3);
        break;
      case TransactionType.cashDrop:
        writer.writeByte(4);
        break;
      case TransactionType.transferOut:
        writer.writeByte(5);
        break;
      case TransactionType.transferIn:
        writer.writeByte(6);
        break;
    }
  }
}

class SessionStatusAdapter extends TypeAdapter<SessionStatus> {
  @override
  final int typeId = 2;

  @override
  SessionStatus read(BinaryReader reader) {
    switch (reader.readByte()) {
      case 0:
        return SessionStatus.active;
      case 1:
        return SessionStatus.onBreak;
      case 2:
        return SessionStatus.ended;
      default:
        return SessionStatus.active;
    }
  }

  @override
  void write(BinaryWriter writer, SessionStatus obj) {
    switch (obj) {
      case SessionStatus.active:
        writer.writeByte(0);
        break;
      case SessionStatus.onBreak:
        writer.writeByte(1);
        break;
      case SessionStatus.ended:
        writer.writeByte(2);
        break;
    }
  }
}

class AppCurrencyAdapter extends TypeAdapter<AppCurrency> {
  @override
  final int typeId = 3;

  @override
  AppCurrency read(BinaryReader reader) {
    switch (reader.readByte()) {
      case 0:
        return AppCurrency.usd;
      case 1:
        return AppCurrency.toman;
      default:
        return AppCurrency.usd;
    }
  }

  @override
  void write(BinaryWriter writer, AppCurrency obj) {
    switch (obj) {
      case AppCurrency.usd:
        writer.writeByte(0);
        break;
      case AppCurrency.toman:
        writer.writeByte(1);
        break;
    }
  }
}

class RakeModeAdapter extends TypeAdapter<RakeMode> {
  @override
  final int typeId = 7;

  @override
  RakeMode read(BinaryReader reader) {
    switch (reader.readByte()) {
      case 0:
        return RakeMode.percentage;
      case 1:
        return RakeMode.fixed;
      case 2:
        return RakeMode.tiered;
      default:
        return RakeMode.percentage;
    }
  }

  @override
  void write(BinaryWriter writer, RakeMode obj) {
    switch (obj) {
      case RakeMode.percentage:
        writer.writeByte(0);
        break;
      case RakeMode.fixed:
        writer.writeByte(1);
        break;
      case RakeMode.tiered:
        writer.writeByte(2);
        break;
    }
  }
}

class SessionModeAdapter extends TypeAdapter<SessionMode> {
  @override
  final int typeId = 8;

  @override
  SessionMode read(BinaryReader reader) {
    switch (reader.readByte()) {
      case 0:
        return SessionMode.cashGame;
      case 1:
        return SessionMode.tournament;
      default:
        return SessionMode.cashGame;
    }
  }

  @override
  void write(BinaryWriter writer, SessionMode obj) {
    switch (obj) {
      case SessionMode.cashGame:
        writer.writeByte(0);
        break;
      case SessionMode.tournament:
        writer.writeByte(1);
        break;
    }
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SessionModeAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
