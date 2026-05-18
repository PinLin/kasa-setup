// Loaded automatically by `flutter test` once per test invocation.
//
// Loads real fonts from the Flutter SDK so golden tests render actual glyphs
// instead of the default "Ahem" placeholder boxes.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';

Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  await _loadFlutterSdkFonts();
  await testMain();
}

Future<void> _loadFlutterSdkFonts() async {
  final flutterRoot = _resolveFlutterRoot();
  if (flutterRoot == null) return;

  final fontDir = '$flutterRoot/bin/cache/artifacts/material_fonts';
  final candidates = <String, List<String>>{
    'Roboto': [
      '$fontDir/Roboto-Regular.ttf',
      '$fontDir/Roboto-Medium.ttf',
      '$fontDir/Roboto-Light.ttf',
      '$fontDir/Roboto-Bold.ttf',
    ],
    'MaterialIcons': ['$fontDir/MaterialIcons-Regular.otf'],
  };

  for (final entry in candidates.entries) {
    final loader = FontLoader(entry.key);
    var loadedAny = false;
    for (final path in entry.value) {
      final file = File(path);
      if (file.existsSync()) {
        final bytes = await file.readAsBytes();
        loader.addFont(Future.value(ByteData.sublistView(bytes)));
        loadedAny = true;
      }
    }
    if (loadedAny) await loader.load();
  }
}

String? _resolveFlutterRoot() {
  final env = Platform.environment['FLUTTER_ROOT'];
  if (env != null && Directory(env).existsSync()) return env;
  // Try common install locations.
  for (final p in [
    '/opt/homebrew/share/flutter',
    '/usr/local/share/flutter',
    '${Platform.environment['HOME']}/development/flutter',
    '${Platform.environment['HOME']}/flutter',
  ]) {
    if (Directory(p).existsSync()) return p;
  }
  return null;
}
