import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kasa_setup/kasa/tdp_discovery.dart';
import 'package:kasa_setup/kasa/tdp_packet.dart';

TdpPacket _replyWithJson(Map<String, dynamic> body, {int flagsExtra = 0}) {
  final payload = Uint8List.fromList(utf8.encode(jsonEncode(body)));
  return TdpPacket(
    version: TdpPacket.versionV2,
    opcode: TdpPacket.opcodeV2Discovery,
    flags: TdpFlag.reply | flagsExtra,
    sn: 1,
    payload: payload,
  );
}

void main() {
  final src = InternetAddress('192.168.0.1');

  group('parseTdpReply', () {
    test('parses a typical 1.1.x HS300 unbound TDP reply', () {
      final pkt = _replyWithJson({
        'mac': '78-8C-B5-AF-0A-00',
        'device_id_md5': 'abc123',
        'device_type': 'IOT.SMARTPLUGSWITCH',
        'device_model': 'HS300(US)',
        'owner': '',
        'factory_default': true,
        'http_port': 80,
        'is_support_https': false,
        'is_support_iot_cloud': true,
        'lv': 2,
        'new_klap': 2,
        'ANS': false,
      });
      final dev = TdpDiscovery.parseTdpReply(pkt, src);
      expect(dev, isNotNull);
      expect(dev!.address, src);
      expect(dev.mac, '78-8C-B5-AF-0A-00');
      expect(dev.deviceModel, 'HS300(US)');
      expect(dev.factoryDefault, isTrue);
      expect(dev.klapVersion, 2);
      expect(dev.loginVersion, 2);
      expect(dev.usesKlap, isTrue);
      expect(dev.isUnbound, isTrue);
    });

    test('bound device (non-empty owner) reports isUnbound = false', () {
      final pkt = _replyWithJson({
        'mac': 'aa:bb:cc:dd:ee:ff',
        'owner': 'DEADBEEFDEADBEEFDEADBEEFDEADBEEF',
        'new_klap': 2,
      });
      final dev = TdpDiscovery.parseTdpReply(pkt, src)!;
      expect(dev.isUnbound, isFalse);
    });

    test('device that returns no new_klap reports usesKlap = false', () {
      final pkt = _replyWithJson({'mac': '01:02:03:04:05:06'});
      final dev = TdpDiscovery.parseTdpReply(pkt, src)!;
      expect(dev.usesKlap, isFalse);
      expect(dev.klapVersion, isNull);
    });

    test('explicit new_klap=0 still reports usesKlap = false', () {
      final pkt = _replyWithJson({'mac': 'x', 'new_klap': 0});
      final dev = TdpDiscovery.parseTdpReply(pkt, src)!;
      expect(dev.usesKlap, isFalse);
    });

    test('returns null on empty payload', () {
      final pkt = TdpPacket(
        version: TdpPacket.versionV2,
        opcode: TdpPacket.opcodeV2Discovery,
        flags: TdpFlag.reply,
        sn: 1,
      );
      expect(TdpDiscovery.parseTdpReply(pkt, src), isNull);
    });

    test('returns null on malformed JSON payload', () {
      final pkt = TdpPacket(
        version: TdpPacket.versionV2,
        opcode: TdpPacket.opcodeV2Discovery,
        flags: TdpFlag.reply,
        sn: 1,
        payload: Uint8List.fromList([0xFF, 0xFE, 0xFD]),
      );
      expect(TdpDiscovery.parseTdpReply(pkt, src), isNull);
    });

    test('returns null on non-object JSON payload', () {
      final pkt = TdpPacket(
        version: TdpPacket.versionV2,
        opcode: TdpPacket.opcodeV2Discovery,
        flags: TdpFlag.reply,
        sn: 1,
        payload: Uint8List.fromList(utf8.encode('[1,2,3]')),
      );
      expect(TdpDiscovery.parseTdpReply(pkt, src), isNull);
    });

    test('skips encrypted-payload replies', () {
      final pkt = _replyWithJson({'mac': 'x'}, flagsExtra: TdpFlag.encrypt);
      expect(TdpDiscovery.parseTdpReply(pkt, src), isNull);
    });

    test('parses numeric fields supplied as strings', () {
      final pkt = _replyWithJson({
        'mac': 'x',
        'new_klap': '2',
        'lv': '1',
        'http_port': '80',
      });
      final dev = TdpDiscovery.parseTdpReply(pkt, src)!;
      expect(dev.klapVersion, 2);
      expect(dev.loginVersion, 1);
      expect(dev.httpPort, 80);
    });

    test('preserves the original JSON in `raw` for debugging', () {
      final body = {'mac': 'x', 'extra_field': 'foo'};
      final dev = TdpDiscovery.parseTdpReply(_replyWithJson(body), src)!;
      expect(dev.raw['extra_field'], 'foo');
    });
  });

  group('TdpDiscovery.scan (smoke — no real device)', () {
    test('completes within endWait + slack even with no peers', () async {
      final sw = Stopwatch()..start();
      final devices = await TdpDiscovery.scan(
        broadcastCount: 1,
        interval: const Duration(milliseconds: 50),
        endWait: const Duration(milliseconds: 200),
      ).toList();
      sw.stop();
      expect(devices, isEmpty);
      expect(sw.elapsedMilliseconds, lessThan(2000),
          reason: 'scan should not hang past endWait by much');
    });
  });
}
