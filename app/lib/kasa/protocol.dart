import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'cipher.dart';
import 'discovery.dart';
import 'klap.dart';

/// Kasa local protocol on TCP/UDP port 9999.
///
/// TCP frames are length-prefixed (4 bytes big-endian) and 0xAB-XOR encoded.
/// UDP datagrams are 0xAB-XOR encoded with no length prefix.
class KasaTransport {
  static const int port = 9999;

  /// Send one length-prefixed XOR-encoded JSON command over TCP and read one
  /// length-prefixed XOR-encoded response. Returns the decoded JSON-ish string.
  static Future<String> tcpSend({
    required InternetAddress host,
    required String command,
    Duration timeout = const Duration(seconds: 8),
  }) async {
    final encoded = KasaCipher.encode(utf8.encode(command));
    final framed = _withLengthPrefix(encoded);

    final socket = await Socket.connect(host, port, timeout: timeout);
    try {
      socket.add(framed);
      await socket.flush();
      final raw = await _readAll(socket).timeout(timeout);
      return _parseFramedResponse(raw);
    } finally {
      socket.destroy();
    }
  }

  /// Send one XOR-encoded JSON datagram to [host] and wait up to [timeout]
  /// for a reply from that same host. Returns the decoded body, or null on
  /// timeout (caller decides whether silence == success, e.g. for set_stainfo
  /// the device tears down its AP before replying so silence is expected).
  static Future<String?> udpUnicastSend({
    required InternetAddress host,
    required String command,
    Duration timeout = const Duration(seconds: 3),
  }) async {
    final encoded = KasaCipher.encode(utf8.encode(command));
    final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    try {
      final completer = Completer<String?>();
      final sub = socket.listen((event) {
        if (event != RawSocketEvent.read) return;
        final d = socket.receive();
        if (d == null) return;
        // Accept replies from the unicast target only — ignore stray broadcasts
        // from other Kasa devices that happen to be on the same segment.
        if (d.address.address != host.address) return;
        try {
          final body = utf8.decode(KasaCipher.decode(d.data));
          if (!completer.isCompleted) completer.complete(body);
        } catch (_) {/* malformed — ignore */}
      });
      socket.send(encoded, host, port);
      final res =
          await completer.future.timeout(timeout, onTimeout: () => null);
      await sub.cancel();
      return res;
    } finally {
      socket.close();
    }
  }

  /// Send one XOR-encoded JSON datagram and listen up to [timeout] for replies
  /// from any peer. Yields each reply as the peer's address + decoded string.
  static Stream<KasaUdpReply> udpBroadcast({
    required String command,
    Duration timeout = const Duration(seconds: 4),
  }) async* {
    final encoded = KasaCipher.encode(utf8.encode(command));
    final socket =
        await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0, reuseAddress: true);
    socket.broadcastEnabled = true;

    socket.send(encoded, InternetAddress('255.255.255.255'), port);

    final controller = StreamController<KasaUdpReply>();
    final sub = socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      final dgram = socket.receive();
      if (dgram == null) return;
      try {
        final body = utf8.decode(KasaCipher.decode(dgram.data));
        controller.add(KasaUdpReply(dgram.address, body));
      } catch (_) {
        // ignore garbled
      }
    });

    Timer(timeout, () {
      sub.cancel();
      socket.close();
      controller.close();
    });

    yield* controller.stream;
  }

  // ---- helpers --------------------------------------------------------------

  static Uint8List _withLengthPrefix(Uint8List body) {
    final out = Uint8List(4 + body.length);
    final bd = ByteData.view(out.buffer);
    bd.setUint32(0, body.length, Endian.big);
    out.setRange(4, 4 + body.length, body);
    return out;
  }

  static Future<Uint8List> _readAll(Socket socket) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in socket) {
      builder.add(chunk);
      // Stop early once we have a complete length-prefixed frame.
      if (builder.length >= 4) {
        final view = ByteData.sublistView(builder.toBytes(), 0, 4);
        final declared = view.getUint32(0, Endian.big);
        if (builder.length >= 4 + declared) break;
      }
    }
    return builder.toBytes();
  }

  static String _parseFramedResponse(Uint8List raw) {
    if (raw.length < 4) {
      throw StateError('short response (${raw.length}B)');
    }
    final view = ByteData.sublistView(raw, 0, 4);
    final declared = view.getUint32(0, Endian.big);
    final end = (4 + declared).clamp(0, raw.length);
    final body = raw.sublist(4, end);
    return utf8.decode(KasaCipher.decode(body));
  }
}

class KasaUdpReply {
  final InternetAddress address;
  final String body;
  const KasaUdpReply(this.address, this.body);
}

/// High-level dispatcher: pick the right transport for a discovered
/// device. Mirrors `TPSmartPlugUtils.getClient()` in the official app:
/// when the device's `klap` flag is set we go through KLAP HTTP/80
/// with the hardcoded fallback credentials (assuming the device is
/// unbound); otherwise we use the legacy XOR/9999 TCP path.
///
/// For KLAP devices we open a fresh handshake per call. The app's use
/// case is a single `set_stainfo` send during provisioning, so we
/// avoid the complexity of session caching that `KLAPSessionManager`
/// adds in the official client.
abstract class Kasa {
  static Future<String> send({
    required DiscoveredKasaDevice device,
    required String command,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    if (device.klap) {
      if (!device.isUnbound) {
        throw KlapException(
          'Device is bound to a TP-Link account (owner=${device.owner}). '
          'Local control would require that account\'s credentials, which '
          'we do not collect. Factory-reset the device to clear the owner.',
        );
      }
      final session = await KlapTransport.handshake(
        host: device.address,
        timeout: timeout,
      );
      return KlapTransport.sendRequest(
        host: device.address,
        session: session,
        commandJson: command,
        timeout: timeout,
      );
    }
    return KasaTransport.tcpSend(
      host: device.address,
      command: command,
      timeout: timeout,
    );
  }
}

/// Builders for the JSON commands we actually need.
///
/// These are built as plain `Map`s and serialized with `jsonEncode` so the
/// runtime doesn't depend on any TP-Link SDK.
abstract class KasaCommand {
  static String getSysinfo() =>
      jsonEncode({'system': {'get_sysinfo': {}}});

  /// Tell the device to join the given home Wi-Fi.
  ///
  /// [keyType]: 0=open, 1=WEP, 2=WPA, 3=WPA2 (the only one anyone uses).
  static String setStaInfo({
    required String ssid,
    required String password,
    int keyType = 3,
  }) =>
      jsonEncode({
        'netif': {
          'set_stainfo': {
            'ssid': ssid,
            'password': password,
            'key_type': keyType,
          }
        }
      });

  /// Ask the device to scan and report APs visible from its position.
  /// Useful before set_stainfo when the user isn't sure their home AP
  /// is on 2.4 GHz / within range of the strip.
  static String getScanInfo({bool refresh = true}) =>
      jsonEncode({
        'netif': {
          'get_scaninfo': {'refresh': refresh ? 1 : 0}
        }
      });
}
