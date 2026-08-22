// GENERATED CODE - mirrors hive_generator output for Hand and its enums.
//
// Hand-written to match the rest of this repo. Fields must stay
// contiguous from 0; update the count in write() if you add one.
part of 'hand.dart';

class HandKindAdapter extends TypeAdapter<HandKind> {
  @override
  final int typeId = 21;

  @override
  HandKind read(BinaryReader reader) => HandKind.values[reader.readByte()];

  @override
  void write(BinaryWriter writer, HandKind obj) => writer.writeByte(obj.index);

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is HandKindAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}

class HandStatusAdapter extends TypeAdapter<HandStatus> {
  @override
  final int typeId = 22;

  @override
  HandStatus read(BinaryReader reader) => HandStatus.values[reader.readByte()];

  @override
  void write(BinaryWriter writer, HandStatus obj) =>
      writer.writeByte(obj.index);

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is HandStatusAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}

class HandAdapter extends TypeAdapter<Hand> {
  @override
  final int typeId = 20;

  @override
  Hand read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return Hand(
      id: fields[0] as String,
      sessionId: fields[1] as String,
      tableId: fields[2] as String,
      handNumber: (fields[3] as num?)?.toInt() ?? 0,
      kind: fields[4] as HandKind? ?? HandKind.poker,
      status: fields[5] as HandStatus? ?? HandStatus.completed,
      completedAt: fields[6] as DateTime?,
      note: fields[7] as String?,
      potAmount: (fields[8] as num?)?.toDouble() ?? 0,
      rakeAmount: (fields[9] as num?)?.toDouble() ?? 0,
      houseWinAmount: (fields[10] as num?)?.toDouble() ?? 0,
      resultsRaw: fields[11] as List? ?? const [],
      rakeTransactionId: fields[12] as String?,
      houseWinTransactionId: fields[13] as String?,
      chipMovementIds: fields[14] as List? ?? const [],
    );
  }

  @override
  void write(BinaryWriter writer, Hand obj) {
    writer
      ..writeByte(15)
      ..writeByte(0)
      ..write(obj.id)
      ..writeByte(1)
      ..write(obj.sessionId)
      ..writeByte(2)
      ..write(obj.tableId)
      ..writeByte(3)
      ..write(obj.handNumber)
      ..writeByte(4)
      ..write(obj.kind)
      ..writeByte(5)
      ..write(obj.status)
      ..writeByte(6)
      ..write(obj.completedAt)
      ..writeByte(7)
      ..write(obj.note)
      ..writeByte(8)
      ..write(obj.potAmount)
      ..writeByte(9)
      ..write(obj.rakeAmount)
      ..writeByte(10)
      ..write(obj.houseWinAmount)
      ..writeByte(11)
      ..write(obj.resultsRaw)
      ..writeByte(12)
      ..write(obj.rakeTransactionId)
      ..writeByte(13)
      ..write(obj.houseWinTransactionId)
      ..writeByte(14)
      ..write(obj.chipMovementIds);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is HandAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
