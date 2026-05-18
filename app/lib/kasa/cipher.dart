import 'dart:typed_data';

/// Kasa "autokey-XOR" obfuscation, seed byte 0xAB.
///
/// Each plaintext byte is XORed with the running key. The key for byte i is
/// the previous *ciphertext* byte; the key for byte 0 is 0xAB.
///
/// This matches `com.tplinkra.tpcommon.tpclient.TPClientUtils.encode()` in
/// the official Kasa Smart Android app and python-kasa.
class KasaCipher {
  static const int _seed = 0xAB;

  static Uint8List encode(List<int> plaintext) {
    final out = Uint8List(plaintext.length);
    var key = _seed;
    for (var i = 0; i < plaintext.length; i++) {
      final c = (key ^ plaintext[i]) & 0xFF;
      out[i] = c;
      key = c;
    }
    return out;
  }

  static Uint8List decode(List<int> ciphertext) {
    final out = Uint8List(ciphertext.length);
    var key = _seed;
    for (var i = 0; i < ciphertext.length; i++) {
      final c = ciphertext[i] & 0xFF;
      out[i] = (key ^ c) & 0xFF;
      key = c;
    }
    return out;
  }
}
