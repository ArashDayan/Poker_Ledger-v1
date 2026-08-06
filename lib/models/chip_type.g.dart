// GENERATED CODE - mirrors hive_generator output for ChipType.
//
// Hand-written to match the rest of this repo, which ships adapters
// directly so the project builds without running codegen. If you change
// the @HiveField layout, update BOTH the field count in write() and the
// reads below — they must stay contiguous and in step.
part of 'chip_type.dart';

class ChipTypeAdapter extends TypeAdapter<ChipType> {
  @override
  final int typeId = 9;

  @override
  ChipType read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return ChipType(
      id: fields[0] as String,
      name: fields[1] as String?,
      colorValue: fields[2] as int?,
      value: fields[3] as double,
      quantity: fields[4] as int,
      note: fields[5] as String?,
      createdAt: fields[6] as DateTime?,
      updatedAt: fields[7] as DateTime?,
      assignedToTables: fields[8] == null ? 0 : fields[8] as int,
    );
  }

  @override
  void write(BinaryWriter writer, ChipType obj) {
    writer
      ..writeByte(9)
      ..writeByte(0)
      ..write(obj.id)
      ..writeByte(1)
      ..write(obj.name)
      ..writeByte(2)
      ..write(obj.colorValue)
      ..writeByte(3)
      ..write(obj.value)
      ..writeByte(4)
      ..write(obj.quantity)
      ..writeByte(5)
      ..write(obj.note)
      ..writeByte(6)
      ..write(obj.createdAt)
      ..writeByte(7)
      ..write(obj.updatedAt)
      ..writeByte(8)
      ..write(obj.assignedToTables);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ChipTypeAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
