import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:meta/meta.dart';

import 'tdp_packet.dart';

/// Result of one TDP discovery reply — the fields the official app
/// expects (matches the `@SerializedName` annotations on
/// `com.tplink.libtdp.bean.TDPIoTDevice` in
/// `reverse/kasa-3.4.483-jadx/sources/com/tplink/libtdp/bean/TDPIoTDevice.java`).
///
/// Not every field is populated by every firmware. The ones we care
/// about for transport-selection are [klapVersion], [owner], and
/// [factoryDefault].
class TdpIoTDevice {
  final InternetAddress address;
  final String? mac;
  final String? deviceIdMd5;
  final String? deviceType;
  final String? deviceModel;
  final String? owner;
  final bool? factoryDefault;
  final bool? isSupportHttps;
  final int? httpPort;
  final bool? isSupportIoTCloud;
  final String? obdSrc;
  final int? loginVersion;
  final int? klapVersion;
  final bool? ans;

  /// Anything in the response we didn't pull out as a named field.
  /// Kept so callers can debug-print the raw response.
  final Map<String, dynamic> raw;

  const TdpIoTDevice({
    required this.address,
    required this.raw,
    this.mac,
    this.deviceIdMd5,
    this.deviceType,
    this.deviceModel,
    this.owner,
    this.factoryDefault,
    this.isSupportHttps,
    this.httpPort,
    this.isSupportIoTCloud,
    this.obdSrc,
    this.loginVersion,
    this.klapVersion,
    this.ans,
  });

  /// True if this device speaks KLAP — i.e. responded with a non-null,
  /// non-zero `new_klap` field. Equivalent to `deviceContext.klap` in
  /// `TPSmartPlugUtils.getClient()` line 117-120.
  bool get usesKlap => klapVersion != null && klapVersion! > 0;

  /// True if no TP-Link account currently owns this device (empty
  /// `owner` field). When this is true the official app falls back to
  /// the hardcoded `kasa@tp-link.net` / `kasaSetup` credentials for
  /// the KLAP handshake — preserving the "no-login" property.
  bool get isUnbound => owner == null || owner!.isEmpty;
}

/// Discover Kasa devices on the local network by broadcasting a TDP V2
/// discovery request to `255.255.255.255:20002` and collecting replies.
///
/// This is the **newer** discovery path used by KLAP-era firmware
/// (≥ 1.1.x). Legacy (1.0.x) firmware does NOT respond on UDP/20002;
/// callers should run this in parallel with the legacy XOR/9999
/// broadcast (see `KasaDiscovery.scan`).
class TdpDiscovery {
  /// Mirrors `TPDeviceDiscovery.tdpBroadcastDiscovery` onboarding-mode
  /// params at line 298 of the decompiled file: 2 broadcasts, 300 ms
  /// apart, then wait up to 1800 ms for late replies.
  static Stream<TdpIoTDevice> scan({
    Duration interval = const Duration(milliseconds: 300),
    int broadcastCount = 2,
    Duration endWait = const Duration(milliseconds: 1800),
  }) async* {
    final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0,
        reuseAddress: true);
    socket.broadcastEnabled = true;

    final controller = StreamController<TdpIoTDevice>();
    final seenMacs = <String>{};
    final sn = Random().nextInt(1 << 28);

    void onPacket(RawSocketEvent event) {
      if (event != RawSocketEvent.read) return;
      final dgram = socket.receive();
      if (dgram == null) return;
      final packet = TdpPacket.decode(dgram.data);
      if (packet == null) return;
      if ((packet.flags & TdpFlag.reply) == 0) return;
      final device = parseTdpReply(packet, dgram.address);
      if (device == null) return;
      final key = device.mac ?? '${device.address.address}-${device.deviceIdMd5}';
      if (!seenMacs.add(key)) return;
      controller.add(device);
    }

    final sub = socket.listen(onPacket);

    // Broadcast `broadcastCount` times with `interval` between sends.
    for (var i = 0; i < broadcastCount; i++) {
      final pkt = TdpPacket.v2DiscoveryRequest(sn: sn).encode();
      socket.send(pkt, InternetAddress('255.255.255.255'), TdpPacket.port);
      if (i + 1 < broadcastCount) {
        await Future<void>.delayed(interval);
      }
    }

    Timer(endWait, () {
      sub.cancel();
      socket.close();
      controller.close();
    });

    yield* controller.stream;
  }

  @visibleForTesting
  static TdpIoTDevice? parseTdpReply(TdpPacket packet, InternetAddress src) {
    if ((packet.flags & TdpFlag.encrypt) != 0) {
      // Encrypted-payload TDP responses use a session key we haven't
      // negotiated. Skip — never seen from a factory-default device.
      return null;
    }
    if (packet.payload.isEmpty) return null;
    final Map<String, dynamic> json;
    try {
      final text = utf8.decode(packet.payload, allowMalformed: false);
      final decoded = jsonDecode(text);
      if (decoded is! Map<String, dynamic>) return null;
      json = decoded;
    } catch (_) {
      return null;
    }
    return TdpIoTDevice(
      address: src,
      raw: json,
      mac: _str(json['mac']),
      deviceIdMd5: _str(json['device_id_md5']),
      deviceType: _str(json['device_type']),
      deviceModel: _str(json['device_model']),
      owner: _str(json['owner']),
      factoryDefault: _bool(json['factory_default']),
      isSupportHttps: _bool(json['is_support_https']),
      httpPort: _int(json['http_port']),
      isSupportIoTCloud: _bool(json['is_support_iot_cloud']),
      obdSrc: _str(json['obd_src']),
      loginVersion: _int(json['lv']),
      klapVersion: _int(json['new_klap']),
      ans: _bool(json['ANS']),
    );
  }
}

String? _str(Object? v) => v == null ? null : v.toString();
int? _int(Object? v) {
  if (v == null) return null;
  if (v is int) return v;
  if (v is num) return v.toInt();
  return int.tryParse(v.toString());
}

bool? _bool(Object? v) {
  if (v == null) return null;
  if (v is bool) return v;
  if (v is num) return v != 0;
  return v.toString().toLowerCase() == 'true';
}
