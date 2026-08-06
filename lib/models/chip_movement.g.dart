// GENERATED CODE - mirrors hive_generator output for ChipMovement.
//
// Hand-written to match the rest of this repo. Fields must stay
// contiguous from 0; update the count in write() if you add one.
part of 'chip_movement.dart';

class ChipMovementAdapter extends TypeAdapter<ChipMovement> {
  @override
  final int typeId = 10;

  @override
  ChipMovement read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return ChipMovement(
      id: fields[0] as String,
      sessionId: fields[1] as String?,
      chipTypeId: fields[2] as String,
      chipValue: fields[3] as double,
      quantity: fields[4] as int,
      fromLocation: fields[5] as String,
      toLocation: fields[6] as String,
      reason: fields[7] as String,
      timestamp: fields[8] as DateTime?,
      transactionId: fields[9] as String?,
      note: fields[10] as String?,
    );
  }

  @override
  void write(BinaryWriter writer, ChipMovement obj) {
    writer
      ..writeByte(11)
      ..writeByte(0)
      ..write(obj.id)
      ..writeByte(1)
      ..write(obj.sessionId)
      ..writeByte(2)
      ..write(obj.chipTypeId)
      ..writeByte(3)
      ..write(obj.chipValue)
      ..writeByte(4)
      ..write(obj.quantity)
      ..writeByte(5)
      ..write(obj.fromLocation)
      ..writeByte(6)
      ..write(obj.toLocation)
      ..writeByte(7)
      ..write(obj.reason)
      ..writeByte(8)
      ..write(obj.timestamp)
      ..writeByte(9)
      ..write(obj.transactionId)
      ..writeByte(10)
      ..write(obj.note);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ChipMovementAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
