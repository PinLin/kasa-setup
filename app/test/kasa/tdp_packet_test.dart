import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kasa_setup/kasa/tdp_packet.dart';

void main() {
  group('TdpPacket.encode', () {
    test('V2 discovery request is exactly 16 bytes (no payload)', () {
      final pkt = TdpPacket.v2DiscoveryRequest(sn: 0);
      final bytes = pkt.encode();
      expect(bytes.length, 16);
    });

    test('V2 discovery request has the expected header layout', () {
      final pkt = TdpPacket.v2DiscoveryRequest(sn: 0x12345678);
      final bytes = pkt.encode();
      final bd = ByteData.view(bytes.buffer);
      expect(bytes[0], 2, reason: 'version');
      expect(bytes[1], 0, reason: 'reserved');
      expect(bd.getUint16(2, Endian.big), 1, reason: 'opcode (V2 = 1)');
      expect(bd.getUint16(4, Endian.big), 0, reason: 'payloadLen');
      expect(bytes[6], 0x11, reason: 'flags = BROADCAST | REQUEST');
      expect(bytes[7], 0, reason: 'result');
      expect(bd.getUint32(8, Endian.big), 0x12345678, reason: 'sn');
      // checksum at offset 12 must NOT still be the placeholder
      expect(bd.getUint32(12, Endian.big), isNot(0x5A6B7C8D),
          reason: 'checksum should be CRC32, not placeholder');
    });

    test('checksum is deterministic across runs', () {
      final a = TdpPacket.v2DiscoveryRequest(sn: 42).encode();
      final b = TdpPacket.v2DiscoveryRequest(sn: 42).encode();
      expect(a, b);
    });

    test('different sn produces different checksum', () {
      final a = ByteData.view(TdpPacket.v2DiscoveryRequest(sn: 1).encode().buffer)
          .getUint32(12, Endian.big);
      final b = ByteData.view(TdpPacket.v2DiscoveryRequest(sn: 2).encode().buffer)
          .getUint32(12, Endian.big);
      expect(a, isNot(b));
    });

    test('payload is appended after the 16-byte header', () {
      final payload = Uint8List.fromList(utf8Bytes('{"x":1}'));
      final pkt = TdpPacket(
        version: TdpPacket.versionV2,
        opcode: TdpPacket.opcodeV2Discovery,
        flags: TdpFlag.reply,
        sn: 7,
        payload: payload,
      );
      final bytes = pkt.encode();
      expect(bytes.length, 16 + payload.length);
      expect(bytes.sublist(16), payload);
      final bd = ByteData.view(bytes.buffer);
      expect(bd.getUint16(4, Endian.big), payload.length,
          reason: 'payloadLen in header');
    });
  });

  group('TdpPacket.decode', () {
    test('round-trip preserves all fields (no payload)', () {
      final src = TdpPacket(
        version: TdpPacket.versionV2,
        opcode: TdpPacket.opcodeV2Discovery,
        flags: TdpFlag.broadcast | TdpFlag.request,
        sn: 0xDEADBEEF,
      );
      final encoded = src.encode();
      final decoded = TdpPacket.decode(encoded)!;
      expect(decoded.version, src.version);
      expect(decoded.opcode, src.opcode);
      expect(decoded.flags, src.flags);
      expect(decoded.sn, src.sn);
      expect(decoded.payload, isEmpty);
    });

    test('round-trip preserves payload bytes', () {
      final payload = Uint8List.fromList([1, 2, 3, 4, 5, 0xFF, 0]);
      final src = TdpPacket(
        version: TdpPacket.versionV2,
        opcode: TdpPacket.opcodeV2Discovery,
        flags: TdpFlag.reply,
        sn: 99,
        payload: payload,
      );
      final decoded = TdpPacket.decode(src.encode())!;
      expect(decoded.payload, payload);
    });

    test('returns null for buffer shorter than 16-byte header', () {
      expect(TdpPacket.decode(List.filled(15, 0)), isNull);
      expect(TdpPacket.decode([]), isNull);
    });

    test('returns null when declared payloadLen exceeds buffer', () {
      final src = TdpPacket(
        version: TdpPacket.versionV2,
        opcode: TdpPacket.opcodeV2Discovery,
        flags: TdpFlag.reply,
        sn: 1,
        payload: Uint8List.fromList([0xAA, 0xBB]),
      );
      final encoded = src.encode();
      // Truncate to 17 bytes — header says payloadLen=2 but we only have 1.
      final truncated = encoded.sublist(0, 17);
      expect(TdpPacket.decode(truncated), isNull);
    });

    test('returns null on tampered byte (checksum mismatch)', () {
      final encoded = TdpPacket.v2DiscoveryRequest(sn: 11).encode();
      // Flip a bit in the sn — checksum no longer matches.
      final tampered = Uint8List.fromList(encoded);
      tampered[8] ^= 0x01;
      expect(TdpPacket.decode(tampered), isNull);
    });

    test('returns null when stored checksum is wrong', () {
      final encoded = TdpPacket.v2DiscoveryRequest(sn: 11).encode();
      final tampered = Uint8List.fromList(encoded);
      tampered[12] ^= 0xFF;
      expect(TdpPacket.decode(tampered), isNull);
    });
  });

  group('TdpFlag constants match TDPDefine.java', () {
    test('numeric values', () {
      expect(TdpFlag.none, 0x00);
      expect(TdpFlag.request, 0x01);
      expect(TdpFlag.reply, 0x02);
      expect(TdpFlag.compress, 0x04);
      expect(TdpFlag.encrypt, 0x08);
      expect(TdpFlag.broadcast, 0x10);
      expect(TdpFlag.unicast, 0x20);
    });

    test('opcode constants — V1=2, V2=1 (note the inversion)', () {
      expect(TdpPacket.opcodeV1Discovery, 2);
      expect(TdpPacket.opcodeV2Discovery, 1);
    });
  });
}

List<int> utf8Bytes(String s) => s.codeUnits;
