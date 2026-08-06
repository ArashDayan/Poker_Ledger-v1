// GENERATED CODE - mirrors hive_generator output for LedgerTransaction.
part of 'transaction.dart';

class LedgerTransactionAdapter extends TypeAdapter<LedgerTransaction> {
  @override
  final int typeId = 5;

  @override
  LedgerTransaction read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return LedgerTransaction(
      id: fields[0] as String,
      sessionId: fields[1] as String,
      playerId: fields[2] as String?,
      type: fields[3] as TransactionType,
      amount: fields[4] as double,
      timestamp: fields[5] as DateTime,
      hostSignatureBase64: fields[6] as String?,
      note: fields[7] as String?,
      voiceNotePath: fields[8] as String?,
      isVoided: fields[9] as bool,
      isEdited: fields[10] == null ? false : fields[10] as bool,
      editedAt: fields[11] as DateTime?,
      signedWhileAbsent: fields[12] == null ? false : fields[12] as bool,
      tableId: fields[13] as String?,
    );
  }

  @override
  void write(BinaryWriter writer, LedgerTransaction obj) {
    writer
      ..writeByte(14)
      ..writeByte(0)
      ..write(obj.id)
      ..writeByte(1)
      ..write(obj.sessionId)
      ..writeByte(2)
      ..write(obj.playerId)
      ..writeByte(3)
      ..write(obj.type)
      ..writeByte(4)
      ..write(obj.amount)
      ..writeByte(5)
      ..write(obj.timestamp)
      ..writeByte(6)
      ..write(obj.hostSignatureBase64)
      ..writeByte(7)
      ..write(obj.note)
      ..writeByte(8)
      ..write(obj.voiceNotePath)
      ..writeByte(9)
      ..write(obj.isVoided)
      ..writeByte(10)
      ..write(obj.isEdited)
      ..writeByte(11)
      ..write(obj.editedAt)
      ..writeByte(12)
      ..write(obj.signedWhileAbsent)
      ..writeByte(13)
      ..write(obj.tableId);
  }
}
