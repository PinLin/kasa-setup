import 'package:flutter_test/flutter_test.dart';
import 'package:kasa_setup/kasa/cipher.dart';

void main() {
  group('KasaCipher.encode', () {
    test('empty input produces empty output', () {
      expect(KasaCipher.encode(const []), isEmpty);
    });

    test('single byte XORs with seed 0xAB', () {
      // 'a' = 0x61, 0xAB ^ 0x61 = 0xCA
      expect(KasaCipher.encode('a'.codeUnits), [0xCA]);
    });

    test('autokey chain advances on each byte', () {
      // "{}" = [0x7B, 0x7D]
      // c0 = 0xAB ^ 0x7B = 0xD0
      // c1 = 0xD0 ^ 0x7D = 0xAD
      expect(KasaCipher.encode('{}'.codeUnits), [0xD0, 0xAD]);
    });

    test('three-byte fixture "a" with quotes', () {
      // 0x22 0x61 0x22
      // c0 = 0xAB ^ 0x22 = 0x89
      // c1 = 0x89 ^ 0x61 = 0xE8
      // c2 = 0xE8 ^ 0x22 = 0xCA
      expect(KasaCipher.encode('"a"'.codeUnits), [0x89, 0xE8, 0xCA]);
    });
  });

  group('KasaCipher.decode', () {
    test('empty input produces empty output', () {
      expect(KasaCipher.decode(const []), isEmpty);
    });

    test('inverse of encode for single byte', () {
      expect(KasaCipher.decode([0xCA]), 'a'.codeUnits);
    });

    test('inverse of encode for "{}"', () {
      expect(KasaCipher.decode([0xD0, 0xAD]), '{}'.codeUnits);
    });
  });

  group('round-trip', () {
    void roundTrip(String label, List<int> input) {
      test(label, () {
        final encoded = KasaCipher.encode(input);
        final decoded = KasaCipher.decode(encoded);
        expect(decoded, input);
      });
    }

    roundTrip('ASCII JSON', '{"system":{"get_sysinfo":{}}}'.codeUnits);
    roundTrip(
      'set_stainfo command',
      '{"netif":{"set_stainfo":{"ssid":"home","password":"pw","key_type":3}}}'
          .codeUnits,
    );
    roundTrip('all 0x00', List.filled(64, 0x00));
    roundTrip('all 0xFF', List.filled(64, 0xFF));
    roundTrip('256-byte counter', List.generate(256, (i) => i));
  });

  test('encode is deterministic across runs', () {
    final input = '{"a":1}'.codeUnits;
    expect(KasaCipher.encode(input), KasaCipher.encode(input));
  });

  test('encode masks values to 8 bits', () {
    // If a caller passes ints > 255 we should still get bytes back.
    final out = KasaCipher.encode([0x161, 0x100]);
    for (final b in out) {
      expect(b, lessThanOrEqualTo(0xFF));
      expect(b, greaterThanOrEqualTo(0));
    }
  });
}
