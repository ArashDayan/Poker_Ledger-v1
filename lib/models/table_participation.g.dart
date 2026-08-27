// GENERATED CODE - mirrors hive_generator output for
// TableParticipation and its enums.
//
// Hand-written to match the rest of this repo.
part of 'table_participation.dart';

class ParticipationStatusAdapter extends TypeAdapter<ParticipationStatus> {
  @override
  final int typeId = 18;

  @override
  ParticipationStatus read(BinaryReader reader) =>
      ParticipationStatus.values[reader.readByte()];

  @override
  void write(BinaryWriter writer, ParticipationStatus obj) =>
      writer.writeByte(obj.index);

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ParticipationStatusAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}

class ParticipationCloseReasonAdapter
    extends TypeAdapter<ParticipationCloseReason> {
  @override
  final int typeId = 19;

  @override
  ParticipationCloseReason read(BinaryReader reader) =>
      ParticipationCloseReason.values[reader.readByte()];

  @override
  void write(BinaryWriter writer, ParticipationCloseReason obj) =>
      writer.writeByte(obj.index);

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ParticipationCloseReasonAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}

class TableParticipationAdapter extends TypeAdapter<TableParticipation> {
  @override
  final int typeId = 15;

  @override
  TableParticipation read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return TableParticipation(
      id: fields[0] as String,
      sessionId: fields[1] as String,
      personId: fields[2] as String?,
      tableId: fields[3] as String,
      seatPlayerId: fields[4] as String,
      openedAt: fields[5] as DateTime?,
      closedAt: fields[6] as DateTime?,
      status: (fields[7] as ParticipationStatus?) ?? ParticipationStatus.open,
      closeReason: fields[8] as ParticipationCloseReason?,
    );
  }

  @override
  void write(BinaryWriter writer, TableParticipation obj) {
    writer
      ..writeByte(9)
      ..writeByte(0)
      ..write(obj.id)
      ..writeByte(1)
      ..write(obj.sessionId)
      ..writeByte(2)
      ..write(obj.personId)
      ..writeByte(3)
      ..write(obj.tableId)
      ..writeByte(4)
      ..write(obj.seatPlayerId)
      ..writeByte(5)
      ..write(obj.openedAt)
      ..writeByte(6)
      ..write(obj.closedAt)
      ..writeByte(7)
      ..write(obj.status)
      ..writeByte(8)
      ..write(obj.closeReason);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TableParticipationAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
