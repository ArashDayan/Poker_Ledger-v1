// GENERATED CODE - mirrors hive_generator output for PlayerIdentity.
//
// Hand-written to match the rest of this repo. Fields must stay
// contiguous from 0; update the count in write() if you add one.
//
// ICR-01: fields 5–11 appended after the frozen fields 0–4. Records
// written by any pre-ICR-01 build carry only 5 fields; read() maps
// their numbers by index, so missing trailing keys simply fall back
// to the constructor defaults below (0 / '' / null). Hive typeId 16
// was NOT consumed for this — the extension is additive on typeId 11.
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
      // ICR-01 fields — absent in pre-ICR-01 records; defaults are the
      // same values the migration treats as "not yet backfilled".
      playerNumber: fields[5] as int? ?? 0,
      firstName: fields[6] as String? ?? '',
      lastName: fields[7] as String? ?? '',
      idNumber: fields[8] as String?,
      sampleSignatureBase64: fields[9] as String?,
      sampleSignature2Base64: fields[10] as String?,
      creditLimitMinor: fields[11] as int? ?? 0,
    );
  }

  @override
  void write(BinaryWriter writer, PlayerIdentity obj) {
    writer
      ..writeByte(12)
      ..writeByte(0)
      ..write(obj.id)
      ..writeByte(1)
      ..write(obj.displayName)
      ..writeByte(2)
      ..write(obj.createdAt)
      ..writeByte(3)
      ..write(obj.updatedAt)
      ..writeByte(4)
      ..write(obj.note)
      ..writeByte(5)
      ..write(obj.playerNumber)
      ..writeByte(6)
      ..write(obj.firstName)
      ..writeByte(7)
      ..write(obj.lastName)
      ..writeByte(8)
      ..write(obj.idNumber)
      ..writeByte(9)
      ..write(obj.sampleSignatureBase64)
      ..writeByte(10)
      ..write(obj.sampleSignature2Base64)
      ..writeByte(11)
      ..write(obj.creditLimitMinor);
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
