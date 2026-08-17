// GENERATED CODE - mirrors hive_generator output for Player.
part of 'player.dart';

class PlayerAdapter extends TypeAdapter<Player> {
  @override
  final int typeId = 4;

  @override
  Player read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return Player(
      id: fields[0] as String,
      sessionId: fields[1] as String,
      name: fields[2] as String,
      photoPath: fields[3] as String?,
      seatNumber: fields[4] as int,
      tags: (fields[5] as List).cast<PlayerTag>(),
      isActive: fields[6] as bool,
      isFavorite: fields[7] as bool,
      joinedAt: fields[8] as DateTime,
      sampleSignatureBase64: fields[9] as String?,
      sampleSignatureAt: fields[10] as DateTime?,
      tableId: fields[11] as String?,
      finishPosition: fields[12] as int?,
      eliminatedAt: fields[13] as DateTime?,
      addOnCount: (fields[14] as int?) ?? 0,
      sampleSignature2Base64: fields[15] as String?,
      sampleSignature2At: fields[16] as DateTime?,
      personId: fields[17] as String?,
    );
  }

  @override
  void write(BinaryWriter writer, Player obj) {
    writer
      ..writeByte(18)
      ..writeByte(0)
      ..write(obj.id)
      ..writeByte(1)
      ..write(obj.sessionId)
      ..writeByte(2)
      ..write(obj.name)
      ..writeByte(3)
      ..write(obj.photoPath)
      ..writeByte(4)
      ..write(obj.seatNumber)
      ..writeByte(5)
      ..write(obj.tags)
      ..writeByte(6)
      ..write(obj.isActive)
      ..writeByte(7)
      ..write(obj.isFavorite)
      ..writeByte(8)
      ..write(obj.joinedAt)
      ..writeByte(9)
      ..write(obj.sampleSignatureBase64)
      ..writeByte(10)
      ..write(obj.sampleSignatureAt)
      ..writeByte(11)
      ..write(obj.tableId)
      ..writeByte(12)
      ..write(obj.finishPosition)
      ..writeByte(13)
      ..write(obj.eliminatedAt)
      ..writeByte(14)
      ..write(obj.addOnCount)
      ..writeByte(15)
      ..write(obj.sampleSignature2Base64)
      ..writeByte(16)
      ..write(obj.sampleSignature2At)
      ..writeByte(17)
      ..write(obj.personId);
  }
}
