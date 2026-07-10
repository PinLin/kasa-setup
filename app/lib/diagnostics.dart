/// In-process, non-persisted diagnostic event log for the Kasa provisioning
/// flow. Nothing here ever touches disk — the whole log lives in memory for
/// the lifetime of the app process and disappears when the app is killed.
///
/// Ported from the sister `broadlink-setup` app's `lib/diagnostics.dart`,
/// adapted for Kasa's JSON-command local protocol (legacy XOR/9999 TCP+UDP
/// and KLAP v2 HTTP) instead of Broadlink's fixed-offset binary AP-join
/// packet. See [packetSummary] for the specific adaptation.
///
/// Usage:
/// ```dart
/// Diagnostics.instance.event('join.ap', 'joining device hotspot');
/// Diagnostics.instance.setDeviceInfo({'model': d.model, 'mac': d.mac});
/// final report = Diagnostics.instance.render();
/// ```
///
/// Not a [ChangeNotifier] / no [Stream] — this is a pull-only log. UI that
/// wants to show it (see `lib/diagnostics_view.dart`) re-reads [render] on
/// each open rather than subscribing to updates.
library;

import 'dart:typed_data';

import 'package:crypto/crypto.dart';

enum DiagLevel { info, warn, error }

class DiagEvent {
  final DateTime time;
  final DiagLevel level;
  final String tag;
  final String message;

  const DiagEvent(this.time, this.level, this.tag, this.message);
}

class Diagnostics {
  Diagnostics._();

  static final Diagnostics instance = Diagnostics._();

  /// Unbounded, like the broadlink-setup template — a single provisioning
  /// session generates at most a few dozen events (this flow has fewer
  /// retry loops than broadlink's), so a ring buffer isn't warranted. If a
  /// future flow adds a long-lived polling loop that logs every tick,
  /// revisit this.
  final List<DiagEvent> _events = [];

  Map<String, Object?> _deviceInfo = const {};
  Map<String, Object?> get deviceInfo => _deviceInfo;

  /// Record one diagnostic event. [tag] is a free-form dotted path chosen
  /// by the call site (e.g. `'flow'`, `'join.ap'`, `'provision.send'`,
  /// `'discover.home_wifi'`, `'klap.handshake'`) — see call sites in
  /// `lib/main.dart` and `lib/kasa/klap.dart` for the vocabulary in use.
  void event(String tag, String message, {DiagLevel level = DiagLevel.info}) {
    _events.add(DiagEvent(DateTime.now(), level, tag, message));
  }

  /// Records a redacted summary of a Kasa command payload about to be sent
  /// (or an encrypted KLAP request body), for correlating "what shape of
  /// packet did we send" without ever writing the SSID/password it embeds.
  ///
  /// Broadlink's `packetSummary` reads *fixed byte offsets* out of a binary
  /// AP-join packet to recover `ssidLen`/`passLen`/security type without
  /// decoding the payload. Kasa has no such fixed-offset binary frame at
  /// this layer — `set_stainfo` is a JSON command
  /// (`{"netif":{"set_stainfo":{"ssid":...,"password":...,"key_type":...}}}`)
  /// that gets XOR-encoded (legacy) or AES-encrypted (KLAP) further down
  /// the stack. So instead of parsing offsets, the *caller* passes the
  /// lengths it already knows from the plaintext strings before they were
  /// serialized — the same information broadlink recovers from offsets,
  /// obtained the way that's actually available in this protocol. [payload]
  /// is hashed (never stored) purely so two log entries referring to the
  /// same bytes can be recognized as identical without revealing them.
  void packetSummary(
    String tag,
    Uint8List payload, {
    required int attempt,
    int? ssidLength,
    int? passwordLength,
    int? keyType,
  }) {
    final shortHash = sha256.convert(payload).toString().substring(0, 8);
    final parts = <String>[
      'attempt=$attempt',
      'payloadBytes=${payload.length}',
      if (ssidLength != null) 'ssidLen=$ssidLength',
      if (passwordLength != null) 'passLen=$passwordLength',
      if (keyType != null) 'keyType=$keyType',
      'sha256=$shortHash',
    ];
    event(tag, '${parts.join(' ')} (SSID/password bytes redacted)');
  }

  /// Store a snapshot of non-credential device metadata (model, MAC,
  /// firmware version, IP, …) alongside the event stream. Not itself an
  /// event — shown as a separate block by [render]. Overwrites any
  /// previous value; NOT cleared by [clear] (matches the broadlink
  /// template — a fresh device-info snapshot is normally set again before
  /// the next [render] matters).
  void setDeviceInfo(Map<String, Object?> info) {
    _deviceInfo = Map.unmodifiable(info);
  }

  /// Drop all recorded events (does not clear [deviceInfo]). Called when
  /// the user restarts the provisioning flow, so a report only ever
  /// reflects the most recent attempt.
  void clear() {
    _events.clear();
  }

  /// Render the full in-memory log as plain text suitable for the user to
  /// copy/paste into a bug report.
  String render() {
    final buf = StringBuffer();
    buf.writeln('=== Kasa Setup Diagnostics ===');
    buf.writeln('Generated: ${_fmtTime(DateTime.now())}');
    buf.writeln();
    buf.writeln('--- Device Info ---');
    if (_deviceInfo.isEmpty) {
      buf.writeln('(none)');
    } else {
      for (final entry in _deviceInfo.entries) {
        buf.writeln('${entry.key}: ${entry.value}');
      }
    }
    buf.writeln();
    buf.writeln('--- Events (${_events.length}) ---');
    if (_events.isEmpty) {
      buf.writeln('(none)');
    } else {
      for (final e in _events) {
        final level = e.level.name.padRight(5);
        buf.writeln('${_fmtTime(e.time)} [$level] ${e.tag}: ${e.message}');
      }
    }
    return buf.toString();
  }

  static String _fmtTime(DateTime t) {
    String p2(int n) => n.toString().padLeft(2, '0');
    String p3(int n) => n.toString().padLeft(3, '0');
    return '${t.year}-${p2(t.month)}-${p2(t.day)} '
        '${p2(t.hour)}:${p2(t.minute)}:${p2(t.second)}.${p3(t.millisecond)}';
  }
}
