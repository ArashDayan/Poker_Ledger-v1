// GENERATED CODE - mirrors hive_generator output for PokerSession.
part of 'session.dart';

class PokerSessionAdapter extends TypeAdapter<PokerSession> {
  @override
  final int typeId = 6;

  @override
  PokerSession read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return PokerSession(
      id: fields[0] as String,
      name: fields[1] as String,
      location: fields[2] as String,
      dateTime: fields[3] as DateTime,
      smallBlind: fields[4] as double,
      bigBlind: fields[5] as double,
      rakePercentage: fields[6] as double,
      tableNumber: fields[7] as String,
      status: fields[8] as SessionStatus,
      currency: fields[9] as AppCurrency,
      endedAt: fields[10] as DateTime?,
      totalBreakSeconds: fields[11] as int,
      breakStartedAt: fields[12] as DateTime?,
      hostName: fields[13] as String?,
      currentLevel: fields[14] == null ? 1 : fields[14] as int,
      buyInCapAmount: fields[15] as double?,
      defaultBuyInAmount: fields[16] as double?,
      rakeMode: fields[17] == null ? RakeMode.percentage : fields[17] as RakeMode,
      fixedRakeAmount: fields[18] as double?,
      tieredRakeRules: (fields[19] as List?)?.cast<Map>(),
      tieredMaxRake: fields[20] as double?,
      tieredNoRakeAtOrAbove: fields[21] as double?,
      rebuyLastLevel: fields[22] == null ? 6 : fields[22] as int,
      tableSeatCount: fields[23] == null ? 9 : fields[23] as int,
      dealerSeatIndex: fields[24] == null ? 1 : fields[24] as int,
      quickRakeAmounts: (fields[25] as List?)?.cast<double>(),
      rebuyLevelEnforcementEnabled: fields[26] == null ? true : fields[26] as bool,
      tables: (fields[27] as List?)?.cast<Map>(),
      plannedMinutes: fields[28] as int?,
      tenMinuteWarningShown: fields[29] as bool? ?? false,
      finishNoticeShown: fields[30] as bool? ?? false,
      mode: (fields[31] as SessionMode?) ?? SessionMode.cashGame,
      blindLevels: (fields[32] as List?)?.cast<Map>(),
      currentBlindIndex: (fields[33] as int?) ?? 0,
      levelStartedAt: fields[34] as DateTime?,
      levelElapsedSeconds: (fields[35] as int?) ?? 0,
      blindTimerRunning: (fields[36] as bool?) ?? false,
      tournamentBuyIn: (fields[37] as num?)?.toDouble(),
      tournamentFee: (fields[38] as num?)?.toDouble(),
      tournamentRebuy: (fields[39] as num?)?.toDouble(),
      tournamentAddOn: (fields[40] as num?)?.toDouble(),
      startingStack: fields[41] as int?,
      payoutPercentages:
          (fields[42] as List?)?.map((e) => (e as num).toDouble()).toList(),
      blindNoticesShown: (fields[43] as List?)?.cast<String>(),
      rebateEnabled: fields[44] as bool? ?? false,
      rebateMinLoss: (fields[45] as num?)?.toDouble(),
      rebatePercent: (fields[46] as num?)?.toDouble(),
      plannedEndAt: fields[47] as DateTime?,
    );
  }

  @override
  void write(BinaryWriter writer, PokerSession obj) {
    writer
      ..writeByte(48)
      ..writeByte(0)
      ..write(obj.id)
      ..writeByte(1)
      ..write(obj.name)
      ..writeByte(2)
      ..write(obj.location)
      ..writeByte(3)
      ..write(obj.dateTime)
      ..writeByte(4)
      ..write(obj.smallBlind)
      ..writeByte(5)
      ..write(obj.bigBlind)
      ..writeByte(6)
      ..write(obj.rakePercentage)
      ..writeByte(7)
      ..write(obj.tableNumber)
      ..writeByte(8)
      ..write(obj.status)
      ..writeByte(9)
      ..write(obj.currency)
      ..writeByte(10)
      ..write(obj.endedAt)
      ..writeByte(11)
      ..write(obj.totalBreakSeconds)
      ..writeByte(12)
      ..write(obj.breakStartedAt)
      ..writeByte(13)
      ..write(obj.hostName)
      ..writeByte(14)
      ..write(obj.currentLevel)
      ..writeByte(15)
      ..write(obj.buyInCapAmount)
      ..writeByte(16)
      ..write(obj.defaultBuyInAmount)
      ..writeByte(17)
      ..write(obj.rakeMode)
      ..writeByte(18)
      ..write(obj.fixedRakeAmount)
      ..writeByte(19)
      ..write(obj.tieredRakeRules)
      ..writeByte(20)
      ..write(obj.tieredMaxRake)
      ..writeByte(21)
      ..write(obj.tieredNoRakeAtOrAbove)
      ..writeByte(22)
      ..write(obj.rebuyLastLevel)
      ..writeByte(23)
      ..write(obj.tableSeatCount)
      ..writeByte(24)
      ..write(obj.dealerSeatIndex)
      ..writeByte(25)
      ..write(obj.quickRakeAmounts)
      ..writeByte(26)
      ..write(obj.rebuyLevelEnforcementEnabled)
      ..writeByte(27)
      ..write(obj.tables)
      ..writeByte(28)
      ..write(obj.plannedMinutes)
      ..writeByte(29)
      ..write(obj.tenMinuteWarningShown)
      ..writeByte(30)
      ..write(obj.finishNoticeShown)
      ..writeByte(31)
      ..write(obj.mode)
      ..writeByte(32)
      ..write(obj.blindLevels)
      ..writeByte(33)
      ..write(obj.currentBlindIndex)
      ..writeByte(34)
      ..write(obj.levelStartedAt)
      ..writeByte(35)
      ..write(obj.levelElapsedSeconds)
      ..writeByte(36)
      ..write(obj.blindTimerRunning)
      ..writeByte(37)
      ..write(obj.tournamentBuyIn)
      ..writeByte(38)
      ..write(obj.tournamentFee)
      ..writeByte(39)
      ..write(obj.tournamentRebuy)
      ..writeByte(40)
      ..write(obj.tournamentAddOn)
      ..writeByte(41)
      ..write(obj.startingStack)
      ..writeByte(42)
      ..write(obj.payoutPercentages)
      ..writeByte(43)
      ..write(obj.blindNoticesShown)
      ..writeByte(44)
      ..write(obj.rebateEnabled)
      ..writeByte(45)
      ..write(obj.rebateMinLoss)
      ..writeByte(46)
      ..write(obj.rebatePercent)
      ..writeByte(47)
      ..write(obj.plannedEndAt);
  }
}
