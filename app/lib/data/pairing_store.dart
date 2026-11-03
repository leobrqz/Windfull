import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// A credential issued only after the Windows host approves this device.
/// The token and server identity stay in Android's encrypted key store-backed
/// storage and are never written to preferences or logs.
class PairingCredential {
  const PairingCredential({
    required this.serverId,
    required this.host,
    required this.port,
    required this.clientId,
    required this.secret,
    required this.fingerprint,
  });

  final String serverId;
  final String host;
  final int port;
  final String clientId;
  final String secret;
  final String fingerprint;

  Map<String, Object?> toJson() => {
        'serverId': serverId,
        'host': host,
        'port': port,
        'clientId': clientId,
        'secret': secret,
        'fingerprint': fingerprint,
      };

  factory PairingCredential.fromJson(Map<String, dynamic> json) =>
      PairingCredential(
        serverId: json['serverId'] as String,
        host: json['host'] as String,
        port: json['port'] as int,
        clientId: json['clientId'] as String,
        secret: json['secret'] as String,
        fingerprint: json['fingerprint'] as String,
      );
}

class PairingStore {
  PairingStore({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  static const _key = 'windfull.pairing.v1';
  final FlutterSecureStorage _storage;

  Future<PairingCredential?> read() async {
    final value = await _storage.read(key: _key);
    if (value == null) return null;
    try {
      return PairingCredential.fromJson(
        jsonDecode(value) as Map<String, dynamic>,
      );
    } on Object {
      // Corrupt or incompatible credentials must not be treated as paired.
      await clear();
      return null;
    }
  }

  Future<void> save(PairingCredential credential) =>
      _storage.write(key: _key, value: jsonEncode(credential.toJson()));

  Future<void> clear() => _storage.delete(key: _key);
}
