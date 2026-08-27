// GENERATED CODE - mirrors hive_generator output for BankCount.
//
// Hand-written to match the rest of this repo. Fields must stay
// contiguous from 0; update the count in write() if you add one.
part of 'bank_count.dart';

class BankCountAdapter extends TypeAdapter<BankCount> {
  @override
  final int typeId = 17;

  @override
  BankCount read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return BankCount(
      id: fields[0] as String,
      countedAt: fields[1] as DateTime,
      counts: (fields[2] as Map)
          .map((k, v) => MapEntry(k as String, (v as num).toInt())),
      note: fields[3] as String?,
      createdAt: fields[4] as DateTime?,
    );
  }

  @override
  void write(BinaryWriter writer, BankCount obj) {
    writer
      ..writeByte(5)
      ..writeByte(0)
      ..write(obj.id)
      ..writeByte(1)
      ..write(obj.countedAt)
      ..writeByte(2)
      ..write(obj.counts)
      ..writeByte(3)
      ..write(obj.note)
      ..writeByte(4)
      ..write(obj.createdAt);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is BankCountAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
