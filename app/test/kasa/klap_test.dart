import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kasa_setup/kasa/klap.dart';
import 'package:pointycastle/export.dart';

void main() {
  group('computeAuthHash', () {
    test('produces exactly 16 bytes', () {
      final h = KlapClient.computeAuthHash('a@b', 'pw');
      expect(h.length, 16);
    });

    test('is deterministic for the same inputs', () {
      final a = KlapClient.computeAuthHash('a@b', 'pw');
      final b = KlapClient.computeAuthHash('a@b', 'pw');
      expect(a, b);
    });

    test('changes when either email or password changes', () {
      final base = KlapClient.computeAuthHash('a@b', 'pw');
      expect(KlapClient.computeAuthHash('a@b', 'pw2'), isNot(base));
      expect(KlapClient.computeAuthHash('a2@b', 'pw'), isNot(base));
    });

    test('matches the documented MD5(MD5(e)||MD5(p)) chain', () {
      const e = 'kasa@tp-link.net';
      const p = 'kasaSetup';
      final expected = md5
          .convert([
            ...md5.convert(utf8.encode(e)).bytes,
            ...md5.convert(utf8.encode(p)).bytes,
          ])
          .bytes;
      expect(KlapClient.computeAuthHash(e, p), expected);
    });
  });

  group('handshake verification helpers', () {
    test('verifyServerConfirm accepts an honest server', () {
      final authHash = KlapClient.computeAuthHash('a@b', 'pw');
      final clientSeed = Uint8List.fromList(List.filled(16, 0x42));
      final serverConfirm = Uint8List.fromList(
        sha256.convert([...clientSeed, ...authHash]).bytes,
      );
      expect(
        KlapClient.verifyServerConfirm(
          clientSeed: clientSeed,
          authHash: authHash,
          serverConfirm: serverConfirm,
        ),
        isTrue,
      );
    });

    test('verifyServerConfirm rejects a tampered confirm', () {
      final authHash = KlapClient.computeAuthHash('a@b', 'pw');
      final clientSeed = Uint8List.fromList(List.filled(16, 0x42));
      final tampered = Uint8List.fromList(
        sha256.convert([...clientSeed, ...authHash]).bytes,
      );
      tampered[0] ^= 0xFF;
      expect(
        KlapClient.verifyServerConfirm(
          clientSeed: clientSeed,
          authHash: authHash,
          serverConfirm: tampered,
        ),
        isFalse,
      );
    });

    test('clientConfirm = SHA256(server_seed || auth_hash), 32 bytes', () {
      final authHash = KlapClient.computeAuthHash('a@b', 'pw');
      final serverSeed = Uint8List.fromList(List.filled(16, 0x99));
      final c = KlapClient.clientConfirm(serverSeed: serverSeed, authHash: authHash);
      expect(c.length, 32);
      expect(c,
          sha256.convert([...serverSeed, ...authHash]).bytes);
    });
  });

  group('deriveSession', () {
    test('produces the expected key sizes', () {
      final s = KlapClient.deriveSession(
        clientSeed: Uint8List.fromList(List.filled(16, 1)),
        serverSeed: Uint8List.fromList(List.filled(16, 2)),
        authHash: Uint8List.fromList(List.filled(16, 3)),
      );
      expect(s.lsk.length, 16);
      expect(s.ldk.length, 28);
      expect(s.ivb.length, 16);
      expect(s.seq, lessThan(1 << 31));
      expect(s.seq, greaterThanOrEqualTo(0));
    });

    test('is deterministic from its inputs', () {
      final a = KlapClient.deriveSession(
        clientSeed: Uint8List.fromList(List.filled(16, 1)),
        serverSeed: Uint8List.fromList(List.filled(16, 2)),
        authHash: Uint8List.fromList(List.filled(16, 3)),
      );
      final b = KlapClient.deriveSession(
        clientSeed: Uint8List.fromList(List.filled(16, 1)),
        serverSeed: Uint8List.fromList(List.filled(16, 2)),
        authHash: Uint8List.fromList(List.filled(16, 3)),
      );
      expect(a.lsk, b.lsk);
      expect(a.ldk, b.ldk);
      expect(a.ivb, b.ivb);
      expect(a.seq, b.seq);
    });

    test('changes when any input changes', () {
      final base = KlapClient.deriveSession(
        clientSeed: Uint8List.fromList(List.filled(16, 1)),
        serverSeed: Uint8List.fromList(List.filled(16, 2)),
        authHash: Uint8List.fromList(List.filled(16, 3)),
      );
      final altSeed = KlapClient.deriveSession(
        clientSeed: Uint8List.fromList(List.filled(16, 9)),
        serverSeed: Uint8List.fromList(List.filled(16, 2)),
        authHash: Uint8List.fromList(List.filled(16, 3)),
      );
      expect(altSeed.lsk, isNot(base.lsk));
    });
  });

  group('encrypt / decrypt round-trip', () {
    test('a JSON command encrypts and decrypts back to the same string', () {
      final session = KlapClient.deriveSession(
        clientSeed: Uint8List.fromList(List.filled(16, 7)),
        serverSeed: Uint8List.fromList(List.filled(16, 8)),
        authHash: Uint8List.fromList(List.filled(16, 9)),
      );
      const plain = '{"system":{"get_sysinfo":{}}}';
      final enc = session.encryptRequest(plain, 100);
      // The decrypter sees: signature(32) || ciphertext. We need to
      // mirror the device's response shape, which is the same:
      // signature(32) || ciphertext. Simulate by reusing the request body.
      final decrypted = session.decryptResponse(enc.body, enc.iv);
      expect(decrypted, plain);
    });

    test('long payload (>1 AES block) round-trips intact', () {
      final session = KlapClient.deriveSession(
        clientSeed: Uint8List.fromList(List.filled(16, 7)),
        serverSeed: Uint8List.fromList(List.filled(16, 8)),
        authHash: Uint8List.fromList(List.filled(16, 9)),
      );
      final long = jsonEncode({
        'netif': {
          'set_stainfo': {
            'ssid': 'home-network-with-a-fairly-long-name',
            'password': 'p@ssw0rd-also-on-the-longer-side-of-things',
            'key_type': 3,
          }
        }
      });
      final enc = session.encryptRequest(long, 7);
      expect(session.decryptResponse(enc.body, enc.iv), long);
    });

    test('seq increment changes the IV and hence the ciphertext', () {
      final session = KlapClient.deriveSession(
        clientSeed: Uint8List.fromList(List.filled(16, 7)),
        serverSeed: Uint8List.fromList(List.filled(16, 8)),
        authHash: Uint8List.fromList(List.filled(16, 9)),
      );
      final a = session.encryptRequest('{"a":1}', 1);
      final b = session.encryptRequest('{"a":1}', 2);
      expect(a.iv, isNot(b.iv));
      expect(a.body, isNot(b.body));
    });

    test('signature in the body matches SHA256(ldk || seq || ciphertext)', () {
      final session = KlapClient.deriveSession(
        clientSeed: Uint8List.fromList(List.filled(16, 7)),
        serverSeed: Uint8List.fromList(List.filled(16, 8)),
        authHash: Uint8List.fromList(List.filled(16, 9)),
      );
      final enc = session.encryptRequest('{"x":1}', 42);
      final seqBytes = (ByteData(4)..setUint32(0, 42, Endian.big))
          .buffer
          .asUint8List();
      final ciphertext = enc.body.sublist(32);
      final expectedSig =
          sha256.convert([...session.ldk, ...seqBytes, ...ciphertext]).bytes;
      expect(enc.body.sublist(0, 32), expectedSig);
    });
  });

  group('KlapSession.nextSeq', () {
    test('increments and returns the new value', () {
      final s = KlapSession(
        lsk: Uint8List(16),
        ldk: Uint8List(28),
        ivb: Uint8List(16),
        seq: 5,
      );
      expect(s.nextSeq(), 6);
      expect(s.nextSeq(), 7);
      expect(s.seq, 7);
    });
  });

  group('hardcoded fallback creds match the official app', () {
    test('email is kasa@tp-link.net', () {
      expect(KlapClient.fallbackEmail, 'kasa@tp-link.net');
    });
    test('password is kasaSetup (camelCase, mixed-case S)', () {
      expect(KlapClient.fallbackPassword, 'kasaSetup');
    });
  });

  group('KlapTransport (against a loopback fake device)', () {
    test('full handshake completes and request round-trips', () async {
      final fake = await _FakeKlapServer.start();
      addTearDown(fake.close);

      // Force a known client seed so the test is deterministic.
      final knownSeed = Uint8List.fromList(List.filled(16, 0x11));
      final session = await KlapTransport.handshake(
        host: InternetAddress.loopbackIPv4,
        rng: _FixedRandom(knownSeed),
        httpClient: _httpClientForPort(fake.port),
      );
      expect(session.lsk.length, 16);
      expect(session.cookie, contains('TP_SESSIONID='));

      final reply = await KlapTransport.sendRequest(
        host: InternetAddress.loopbackIPv4,
        session: session,
        commandJson: '{"system":{"get_sysinfo":{}}}',
        httpClient: _httpClientForPort(fake.port),
      );
      expect(jsonDecode(reply), {'echo': '{"system":{"get_sysinfo":{}}}'});
    });

    test('handshake throws when the server gives a wrong confirm', () async {
      final fake = await _FakeKlapServer.start(corruptConfirm: true);
      addTearDown(fake.close);

      expect(
        KlapTransport.handshake(
          host: InternetAddress.loopbackIPv4,
          httpClient: _httpClientForPort(fake.port),
        ),
        throwsA(isA<KlapException>()),
      );
    });
  });
}

// ---------------------------------------------------------------------------
// Test helpers

HttpClient _httpClientForPort(int port) {
  // Force HttpClient to talk to our loopback fake regardless of the URL
  // host portion (which is the device's IP in production).
  return HttpClient()
    ..findProxy = (_) => 'PROXY 127.0.0.1:$port';
}

class _FixedRandom implements Random {
  final Uint8List bytes;
  int _i = 0;
  _FixedRandom(this.bytes);

  @override
  int nextInt(int max) {
    final v = bytes[_i % bytes.length];
    _i++;
    return v % max;
  }

  @override
  bool nextBool() => nextInt(2) == 1;

  @override
  double nextDouble() => nextInt(1 << 32) / (1 << 32);
}

/// Minimal in-process KLAP server. Implements the math correctly so the
/// real client code can talk to it end-to-end without touching the
/// network.
class _FakeKlapServer {
  final HttpServer _server;
  final bool corruptConfirm;
  Uint8List? _serverSeed;
  Uint8List? _authHash;
  KlapSession? _session;

  _FakeKlapServer(this._server, this.corruptConfirm);

  int get port => _server.port;

  static Future<_FakeKlapServer> start({bool corruptConfirm = false}) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final fake = _FakeKlapServer(server, corruptConfirm);
    server.listen(fake._handle);
    return fake;
  }

  Future<void> close() => _server.close(force: true);

  Future<void> _handle(HttpRequest req) async {
    final body = await _readAll(req);
    switch (req.uri.path) {
      case '/app/handshake1':
        await _hs1(req, body);
        break;
      case '/app/handshake2':
        await _hs2(req, body);
        break;
      default:
        if (req.uri.path == '/app/request') {
          await _request(req, body);
        } else {
          req.response.statusCode = 404;
          await req.response.close();
        }
    }
  }

  Future<void> _hs1(HttpRequest req, Uint8List clientSeed) async {
    // We bake in known credentials so the test's session derivation
    // matches ours.
    _authHash = KlapClient.computeAuthHash(
        KlapClient.fallbackEmail, KlapClient.fallbackPassword);
    _serverSeed = Uint8List.fromList(List.filled(16, 0x22));
    final serverConfirm = Uint8List.fromList(
        sha256.convert([...clientSeed, ..._authHash!]).bytes);
    if (corruptConfirm) serverConfirm[0] ^= 0xFF;
    _session = KlapClient.deriveSession(
      clientSeed: clientSeed,
      serverSeed: _serverSeed!,
      authHash: _authHash!,
    );
    req.response.headers.set(
      HttpHeaders.setCookieHeader,
      'TP_SESSIONID=fake-cookie-123; Path=/',
    );
    req.response.add([..._serverSeed!, ...serverConfirm]);
    await req.response.close();
  }

  Future<void> _hs2(HttpRequest req, Uint8List clientConfirm) async {
    final expected = KlapClient.clientConfirm(
        serverSeed: _serverSeed!, authHash: _authHash!);
    if (!_eq(clientConfirm, expected)) {
      req.response.statusCode = 403;
      await req.response.close();
      return;
    }
    req.response.statusCode = 200;
    await req.response.close();
  }

  Future<void> _request(HttpRequest req, Uint8List body) async {
    final seq = int.parse(req.uri.queryParameters['seq']!);
    final s = _session!;
    final seqBytes = (ByteData(4)..setUint32(0, seq, Endian.big))
        .buffer
        .asUint8List();
    final iv = Uint8List.fromList([...s.ivb.sublist(0, 12), ...seqBytes]);
    final ciphertext = body.sublist(32);
    final plaintext = _aesCbcDecrypt(ciphertext, s.lsk, iv);
    final plainStr = utf8.decode(plaintext);
    final replyJson = jsonEncode({'echo': plainStr});
    final replyCipher =
        _aesCbcEncrypt(Uint8List.fromList(utf8.encode(replyJson)), s.lsk, iv);
    final replySig = Uint8List.fromList(
        sha256.convert([...s.ldk, ...seqBytes, ...replyCipher]).bytes);
    req.response.add([...replySig, ...replyCipher]);
    await req.response.close();
  }
}

Future<Uint8List> _readAll(HttpRequest req) async {
  final builder = BytesBuilder(copy: false);
  await for (final chunk in req) {
    builder.add(chunk);
  }
  return builder.toBytes();
}

bool _eq(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

Uint8List _aesCbcEncrypt(Uint8List plain, Uint8List key, Uint8List iv) {
  final padder =
      PaddedBlockCipherImpl(PKCS7Padding(), CBCBlockCipher(AESEngine()))
        ..init(
          true,
          PaddedBlockCipherParameters(
            ParametersWithIV(KeyParameter(key), iv),
            null,
          ),
        );
  return padder.process(plain);
}

Uint8List _aesCbcDecrypt(Uint8List cipher, Uint8List key, Uint8List iv) {
  final padder =
      PaddedBlockCipherImpl(PKCS7Padding(), CBCBlockCipher(AESEngine()))
        ..init(
          false,
          PaddedBlockCipherParameters(
            ParametersWithIV(KeyParameter(key), iv),
            null,
          ),
        );
  return padder.process(cipher);
}
