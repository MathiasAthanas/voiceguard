import 'package:hive/hive.dart';

import 'call_record_model.dart';
import 'contact_model.dart';

class ContactModelAdapter extends TypeAdapter<ContactModel> {
  @override
  final int typeId = 1;

  @override
  ContactModel read(BinaryReader reader) {
    final fieldCount = reader.readByte();
    final fields = <int, dynamic>{
      for (var i = 0; i < fieldCount; i++) reader.readByte(): reader.read(),
    };

    return ContactModel(
      id: fields[0] as String,
      name: fields[1] as String,
      phoneNumber: fields[2] as String,
      alternatePhoneNumber: fields[6] as String?,
      email: fields[7] as String?,
      notes: fields[8] as String?,
      phoneLabel: fields[9] as String? ?? 'Mobile',
      isFavorite: fields[10] as bool? ?? false,
      isEnrolled: fields[3] as bool? ?? false,
      enrolledAt: fields[4] as DateTime?,
      avatarUrl: fields[5] as String?,
    );
  }

  @override
  void write(BinaryWriter writer, ContactModel obj) {
    writer
      ..writeByte(11)
      ..writeByte(0)
      ..write(obj.id)
      ..writeByte(1)
      ..write(obj.name)
      ..writeByte(2)
      ..write(obj.phoneNumber)
      ..writeByte(3)
      ..write(obj.isEnrolled)
      ..writeByte(4)
      ..write(obj.enrolledAt)
      ..writeByte(5)
      ..write(obj.avatarUrl)
      ..writeByte(6)
      ..write(obj.alternatePhoneNumber)
      ..writeByte(7)
      ..write(obj.email)
      ..writeByte(8)
      ..write(obj.notes)
      ..writeByte(9)
      ..write(obj.phoneLabel)
      ..writeByte(10)
      ..write(obj.isFavorite);
  }
}

class CallTypeAdapter extends TypeAdapter<CallType> {
  @override
  final int typeId = 2;

  @override
  CallType read(BinaryReader reader) => CallType.values[reader.readByte()];

  @override
  void write(BinaryWriter writer, CallType obj) => writer.writeByte(obj.index);
}

class CallDirectionAdapter extends TypeAdapter<CallDirection> {
  @override
  final int typeId = 3;

  @override
  CallDirection read(BinaryReader reader) =>
      CallDirection.values[reader.readByte()];

  @override
  void write(BinaryWriter writer, CallDirection obj) =>
      writer.writeByte(obj.index);
}

class CallRecordModelAdapter extends TypeAdapter<CallRecordModel> {
  @override
  final int typeId = 4;

  @override
  CallRecordModel read(BinaryReader reader) {
    final fieldCount = reader.readByte();
    final fields = <int, dynamic>{
      for (var i = 0; i < fieldCount; i++) reader.readByte(): reader.read(),
    };

    return CallRecordModel(
      id: fields[0] as String,
      contactName: fields[1] as String,
      contactNumber: fields[2] as String,
      callType: fields[3] as CallType,
      direction: fields[4] as CallDirection,
      startTime: fields[5] as DateTime,
      duration: fields[6] != null ? Duration(seconds: fields[6] as int) : null,
      verificationVerdict: fields[7] as String?,
      verificationConfidence: (fields[8] as num?)?.toDouble(),
      similarityScore: (fields[10] as num?)?.toDouble(),
      spoofProbability: (fields[11] as num?)?.toDouble(),
      segmentsAnalyzed: fields[12] as int?,
      verificationMessage: fields[13] as String?,
      spoofDetected: fields[9] as bool?,
    );
  }

  @override
  void write(BinaryWriter writer, CallRecordModel obj) {
    writer
      ..writeByte(14)
      ..writeByte(0)
      ..write(obj.id)
      ..writeByte(1)
      ..write(obj.contactName)
      ..writeByte(2)
      ..write(obj.contactNumber)
      ..writeByte(3)
      ..write(obj.callType)
      ..writeByte(4)
      ..write(obj.direction)
      ..writeByte(5)
      ..write(obj.startTime)
      ..writeByte(6)
      ..write(obj.duration?.inSeconds)
      ..writeByte(7)
      ..write(obj.verificationVerdict)
      ..writeByte(8)
      ..write(obj.verificationConfidence)
      ..writeByte(9)
      ..write(obj.spoofDetected)
      ..writeByte(10)
      ..write(obj.similarityScore)
      ..writeByte(11)
      ..write(obj.spoofProbability)
      ..writeByte(12)
      ..write(obj.segmentsAnalyzed)
      ..writeByte(13)
      ..write(obj.verificationMessage);
  }
}
