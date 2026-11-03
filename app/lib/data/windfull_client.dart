import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'pairing_store.dart';

class DiscoveredServer {
  const DiscoveredServer({
    required this.id,
    required this.name,
    required this.host,
    required this.port,
    required this.fingerprint,
  });

  final String id;
  final String name;
  final String host;
  final int port;
  final String fingerprint;
}

class WindfullClient {
  static const discoveryPort = 47656;
  static const maxResponseBytes = 1024 * 1024;
  final Random _random = Random.secure();

  Future<List<DiscoveredServer>> discover({
    Duration timeout = const Duration(seconds: 3),
    String? targetIp,
    int port = discoveryPort,
  }) async {
    final destination = targetIp == null
        ? InternetAddress('255.255.255.255')
        : parseIpv4(targetIp);
    final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    try {
      socket.broadcastEnabled = true;
      socket.send(utf8.encode('WINDFULL_DISCOVER_V1'),
          destination, port);
      final servers = <String, DiscoveredServer>{};
      final completer = Completer<List<DiscoveredServer>>();
      late StreamSubscription<RawSocketEvent> subscription;
      subscription = socket.listen((event) {
        if (event != RawSocketEvent.read) return;
        Datagram? datagram;
        while ((datagram = socket.receive()) != null) {
          try {
            final json = jsonDecode(utf8.decode(datagram!.data));
            if (json is! Map<String, dynamic>) continue;
            final server = parseAnnouncement(json, datagram.address.address);
            if (server == null) continue;
            servers['${server.id}@${server.host}'] = server;
          } on Object {
            // Ignore unrelated or malformed LAN datagrams.
          }
        }
      });
      final timeoutTimer = Timer(timeout, () {
        if (!completer.isCompleted) completer.complete(servers.values.toList());
      });
      final result = await completer.future;
      timeoutTimer.cancel();
      await subscription.cancel();
      return result;
    } finally {
      socket.close();
    }
  }

  static InternetAddress parseIpv4(String value) {
    final address = InternetAddress.tryParse(value.trim());
    if (address == null || address.type != InternetAddressType.IPv4) {
      throw const WindfullException('Informe um endere\u00e7o IPv4 v\u00e1lido, por exemplo 192.168.1.20.');
    }
    return address;
  }

  static DiscoveredServer? parseAnnouncement(
    Map<String, dynamic> json,
    String sourceHost,
  ) {
    try {
      if (json['protocol'] != 'windfull/1') return null;
      final id = json['id'];
      final name = json['name'];
      final port = json['port'];
      final fingerprint = json['fingerprint'];
      final address = InternetAddress.tryParse(sourceHost);
      if (id is! String || id.isEmpty || name is! String || name.isEmpty ||
          port is! int || port < 1 || port > 65535 ||
          fingerprint is! String || address == null ||
          address.type != InternetAddressType.IPv4) {
        return null;
      }
      final normalizedFingerprint = fingerprint.toLowerCase();
      if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(normalizedFingerprint)) return null;
      return DiscoveredServer(
        id: id,
        name: name,
        host: address.address,
        port: port,
        fingerprint: normalizedFingerprint,
      );
    } on Object {
      return null;
    }
  }

  Future<DiscoveredServer?> rediscover(PairingCredential credential) async {
    final servers = await discover();
    return matchPinnedServer(credential, servers);
  }

  DiscoveredServer? matchPinnedServer(
    PairingCredential credential,
    Iterable<DiscoveredServer> candidates,
  ) {
    for (final server in candidates) {
      if (server.id == credential.serverId && server.fingerprint == credential.fingerprint) {
        return server;
      }
    }
    return null;
  }

  Future<PairingSession> requestPairing(
    DiscoveredServer server, {
    required String clientName,
  }) async {
    final requestId = _randomHex(16);
    final clientId = _randomHex(16);
    final secret = _randomHex(32);
    final response = await _request(server, 'POST', '/v1/pairings', body: {
      'requestId': requestId,
      'clientId': clientId,
      'clientName': clientName,
      'secret': secret,
    });
    if (response['status'] != 'pending') {
      throw const WindfullException('Resposta inesperada ao solicitar pareamento.');
    }
    return PairingSession(
      server: server,
      requestId: requestId,
      clientId: clientId,
      secret: secret,
      comparisonCode: _comparisonCode(requestId, server.fingerprint),
    );
  }

  Future<String> pairingStatus(PairingSession session) async {
    final response = await _request(
      session.server,
      'GET',
      '/v1/pairings/${session.requestId}',
      clientId: session.clientId,
      secret: session.secret,
    );
    final status = response['status'];
    if (!const ['pending', 'approved', 'rejected', 'expired'].contains(status)) {
      throw const WindfullException('Status de pareamento inv\u00e1lido recebido do computador.');
    }
    return status as String;
  }

  PairingCredential credentialFor(PairingSession session) => PairingCredential(
        serverId: session.server.id,
        host: session.server.host,
        port: session.server.port,
        clientId: session.clientId,
        secret: session.secret,
        fingerprint: session.server.fingerprint,
      );

  Future<Map<String, dynamic>> getState(PairingCredential credential) =>
      _requestCredential(credential, 'GET', '/v1/state');

  Future<Map<String, dynamic>> command(
    PairingCredential credential,
    String type,
    Object value,
  ) =>
      _requestCredential(credential, 'POST', '/v1/commands', body: {
        'type': type,
        'value': value,
      });

  Future<Map<String, dynamic>> _requestCredential(
    PairingCredential credential,
    String method,
    String path, {
    Map<String, Object?>? body,
  }) =>
      _request(
        DiscoveredServer(
          id: credential.serverId,
          name: credential.serverId,
          host: credential.host,
          port: credential.port,
          fingerprint: credential.fingerprint,
        ),
        method,
        path,
        body: body,
        clientId: credential.clientId,
        secret: credential.secret,
      );

  Future<Map<String, dynamic>> _request(
    DiscoveredServer server,
    String method,
    String path, {
    Map<String, Object?>? body,
    String? clientId,
    String? secret,
  }) async {
    final context = SecurityContext(withTrustedRoots: false);
    final client = HttpClient(context: context)
      ..connectionTimeout = const Duration(seconds: 5)
      ..badCertificateCallback = (certificate, host, port) =>
          sha256.convert(certificate.der).toString() == server.fingerprint;
    try {
      final request = await client
          .openUrl(
            method,
            Uri(scheme: 'https', host: server.host, port: server.port, path: path),
          )
          .timeout(const Duration(seconds: 5));
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      if (clientId != null) request.headers.set('X-Windfull-Client', clientId);
      if (secret != null) request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $secret');
      if (body != null) {
        request.headers.contentType = ContentType.json;
        request.write(jsonEncode(body));
      }
      final response = await request.close().timeout(const Duration(seconds: 5));
      final bytes = await response.fold<BytesBuilder>(
        BytesBuilder(copy: false),
        (builder, chunk) {
          if (builder.length + chunk.length > maxResponseBytes) {
            throw const WindfullException('A resposta do computador excede o limite permitido.');
          }
          builder.add(chunk);
          return builder;
        },
      ).timeout(const Duration(seconds: 5));
      final text = utf8.decode(bytes.takeBytes());
      Map<String, dynamic> decoded = <String, dynamic>{};
      if (text.isNotEmpty) {
        try {
          decoded = jsonDecode(text) as Map<String, dynamic>;
        } on Object {
          throw const WindfullException('O computador retornou uma resposta inv\u00e1lida.');
        }
      }
      if (response.statusCode == HttpStatus.unauthorized) {
        throw const WindfullUnauthorizedException();
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final error = decoded['error'];
        if (error is Map && error['message'] is String) {
          throw WindfullException(error['message'] as String);
        }
        throw WindfullException('O computador respondeu com erro HTTP ${response.statusCode}.');
      }
      return decoded;
    } on WindfullException {
      rethrow;
    } on Object catch (error) {
      throw WindfullException('N\u00e3o foi poss\u00edvel conversar com o computador: $error');
    } finally {
      client.close(force: true);
    }
  }

  String _randomHex(int byteCount) => List<int>.generate(byteCount, (_) => _random.nextInt(256))
      .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
      .join();

  String _comparisonCode(String requestId, String fingerprint) {
    final digest = sha256.convert(utf8.encode('windfull-pair-v1:$requestId:$fingerprint'));
    final bytes = digest.bytes;
    final number = ((bytes[0] << 24) | (bytes[1] << 16) | (bytes[2] << 8) | bytes[3]) % 1000000;
    return number.toString().padLeft(6, '0');
  }
}

class PairingSession {
  const PairingSession({
    required this.server,
    required this.requestId,
    required this.clientId,
    required this.secret,
    required this.comparisonCode,
  });

  final DiscoveredServer server;
  final String requestId;
  final String clientId;
  final String secret;
  final String comparisonCode;
}

class WindfullException implements Exception {
  const WindfullException(this.message);
  final String message;
  @override
  String toString() => message;
}

class WindfullUnauthorizedException extends WindfullException {
  const WindfullUnauthorizedException()
      : super('Este celular n\u00e3o est\u00e1 mais autorizado. Fa\u00e7a o pareamento novamente.');
}
