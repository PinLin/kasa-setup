import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:pointycastle/export.dart';

/// KLAP v2 (Kasa MD5 variant) client. Speaks the authenticated local
/// protocol that 1.1.x+ HS300 firmware exposes on HTTP port 80, with
/// the hardcoded `kasa@tp-link.net` / `kasaSetup` fallback for devices
/// that have never been bound to a TP-Link account.
///
/// Reference (decompiled Kasa 3.4.483):
///   - `tpcommon/tpclient/klap/HandShakerClient.java`
///   - `tpcommon/tpclient/klap/TPKLAPClient.java`
///   - `analysis/kasa_3.3.700_klap_handshake.md` in this repo
///
/// We implement the MD5 path (`HandShakerClient.h() == true`), which is
/// what KLAP v2 devices speak. The SHA-1 path is for older Kasa
/// firmware that we don't target.

class KlapClient {
  /// Hardcoded credentials baked into the official Kasa app's
  /// discovery code path. Used for devices whose `owner` field is empty
  /// (i.e. never paired). Source:
  /// `TPDeviceDiscovery.java:94-103` (Kasa 3.4.483).
  static const String fallbackEmail = 'kasa@tp-link.net';
  static const String fallbackPassword = 'kasaSetup';

  /// Compute the KLAP v2 (Kasa MD5 variant) auth hash:
  ///
  ///     auth_hash = MD5( MD5(email) || MD5(password) )    // 16 bytes
  ///
  /// Source: `HandShakerClient.d()` line 95 (MD5 branch, see
  /// `kb0.a.i(...)` calls — the MD5 helper).
  static Uint8List computeAuthHash(String email, String password) {
    final emailMd5 = md5.convert(utf8.encode(email)).bytes;
    final passwordMd5 = md5.convert(utf8.encode(password)).bytes;
    final concat = Uint8List.fromList([...emailMd5, ...passwordMd5]);
    return Uint8List.fromList(md5.convert(concat).bytes);
  }

  /// Derive a [KlapSession] from the three negotiated handshake values.
  /// Mirrors `HandShakerClient.c()`:
  ///
  ///     lsk     = SHA256("lsk" || client_seed || server_seed || auth_hash)[0:16]
  ///     ldk     = SHA256("ldk" || client_seed || server_seed || auth_hash)[0:28]
  ///     iv_full = SHA256("iv"  || client_seed || server_seed || auth_hash)
  ///     ivb     = iv_full[0:16]
  ///     seq0    = int_BE(iv_full[28:32]) & 0x7FFFFFFF
  static KlapSession deriveSession({
    required Uint8List clientSeed,
    required Uint8List serverSeed,
    required Uint8List authHash,
    String cookie = '',
  }) {
    Uint8List sha256OfParts(List<int> prefix) => Uint8List.fromList(
          sha256.convert([...prefix, ...clientSeed, ...serverSeed, ...authHash]).bytes,
        );

    final lsk = sha256OfParts(utf8.encode('lsk')).sublist(0, 16);
    final ldk = sha256OfParts(utf8.encode('ldk')).sublist(0, 28);
    final ivFull = sha256OfParts(utf8.encode('iv'));
    final ivb = ivFull.sublist(0, 16);
    final seq0 = ByteData.sublistView(ivFull, 28, 32).getInt32(0, Endian.big) &
        0x7FFFFFFF;
    return KlapSession(lsk: lsk, ldk: ldk, ivb: ivb, seq: seq0, cookie: cookie);
  }

  /// Verify the server's confirmation byte chunk from /app/handshake1:
  ///
  ///     server_confirm == SHA256(client_seed || auth_hash)
  ///
  /// Source: `HandShakerClient.f()`, line 118-160 — the equality at the
  /// end of the response handler.
  static bool verifyServerConfirm({
    required Uint8List clientSeed,
    required Uint8List authHash,
    required Uint8List serverConfirm,
  }) {
    final expected = sha256.convert([...clientSeed, ...authHash]).bytes;
    return _bytesEqual(expected, serverConfirm);
  }

  /// Compute the client_confirm value sent in /app/handshake2:
  ///
  ///     client_confirm = SHA256(server_seed || auth_hash)    // 32 bytes
  ///
  /// Source: `HandShakerClient.g()`, line 162-183.
  static Uint8List clientConfirm({
    required Uint8List serverSeed,
    required Uint8List authHash,
  }) =>
      Uint8List.fromList(sha256.convert([...serverSeed, ...authHash]).bytes);

  /// Generate a fresh 16-byte random `client_seed`.
  static Uint8List randomClientSeed([Random? rng]) {
    final r = rng ?? Random.secure();
    return Uint8List.fromList(List<int>.generate(16, (_) => r.nextInt(256)));
  }
}

/// Mutable session state. Increment [seq] before each request via
/// [nextSeq].
class KlapSession {
  final Uint8List lsk; // 16 bytes — AES-128-CBC key
  final Uint8List ldk; // 28 bytes — input to the per-request signature
  final Uint8List ivb; // 16 bytes — first half used as IV prefix
  final String cookie;
  int seq;

  KlapSession({
    required this.lsk,
    required this.ldk,
    required this.ivb,
    required this.seq,
    this.cookie = '',
  });

  /// Bump and return the seq counter, used for the next request.
  int nextSeq() {
    seq += 1;
    return seq;
  }

  /// Encrypt a JSON request body. Returns the bytes the official client
  /// would `POST /app/request?seq=<seq>`:
  ///
  ///     seq_bytes  = uint32_BE(seq)                    (4 bytes)
  ///     iv         = ivb[0:12] || seq_bytes            (16 bytes)
  ///     ciphertext = AES-128-CBC(plain, key=lsk, iv=iv, PKCS7)
  ///     signature  = SHA256(ldk || seq_bytes || ciphertext)   (32 bytes)
  ///     body       = signature || ciphertext
  ///
  /// Source: `TPKLAPClient.b()` lines 42-57.
  EncryptedRequest encryptRequest(String plaintextJson, int useSeq) {
    final seqBytes = (ByteData(4)..setUint32(0, useSeq, Endian.big))
        .buffer
        .asUint8List();
    final iv = Uint8List.fromList([...ivb.sublist(0, 12), ...seqBytes]);
    final ciphertext =
        _aesCbcEncrypt(Uint8List.fromList(utf8.encode(plaintextJson)), lsk, iv);
    final signature = Uint8List.fromList(
        sha256.convert([...ldk, ...seqBytes, ...ciphertext]).bytes);
    final body = Uint8List.fromList([...signature, ...ciphertext]);
    return EncryptedRequest(body: body, iv: iv);
  }

  /// Decrypt a /app/request response body. The first 32 bytes are the
  /// server's signature (we do NOT verify it — the official client
  /// doesn't either, per `TPKLAPClient.a()` lines 30-39 which skip
  /// `bArr[0:32]` and only AES-decrypts the tail). The IV is the same
  /// one used for the corresponding request.
  String decryptResponse(Uint8List responseBody, Uint8List iv) {
    if (responseBody.length < 32) {
      throw const FormatException('KLAP response too short for signature');
    }
    final ciphertext = responseBody.sublist(32);
    final plain = _aesCbcDecrypt(ciphertext, lsk, iv);
    return utf8.decode(plain);
  }
}

class EncryptedRequest {
  /// Bytes to POST to `/app/request?seq=<n>`.
  final Uint8List body;

  /// IV used for this request — needed to decrypt the corresponding
  /// response, since the device reuses the same IV.
  final Uint8List iv;

  const EncryptedRequest({required this.body, required this.iv});
}

// ---------------------------------------------------------------------------
// AES-128-CBC + PKCS7 padding via pointycastle.

Uint8List _aesCbcEncrypt(Uint8List plain, Uint8List key, Uint8List iv) {
  final padder = PaddedBlockCipherImpl(PKCS7Padding(), CBCBlockCipher(AESEngine()))
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
  final padder = PaddedBlockCipherImpl(PKCS7Padding(), CBCBlockCipher(AESEngine()))
    ..init(
      false,
      PaddedBlockCipherParameters(
        ParametersWithIV(KeyParameter(key), iv),
        null,
      ),
    );
  return padder.process(cipher);
}

bool _bytesEqual(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}

// ---------------------------------------------------------------------------
// HTTP layer — runs the handshake1 + handshake2 + (optional) request flow
// against a real device. Separated so the math above can be unit-tested
// independently.

class KlapTransport {
  static const Duration defaultTimeout = Duration(seconds: 10);

  /// Run the full handshake1 + handshake2 against `host:80` and return
  /// a ready-to-use [KlapSession]. Throws [KlapException] on any
  /// failure.
  ///
  /// [email] / [password] default to the hardcoded unbound-device
  /// fallback creds. Override only when targeting a bound device whose
  /// owner is the supplied account.
  static Future<KlapSession> handshake({
    required InternetAddress host,
    String email = KlapClient.fallbackEmail,
    String password = KlapClient.fallbackPassword,
    Random? rng,
    Duration timeout = defaultTimeout,
    HttpClient? httpClient,
  }) async {
    final client = httpClient ?? HttpClient();
    client.connectionTimeout = timeout;
    try {
      final authHash = KlapClient.computeAuthHash(email, password);
      final clientSeed = KlapClient.randomClientSeed(rng);

      // ----- handshake1 -----
      final hs1Url = Uri.parse('http://${host.address}/app/handshake1');
      final hs1Req = await client.postUrl(hs1Url).timeout(timeout);
      hs1Req.headers.contentType =
          ContentType('application', 'octet-stream', charset: 'utf-8');
      hs1Req.add(clientSeed);
      final hs1Resp = await hs1Req.close().timeout(timeout);
      if (hs1Resp.statusCode != 200) {
        throw KlapException('handshake1 status ${hs1Resp.statusCode}');
      }
      final hs1Body = await _readAll(hs1Resp);
      if (hs1Body.length < 48) {
        throw KlapException(
            'handshake1 body too short: ${hs1Body.length} bytes (need 48)');
      }
      final serverSeed = hs1Body.sublist(0, 16);
      final serverConfirm = hs1Body.sublist(16, 48);
      if (!KlapClient.verifyServerConfirm(
        clientSeed: clientSeed,
        authHash: authHash,
        serverConfirm: serverConfirm,
      )) {
        throw KlapException(
            'handshake1 server_confirm did not match — wrong credentials or device bound to different owner');
      }
      final cookie = _extractSessionCookie(hs1Resp);

      // ----- handshake2 -----
      final hs2Url = Uri.parse('http://${host.address}/app/handshake2');
      final hs2Req = await client.postUrl(hs2Url).timeout(timeout);
      hs2Req.headers.contentType =
          ContentType('application', 'octet-stream', charset: 'utf-8');
      if (cookie.isNotEmpty) {
        hs2Req.headers.add(HttpHeaders.cookieHeader, cookie);
      }
      hs2Req.add(
        KlapClient.clientConfirm(serverSeed: serverSeed, authHash: authHash),
      );
      final hs2Resp = await hs2Req.close().timeout(timeout);
      if (hs2Resp.statusCode != 200) {
        throw KlapException('handshake2 status ${hs2Resp.statusCode}');
      }
      // Drain body, ignore content.
      await _readAll(hs2Resp);

      return KlapClient.deriveSession(
        clientSeed: clientSeed,
        serverSeed: serverSeed,
        authHash: authHash,
        cookie: cookie,
      );
    } finally {
      if (httpClient == null) client.close();
    }
  }

  /// Send one encrypted JSON command. Increments [session.seq], builds
  /// the encrypted body, POSTs to `/app/request?seq=<n>`, and returns
  /// the decrypted plaintext response.
  static Future<String> sendRequest({
    required InternetAddress host,
    required KlapSession session,
    required String commandJson,
    Duration timeout = defaultTimeout,
    HttpClient? httpClient,
  }) async {
    final client = httpClient ?? HttpClient();
    client.connectionTimeout = timeout;
    try {
      final seq = session.nextSeq();
      final encrypted = session.encryptRequest(commandJson, seq);

      final url = Uri.parse('http://${host.address}/app/request?seq=$seq');
      final req = await client.postUrl(url).timeout(timeout);
      req.headers.contentType =
          ContentType('application', 'octet-stream', charset: 'utf-8');
      if (session.cookie.isNotEmpty) {
        req.headers.add(HttpHeaders.cookieHeader, session.cookie);
      }
      req.add(encrypted.body);
      final resp = await req.close().timeout(timeout);
      if (resp.statusCode != 200) {
        throw KlapException('request status ${resp.statusCode}');
      }
      final body = await _readAll(resp);
      return session.decryptResponse(body, encrypted.iv);
    } finally {
      if (httpClient == null) client.close();
    }
  }

  static String _extractSessionCookie(HttpClientResponse resp) {
    for (final c in resp.cookies) {
      // Device usually sets TP_SESSIONID — but we forward whatever it
      // gives us in raw form.
      return '${c.name}=${c.value}';
    }
    return '';
  }

  static Future<Uint8List> _readAll(HttpClientResponse resp) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in resp) {
      builder.add(chunk);
    }
    return builder.toBytes();
  }
}

class KlapException implements Exception {
  final String message;
  const KlapException(this.message);
  @override
  String toString() => 'KlapException: $message';
}
