import 'dart:typed_data';

/// TP-Link Discovery Protocol (TDP) packet — the binary frame used on
/// UDP port 20002 by KLAP-era Kasa firmware (≥ 1.1.x). Replaces the
/// legacy XOR/9999 broadcast for these devices.
///
/// Wire format (16-byte header + optional payload, all multi-byte fields
/// big-endian):
///
/// ```
///   offset  size  field          notes
///   ------  ----  -------------  -----
///   0       1     version        1 = V1, 2 = V2 (onboarding uses V2)
///   1       1     reserved       always 0
///   2       2     opcode         V1: 2 (TDP_V1_OP_DISCOVERY)
///                                V2: 1 (TDP_V2_OP_DISCOVERY)
///   4       2     payloadLen     bytes after the header
///   6       1     flags          bitfield (see [TdpFlag])
///   7       1     result         0 = default, 1 = OK, -1 (0xFF) = failed
///   8       4     sn             request/response correlation, random
///   12      4     checksum       CRC32 of the whole packet computed with
///                                bytes 12-15 set to the placeholder
///                                [_defaultChecksum] (0x5A6B7C8D)
///   16      …     payload
/// ```
///
/// Reference: jadx of Kasa 3.4.483 at
/// `reverse/kasa-3.4.483-jadx/sources/com/tplinkra/tpcommon/discovery/tdp/`
/// (TDPPacket.java + TDPDefine.java).
class TdpPacket {
  static const int port = 20002;

  static const int versionV1 = 1;
  static const int versionV2 = 2;

  // Opcodes (note the inversion: V1 uses 2, V2 uses 1 — matches the
  // official client exactly).
  static const int opcodeV1Discovery = 2;
  static const int opcodeV2Discovery = 1;

  // Placeholder written at offset 12 *before* CRC32 is computed.
  // Equals `TDPDefine.TDP_CHECKSUM_DEFAULT` = 1516993677.
  static const int _defaultChecksum = 0x5A6B7C8D;

  static const int headerSize = 16;

  final int version;
  final int reserved;
  final int opcode;
  final int flags;
  final int result;
  final int sn;
  final int checksum;
  final Uint8List payload;

  TdpPacket({
    required this.version,
    required this.opcode,
    required this.flags,
    required this.sn,
    this.reserved = 0,
    this.result = 0,
    this.checksum = 0,
    Uint8List? payload,
  }) : payload = payload ?? _empty;

  static final Uint8List _empty = Uint8List(0);

  /// Build the V2 onboarding-discovery broadcast packet — opcode 1, no
  /// payload, flags `BROADCAST | REQUEST` (0x11).
  factory TdpPacket.v2DiscoveryRequest({required int sn}) => TdpPacket(
        version: versionV2,
        opcode: opcodeV2Discovery,
        flags: TdpFlag.broadcast | TdpFlag.request,
        sn: sn,
      );

  /// Serialize into the on-wire form with CRC32 filled in.
  Uint8List encode() {
    final out = Uint8List(headerSize + payload.length);
    final bd = ByteData.view(out.buffer);
    bd.setUint8(0, version & 0xFF);
    bd.setUint8(1, reserved & 0xFF);
    bd.setUint16(2, opcode & 0xFFFF, Endian.big);
    bd.setUint16(4, payload.length & 0xFFFF, Endian.big);
    bd.setUint8(6, flags & 0xFF);
    bd.setUint8(7, result & 0xFF);
    bd.setUint32(8, sn & 0xFFFFFFFF, Endian.big);
    bd.setUint32(12, _defaultChecksum, Endian.big);
    if (payload.isNotEmpty) {
      out.setRange(headerSize, headerSize + payload.length, payload);
    }
    final crc = _crc32(out);
    bd.setUint32(12, crc, Endian.big);
    return out;
  }

  /// Parse an incoming packet. Returns null if the buffer is shorter
  /// than the declared length, the checksum does not validate, or the
  /// header is malformed.
  static TdpPacket? decode(List<int> bytes) {
    if (bytes.length < headerSize) return null;
    final buf = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
    final bd = ByteData.view(buf.buffer, buf.offsetInBytes, buf.length);
    final version = bd.getUint8(0);
    final reserved = bd.getUint8(1);
    final opcode = bd.getUint16(2, Endian.big);
    final payloadLen = bd.getUint16(4, Endian.big);
    final flags = bd.getUint8(6);
    final result = bd.getUint8(7);
    final sn = bd.getUint32(8, Endian.big);
    final declaredChecksum = bd.getUint32(12, Endian.big);
    if (buf.length < headerSize + payloadLen) return null;

    if (!_checksumIsValid(buf, payloadLen, declaredChecksum)) {
      return null;
    }

    final payload = payloadLen == 0
        ? _empty
        : Uint8List.fromList(buf.sublist(headerSize, headerSize + payloadLen));

    return TdpPacket(
      version: version,
      reserved: reserved,
      opcode: opcode,
      flags: flags,
      result: result,
      sn: sn,
      checksum: declaredChecksum,
      payload: payload,
    );
  }

  static bool _checksumIsValid(
      Uint8List buf, int payloadLen, int declaredChecksum) {
    // Recreate the buffer state at the moment fillChecksum() runs in the
    // Java code: the placeholder lives at bytes 12-15, then CRC32 covers
    // everything from offset 0 through 16 + payloadLen.
    final probe = Uint8List(headerSize + payloadLen);
    probe.setRange(0, headerSize + payloadLen, buf);
    final probeBd = ByteData.view(probe.buffer);
    probeBd.setUint32(12, _defaultChecksum, Endian.big);
    return _crc32(probe) == declaredChecksum;
  }

  @override
  String toString() => 'TdpPacket(v=$version op=$opcode flags=0x'
      '${flags.toRadixString(16).padLeft(2, '0')} '
      'result=$result sn=$sn payloadLen=${payload.length})';
}

/// Header flag bitfield values from `TDPDefine.java`. Combine with `|`.
abstract final class TdpFlag {
  static const int none = 0x00;
  static const int request = 0x01;
  static const int reply = 0x02;
  static const int compress = 0x04;
  static const int encrypt = 0x08;
  static const int broadcast = 0x10;
  static const int unicast = 0x20;
  static const int all = 0xFF;
}

// ---------------------------------------------------------------------------
// CRC32 (IEEE 802.3, reflected polynomial 0xEDB88320). Matches
// java.util.zip.CRC32 used by the official client. Table-based for speed.

final List<int> _crc32Table = List<int>.generate(256, (i) {
  var c = i;
  for (var j = 0; j < 8; j++) {
    c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
  }
  return c & 0xFFFFFFFF;
}, growable: false);

int _crc32(List<int> bytes) {
  var crc = 0xFFFFFFFF;
  for (final b in bytes) {
    crc = _crc32Table[(crc ^ b) & 0xFF] ^ (crc >> 8);
  }
  return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}
