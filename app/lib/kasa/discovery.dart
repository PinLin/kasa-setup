import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:meta/meta.dart';

import 'protocol.dart';
import 'tdp_discovery.dart';

/// A Kasa device located via local discovery. Some fields are populated
/// only when the device responded to the legacy XOR/9999 broadcast
/// (full `get_sysinfo` reply); others are only populated when the
/// device responded to the TDP/20002 probe (metadata only).
///
/// Use [klap] to decide which transport to send subsequent commands
/// over — it mirrors `DeviceContext.klap` in
/// `TPSmartPlugUtils.getClient()`.
class DiscoveredKasaDevice {
  final InternetAddress address;

  /// Empty string when discovered only via TDP for some firmware
  /// revisions that omit it from the TDP reply.
  final String model;
  final String alias;
  final String hwVersion;
  final String swVersion;

  final String? mac;
  final String? deviceId;

  /// True if discovery saw this device on TDP/20002 with a KLAP
  /// version advertised. Drives transport selection for set_stainfo.
  final bool klap;

  /// KLAP protocol version reported by the device (1, 2, …). Null
  /// for legacy-discovered devices.
  final int? klapVersion;

  /// `owner` field from the TDP reply — MD5(email).upper() of the
  /// TP-Link account this device is currently bound to. Empty
  /// string for unbound (just-factory-reset) devices. Null when not
  /// reported.
  final String? owner;

  /// Reported by 1.1.x firmware in TDP responses to indicate the
  /// device is in factory-default state (i.e. still in AP mode and
  /// has never been provisioned).
  final bool? factoryDefault;

  const DiscoveredKasaDevice({
    required this.address,
    required this.model,
    required this.alias,
    required this.hwVersion,
    required this.swVersion,
    this.mac,
    this.deviceId,
    this.klap = false,
    this.klapVersion,
    this.owner,
    this.factoryDefault,
  });

  bool get isHs300 => model.toUpperCase().contains('HS300');

  /// True when no TP-Link account currently owns this device. Used to
  /// pick the hardcoded `kasa@tp-link.net` / `kasaSetup` fallback
  /// credentials for the KLAP handshake during provisioning.
  bool get isUnbound => owner == null || owner!.isEmpty;
}

/// Combined Kasa device discovery: runs the legacy XOR/9999 broadcast
/// and the newer TDP/20002 broadcast in parallel, merges the result
/// streams, and dedupes by MAC.
///
/// Mirrors `TPCommonDiscoveryAgent.discoverLocal()` at
/// `reverse/kasa-3.4.483-jadx/sources/com/tplinkra/tpcommon/discovery/TPCommonDiscoveryAgent.java:39-50`.
class KasaDiscovery {
  static Stream<DiscoveredKasaDevice> scan({
    Duration timeout = const Duration(seconds: 4),
  }) {
    final controller = StreamController<DiscoveredKasaDevice>();
    final seen = <String>{};

    void emit(DiscoveredKasaDevice device) {
      final key = device.mac?.toLowerCase() ??
          '${device.address.address}:${device.deviceId ?? ''}';
      if (!seen.add(key)) return;
      controller.add(device);
    }

    final legacy = _legacyScan(timeout: timeout).listen(emit);
    final tdp = TdpDiscovery.scan(
      endWait: timeout,
    ).map(tdpToDiscoveredForTest).listen(emit);

    Future.wait([legacy.asFuture<void>(), tdp.asFuture<void>()])
        .whenComplete(() => controller.close());

    return controller.stream;
  }

  static Stream<DiscoveredKasaDevice> _legacyScan({
    required Duration timeout,
  }) async* {
    await for (final reply in KasaTransport.udpBroadcast(
      command: KasaCommand.getSysinfo(),
      timeout: timeout,
    )) {
      final device = parseLegacySysinfo(reply);
      if (device != null) yield device;
    }
  }

  @visibleForTesting
  static DiscoveredKasaDevice? parseLegacySysinfo(KasaUdpReply reply) {
    try {
      final root = jsonDecode(reply.body) as Map<String, dynamic>;
      final sys = root['system'] as Map<String, dynamic>?;
      final info = sys?['get_sysinfo'] as Map<String, dynamic>?;
      if (info == null) return null;

      return DiscoveredKasaDevice(
        address: reply.address,
        model: (info['model'] ?? '').toString(),
        alias: (info['alias'] ?? '').toString(),
        hwVersion: (info['hw_ver'] ?? '').toString(),
        swVersion: (info['sw_ver'] ?? '').toString(),
        mac: info['mac']?.toString() ?? info['mic_mac']?.toString(),
        deviceId: info['deviceId']?.toString(),
        klap: false,
      );
    } catch (_) {
      return null;
    }
  }

  @visibleForTesting
  static DiscoveredKasaDevice tdpToDiscoveredForTest(TdpIoTDevice d) {
    return DiscoveredKasaDevice(
      address: d.address,
      model: d.deviceModel ?? '',
      alias: '',
      hwVersion: '',
      swVersion: '',
      mac: d.mac,
      deviceId: d.deviceIdMd5,
      klap: d.usesKlap,
      klapVersion: d.klapVersion,
      owner: d.owner,
      factoryDefault: d.factoryDefault,
    );
  }
}
