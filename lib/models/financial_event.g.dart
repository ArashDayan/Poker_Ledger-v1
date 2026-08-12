// GENERATED CODE - mirrors hive_generator output for the Financial Ledger.
//
// Hand-written to match the rest of this repo. typeIds 12–14 are
// permanent. Fields on FinancialEvent must stay contiguous from 0;
// update the count in write() if you add one.
part of 'financial_event.dart';

class FinancialEventTypeAdapter extends TypeAdapter<FinancialEventType> {
  @override
  final int typeId = 13;

  @override
  FinancialEventType read(BinaryReader reader) {
    switch (reader.readByte()) {
      case 0:
        return FinancialEventType.cashInForChips;
      case 1:
        return FinancialEventType.cashOutForChips;
      case 2:
        return FinancialEventType.creditIssued;
      case 3:
        return FinancialEventType.creditRepaid;
      case 4:
        return FinancialEventType.cashOutUnbacked;
      case 5:
        return FinancialEventType.frontMoneyIn;
      case 6:
        return FinancialEventType.frontMoneyOut;
      case 7:
        return FinancialEventType.adjustment;
      case 8:
        return FinancialEventType.rebateGranted;
      case 9:
        return FinancialEventType.rebateRecovered;
      default:
        return FinancialEventType.cashInForChips;
    }
  }

  @override
  void write(BinaryWriter writer, FinancialEventType obj) {
    switch (obj) {
      case FinancialEventType.cashInForChips:
        writer.writeByte(0);
        break;
      case FinancialEventType.cashOutForChips:
        writer.writeByte(1);
        break;
      case FinancialEventType.creditIssued:
        writer.writeByte(2);
        break;
      case FinancialEventType.creditRepaid:
        writer.writeByte(3);
        break;
      case FinancialEventType.cashOutUnbacked:
        writer.writeByte(4);
        break;
      case FinancialEventType.frontMoneyIn:
        writer.writeByte(5);
        break;
      case FinancialEventType.frontMoneyOut:
        writer.writeByte(6);
        break;
      case FinancialEventType.adjustment:
        writer.writeByte(7);
        break;
      case FinancialEventType.rebateGranted:
        writer.writeByte(8);
        break;
      case FinancialEventType.rebateRecovered:
        writer.writeByte(9);
        break;
    }
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is FinancialEventTypeAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}

class PaymentMethodAdapter extends TypeAdapter<PaymentMethod> {
  @override
  final int typeId = 14;

  @override
  PaymentMethod read(BinaryReader reader) {
    switch (reader.readByte()) {
      case 0:
        return PaymentMethod.cash;
      case 1:
        return PaymentMethod.bankTransfer;
      case 2:
        return PaymentMethod.other;
      default:
        return PaymentMethod.other;
    }
  }

  @override
  void write(BinaryWriter writer, PaymentMethod obj) {
    switch (obj) {
      case PaymentMethod.cash:
        writer.writeByte(0);
        break;
      case PaymentMethod.bankTransfer:
        writer.writeByte(1);
        break;
      case PaymentMethod.other:
        writer.writeByte(2);
        break;
    }
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PaymentMethodAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}

class FinancialEventAdapter extends TypeAdapter<FinancialEvent> {
  @override
  final int typeId = 12;

  @override
  FinancialEvent read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return FinancialEvent(
      id: fields[0] as String,
      personId: fields[1] as String,
      currency: fields[2] as AppCurrency,
      type: fields[3] as FinancialEventType,
      amountMinor: fields[4] as int,
      occurredAt: fields[5] as DateTime,
      createdAt: fields[6] as DateTime,
      isBackdated: fields[7] as bool? ?? false,
      sessionId: fields[8] as String?,
      paymentMethod: fields[9] as PaymentMethod?,
      note: fields[10] as String?,
      signatureBase64: fields[11] as String?,
      linkedTransactionId: fields[12] as String?,
      reversesEventId: fields[13] as String?,
      adjustmentSign: fields[14] as int?,
      reason: fields[15] as String?,
      baseLossMinor: fields[16] as int?,
      grantedAsChips: fields[17] as bool?,
    );
  }

  @override
  void write(BinaryWriter writer, FinancialEvent obj) {
    writer
      ..writeByte(18)
      ..writeByte(0)
      ..write(obj.id)
      ..writeByte(1)
      ..write(obj.personId)
      ..writeByte(2)
      ..write(obj.currency)
      ..writeByte(3)
      ..write(obj.type)
      ..writeByte(4)
      ..write(obj.amountMinor)
      ..writeByte(5)
      ..write(obj.occurredAt)
      ..writeByte(6)
      ..write(obj.createdAt)
      ..writeByte(7)
      ..write(obj.isBackdated)
      ..writeByte(8)
      ..write(obj.sessionId)
      ..writeByte(9)
      ..write(obj.paymentMethod)
      ..writeByte(10)
      ..write(obj.note)
      ..writeByte(11)
      ..write(obj.signatureBase64)
      ..writeByte(12)
      ..write(obj.linkedTransactionId)
      ..writeByte(13)
      ..write(obj.reversesEventId)
      ..writeByte(14)
      ..write(obj.adjustmentSign)
      ..writeByte(15)
      ..write(obj.reason)
      ..writeByte(16)
      ..write(obj.baseLossMinor)
      ..writeByte(17)
      ..write(obj.grantedAsChips);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is FinancialEventAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
