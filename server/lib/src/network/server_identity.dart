import 'dart:convert';
import 'dart:math';
import 'dart:io';

import 'package:basic_utils/basic_utils.dart';
import 'package:crypto/crypto.dart';

import 'host_secret_store.dart';

class ServerIdentity {
  const ServerIdentity({
    required this.serverId,
    required this.certificatePem,
    required this.privateKeyPem,
    required this.fingerprint,
  });

  static const storageKey = 'windfull.server_identity.v1';
  static final _random = Random.secure();

  final String serverId;
  final String certificatePem;
  final String privateKeyPem;
  final String fingerprint;

  SecurityContext createSecurityContext() {
    final context = SecurityContext(withTrustedRoots: false)
      ..useCertificateChainBytes(utf8.encode(certificatePem))
      ..usePrivateKeyBytes(utf8.encode(privateKeyPem));
    return context;
  }

  static Future<ServerIdentity> loadOrCreate(HostSecretStore store) async {
    final stored = await store.read(storageKey);
    if (stored == null) {
      return _generateAndStore(store);
    }

    try {
      final json = jsonDecode(stored);
      if (json is! Map<String, dynamic>) {
        throw const FormatException('Formato de identidade inválido.');
      }
      final serverId = json['serverId'];
      final certificatePem = json['certificatePem'];
      final privateKeyPem = json['privateKeyPem'];
      if (serverId is! String ||
          !RegExp(r'^[0-9a-f]{32}$').hasMatch(serverId) ||
          certificatePem is! String ||
          privateKeyPem is! String) {
        throw const FormatException('A identidade persistida está incompleta.');
      }
      final identity = _fromParts(serverId, certificatePem, privateKeyPem);
      identity.createSecurityContext();
      return identity;
    } on Object catch (error) {
      throw HostIdentityException(
        'A identidade TLS existente está inválida e não foi substituída: $error',
      );
    }
  }

  static Future<ServerIdentity> _generateAndStore(HostSecretStore store) async {
    final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
    final serverId = bytes
        .map((value) => value.toRadixString(16).padLeft(2, '0'))
        .join();
    final pair = CryptoUtils.generateRSAKeyPair(keySize: 2048);
    final privateKey = pair.privateKey as RSAPrivateKey;
    final publicKey = pair.publicKey as RSAPublicKey;
    final privateKeyPem = CryptoUtils.encodeRSAPrivateKeyToPem(privateKey);
    final csr = X509Utils.generateRsaCsrPem(
      {'CN': 'Windfull $serverId'},
      privateKey,
      publicKey,
    );
    final certificatePem = X509Utils.generateSelfSignedCertificate(
      privateKey,
      csr,
      3650,
      serialNumber: (BigInt.parse(serverId, radix: 16) + BigInt.one).toString(),
    );
    final identity = _fromParts(serverId, certificatePem, privateKeyPem);
    identity.createSecurityContext();
    await store.write(
      storageKey,
      jsonEncode({
        'serverId': serverId,
        'certificatePem': certificatePem,
        'privateKeyPem': privateKeyPem,
      }),
    );
    return identity;
  }

  static ServerIdentity _fromParts(
    String serverId,
    String certificatePem,
    String privateKeyPem,
  ) {
    final der = _pemBytes(certificatePem);
    return ServerIdentity(
      serverId: serverId,
      certificatePem: certificatePem,
      privateKeyPem: privateKeyPem,
      fingerprint: sha256.convert(der).toString(),
    );
  }

  static List<int> _pemBytes(String pem) {
    final body = pem
        .replaceAll(RegExp(r'-----BEGIN [^-]+-----'), '')
        .replaceAll(RegExp(r'-----END [^-]+-----'), '')
        .replaceAll(RegExp(r'\s'), '');
    return base64.decode(body);
  }
}

class HostIdentityException implements Exception {
  const HostIdentityException(this.message);
  final String message;
  @override
  String toString() => message;
}
