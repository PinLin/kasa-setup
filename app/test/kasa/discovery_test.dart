import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kasa_setup/kasa/discovery.dart';
import 'package:kasa_setup/kasa/protocol.dart';
import 'package:kasa_setup/kasa/tdp_discovery.dart';
import 'package:kasa_setup/kasa/tdp_packet.dart';

void main() {
  group('DiscoveredKasaDevice', () {
    test('isHs300 matches model string case-insensitively', () {
      final d = DiscoveredKasaDevice(
        address: _localhost,
        model: 'hs300(uk)',
        alias: '',
        hwVersion: '',
        swVersion: '',
      );
      expect(d.isHs300, isTrue);
    });

    test('isHs300 is false for other Kasa models', () {
      for (final m in const ['HS200(US)', 'KP303(US)', '', 'LB100(US)']) {
        final d = DiscoveredKasaDevice(
          address: _localhost,
          model: m,
          alias: '',
          hwVersion: '',
          swVersion: '',
        );
        expect(d.isHs300, isFalse, reason: 'model=$m');
      }
    });

    test('isUnbound is true when owner is null or empty', () {
      final a = DiscoveredKasaDevice(
        address: _localhost,
        model: 'HS300(US)',
        alias: '',
        hwVersion: '',
        swVersion: '',
      );
      final b = DiscoveredKasaDevice(
        address: _localhost,
        model: 'HS300(US)',
        alias: '',
        hwVersion: '',
        swVersion: '',
        owner: '',
      );
      expect(a.isUnbound, isTrue);
      expect(b.isUnbound, isTrue);
    });

    test('isUnbound is false when owner is set', () {
      final d = DiscoveredKasaDevice(
        address: _localhost,
        model: 'HS300(US)',
        alias: '',
        hwVersion: '',
        swVersion: '',
        owner: 'DEADBEEFDEADBEEFDEADBEEFDEADBEEF',
      );
      expect(d.isUnbound, isFalse);
    });
  });

  group('KasaDiscovery.parseLegacySysinfo', () {
    KasaUdpReply reply(Map<String, dynamic> sysinfo) => KasaUdpReply(
          _localhost,
          jsonEncode({
            'system': {'get_sysinfo': sysinfo},
          }),
        );

    test('parses a typical HS300 1.0.x reply', () {
      final dev = KasaDiscovery.parseLegacySysinfo(reply({
        'model': 'HS300(US)',
        'alias': 'Living Room',
        'hw_ver': '2.0',
        'sw_ver': '1.0.12 Build 220121 Rel.175814',
        'mac': '78:8C:B5:AF:0A:00',
        'deviceId': 'ABCD',
      }))!;
      expect(dev.model, 'HS300(US)');
      expect(dev.alias, 'Living Room');
      expect(dev.swVersion, contains('1.0.12'));
      expect(dev.mac, '78:8C:B5:AF:0A:00');
      expect(dev.klap, isFalse,
          reason: 'legacy XOR-discovered devices are never KLAP');
    });

    test('falls back to mic_mac when mac is missing', () {
      final dev = KasaDiscovery.parseLegacySysinfo(reply({
        'mic_mac': 'AA:BB:CC:DD:EE:FF',
      }))!;
      expect(dev.mac, 'AA:BB:CC:DD:EE:FF');
    });

    test('returns null when get_sysinfo envelope is missing', () {
      final bogus = KasaUdpReply(_localhost, '{"foo":1}');
      expect(KasaDiscovery.parseLegacySysinfo(bogus), isNull);
    });

    test('returns null on invalid JSON', () {
      final bogus = KasaUdpReply(_localhost, 'not json');
      expect(KasaDiscovery.parseLegacySysinfo(bogus), isNull);
    });
  });

  group('KasaDiscovery._tdpToDiscovered', () {
    test('1.1.x unbound device → klap=true, isUnbound=true', () {
      final tdp = TdpIoTDevice(
        address: _localhost,
        raw: const {},
        mac: '78:8c:b5:af:0a:00',
        deviceModel: 'HS300(US)',
        owner: '',
        klapVersion: 2,
        factoryDefault: true,
      );
      final dev = KasaDiscovery.tdpToDiscoveredForTest(tdp);
      expect(dev.klap, isTrue);
      expect(dev.klapVersion, 2);
      expect(dev.isUnbound, isTrue);
      expect(dev.factoryDefault, isTrue);
      expect(dev.model, 'HS300(US)');
    });

    test('bound 1.1.x device → klap=true, isUnbound=false', () {
      final tdp = TdpIoTDevice(
        address: _localhost,
        raw: const {},
        mac: 'x',
        owner: 'A1B2C3D4',
        klapVersion: 2,
      );
      final dev = KasaDiscovery.tdpToDiscoveredForTest(tdp);
      expect(dev.klap, isTrue);
      expect(dev.isUnbound, isFalse);
    });

    test('TDP-discovered device with klapVersion=0 has klap=false', () {
      // Edge case — device replies on TDP but with no KLAP. Treat as
      // not-KLAP; transport selector falls through to legacy.
      final tdp = TdpIoTDevice(
        address: _localhost,
        raw: const {},
        mac: 'x',
        klapVersion: 0,
      );
      final dev = KasaDiscovery.tdpToDiscoveredForTest(tdp);
      expect(dev.klap, isFalse);
    });
  });
}

final InternetAddress _localhost = InternetAddress.loopbackIPv4;
