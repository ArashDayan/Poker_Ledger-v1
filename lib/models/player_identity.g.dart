// GENERATED CODE - mirrors hive_generator output for PlayerIdentity.
//
// Hand-written to match the rest of this repo. Fields must stay
// contiguous from 0; update the count in write() if you add one.
part of 'player_identity.dart';

class PlayerIdentityAdapter extends TypeAdapter<PlayerIdentity> {
  @override
  final int typeId = 11;

  @override
  PlayerIdentity read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return PlayerIdentity(
      id: fields[0] as String,
      displayName: fields[1] as String,
      createdAt: fields[2] as DateTime,
      updatedAt: fields[3] as DateTime,
      note: fields[4] as String?,
    );
  }

  @override
  void write(BinaryWriter writer, PlayerIdentity obj) {
    writer
      ..writeByte(5)
      ..writeByte(0)
      ..write(obj.id)
      ..writeByte(1)
      ..write(obj.displayName)
      ..writeByte(2)
      ..write(obj.createdAt)
      ..writeByte(3)
      ..write(obj.updatedAt)
      ..writeByte(4)
      ..write(obj.note);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PlayerIdentityAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
