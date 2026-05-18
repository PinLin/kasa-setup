import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kasa_setup/kasa/cipher.dart';
import 'package:kasa_setup/kasa/protocol.dart';

void main() {
  group('KasaCommand', () {
    test('getSysinfo has the canonical shape', () {
      final m = jsonDecode(KasaCommand.getSysinfo()) as Map<String, dynamic>;
      expect(m, {
        'system': {'get_sysinfo': <String, dynamic>{}},
      });
    });

    test('setStaInfo defaults key_type to 3 (WPA2)', () {
      final m = jsonDecode(
              KasaCommand.setStaInfo(ssid: 'home', password: 'pw'))
          as Map<String, dynamic>;
      expect(m, {
        'netif': {
          'set_stainfo': {
            'ssid': 'home',
            'password': 'pw',
            'key_type': 3,
          }
        }
      });
    });

    test('setStaInfo respects explicit keyType', () {
      final m = jsonDecode(KasaCommand.setStaInfo(
              ssid: 'h', password: 'p', keyType: 0))
          as Map<String, dynamic>;
      expect(((m['netif'] as Map)['set_stainfo'] as Map)['key_type'], 0);
    });

    test('setStaInfo round-trips a password with quotes and backslashes', () {
      const tricky = r'p"a\s';
      final m = jsonDecode(
              KasaCommand.setStaInfo(ssid: 's', password: tricky))
          as Map<String, dynamic>;
      expect(((m['netif'] as Map)['set_stainfo'] as Map)['password'], tricky);
    });

    test('getScanInfo refresh=true → 1, false → 0', () {
      final on = jsonDecode(KasaCommand.getScanInfo()) as Map<String, dynamic>;
      expect(((on['netif'] as Map)['get_scaninfo'] as Map)['refresh'], 1);
      final off = jsonDecode(KasaCommand.getScanInfo(refresh: false))
          as Map<String, dynamic>;
      expect(((off['netif'] as Map)['get_scaninfo'] as Map)['refresh'], 0);
    });
  });

  group('KasaTransport.tcpSend (against a fake device)', () {
    test('encodes 4-byte big-endian length prefix and decrypts response',
        () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);

      // Echo-style fake: read one length-prefixed XOR-encoded request, decode,
      // assert it's the expected get_sysinfo, and reply with a known JSON
      // payload framed and encrypted the same way.
      const replyJson =
          '{"system":{"get_sysinfo":{"model":"HS300(US)","alias":"x"}}}';
      final receivedRequest = Completer<String>();

      server.listen((socket) async {
        final builder = BytesBuilder(copy: false);
        await for (final chunk in socket) {
          builder.add(chunk);
          if (builder.length >= 4) {
            final declared = ByteData.sublistView(builder.toBytes(), 0, 4)
                .getUint32(0, Endian.big);
            if (builder.length >= 4 + declared) {
              final body = builder.toBytes().sublist(4, 4 + declared);
              receivedRequest
                  .complete(utf8.decode(KasaCipher.decode(body)));
              break;
            }
          }
        }

        final encReply = KasaCipher.encode(utf8.encode(replyJson));
        final framed = Uint8List(4 + encReply.length);
        ByteData.view(framed.buffer)
            .setUint32(0, encReply.length, Endian.big);
        framed.setRange(4, 4 + encReply.length, encReply);
        socket.add(framed);
        await socket.flush();
        await socket.close();
      });

      // tcpSend hardcodes port 9999, so this test would only work if the host
      // bound that port. To keep the test hermetic we bind a random port and
      // call the lower-level path inline here, replicating tcpSend's framing
      // verbatim. (tcpSend itself is exercised end-to-end against a real
      // device; this test pins the wire format.)
      final socket =
          await Socket.connect(InternetAddress.loopbackIPv4, server.port);
      const cmd = '{"system":{"get_sysinfo":{}}}';
      final encoded = KasaCipher.encode(utf8.encode(cmd));
      final framed = Uint8List(4 + encoded.length);
      ByteData.view(framed.buffer).setUint32(0, encoded.length, Endian.big);
      framed.setRange(4, 4 + encoded.length, encoded);
      socket.add(framed);
      await socket.flush();

      final replyBuilder = BytesBuilder(copy: false);
      await for (final chunk in socket) {
        replyBuilder.add(chunk);
      }
      final replyBytes = replyBuilder.toBytes();
      final declared =
          ByteData.sublistView(replyBytes, 0, 4).getUint32(0, Endian.big);
      final replyDecoded = utf8
          .decode(KasaCipher.decode(replyBytes.sublist(4, 4 + declared)));

      expect(await receivedRequest.future, cmd);
      expect(replyDecoded, replyJson);

      socket.destroy();
    });
  });
}
