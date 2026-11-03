import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'server_identity.dart';

class WindfullNetworkServer {
  WindfullNetworkServer({
    required this.identity,
    required this.onRequest,
    this.name = 'WindFull para Windows',
    InternetAddress? bindAddress,
    this.httpsPort = 47657,
    this.discoveryPort = 47656,
    this.enableDiscovery = true,
    this.onNetworkError,
  }) : bindAddress = bindAddress ?? InternetAddress.anyIPv4;

  static const discoveryRequest = 'WINDFULL_DISCOVER_V1';
  static const discoveryProtocol = 'windfull/1';

  final ServerIdentity identity;
  final Future<void> Function(HttpRequest request) onRequest;
  final String name;
  final InternetAddress bindAddress;
  final int httpsPort;
  final int discoveryPort;
  final bool enableDiscovery;
  final void Function(Object error)? onNetworkError;

  HttpServer? _httpServer;
  RawDatagramSocket? _discoverySocket;
  StreamSubscription<HttpRequest>? _httpSubscription;
  StreamSubscription<RawSocketEvent>? _discoverySubscription;

  int get boundHttpsPort => _httpServer?.port ?? httpsPort;
  int get boundDiscoveryPort => _discoverySocket?.port ?? discoveryPort;

  Future<void> start() async {
    if (_httpServer != null) return;
    final server = await HttpServer.bindSecure(
      bindAddress,
      httpsPort,
      identity.createSecurityContext(),
      shared: false,
      backlog: 128,
    );
    _httpServer = server;
    _httpSubscription = server.listen(
      (request) => unawaited(_serveRequest(request)),
      onError: (Object error, StackTrace stack) => onNetworkError?.call(error),
      cancelOnError: false,
    );

    if (enableDiscovery) {
      try {
        final socket = await RawDatagramSocket.bind(
          bindAddress,
          discoveryPort,
          reuseAddress: false,
          reusePort: false,
        );
        socket.broadcastEnabled = true;
        _discoverySocket = socket;
        _discoverySubscription = socket.listen(
          _onDatagramEvent,
          onError: (Object error, StackTrace stack) =>
              onNetworkError?.call(error),
          cancelOnError: false,
        );
      } on Object {
        await stop();
        rethrow;
      }
    }
  }

  Future<void> stop() async {
    await _discoverySubscription?.cancel();
    _discoverySubscription = null;
    _discoverySocket?.close();
    _discoverySocket = null;
    await _httpSubscription?.cancel();
    _httpSubscription = null;
    await _httpServer?.close(force: true);
    _httpServer = null;
  }

  Future<void> _serveRequest(HttpRequest request) async {
    try {
      await onRequest(request);
    } on Object catch (error) {
      onNetworkError?.call(error);
      try {
        request.response.statusCode = HttpStatus.internalServerError;
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'error': {
              'code': 'internal_error',
              'message': 'Erro interno no host.',
            },
          }),
        );
        await request.response.close();
      } on Object {
        // The client may have closed the connection while the host was writing.
      }
    }
  }

  void _onDatagramEvent(RawSocketEvent event) {
    if (event != RawSocketEvent.read) return;
    final socket = _discoverySocket;
    if (socket == null) return;
    Datagram? datagram;
    while ((datagram = socket.receive()) != null) {
      final packet = datagram!;
      if (packet.data.length != discoveryRequest.length) continue;
      if (utf8.decode(packet.data, allowMalformed: true) != discoveryRequest) {
        continue;
      }
      final response = utf8.encode(
        jsonEncode({
          'protocol': discoveryProtocol,
          'id': identity.serverId,
          'name': name,
          'port': boundHttpsPort,
          'fingerprint': identity.fingerprint,
        }),
      );
      socket.send(response, packet.address, packet.port);
    }
  }
}
