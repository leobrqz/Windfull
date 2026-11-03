import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:windfull_server/src/appliance/appliance_models.dart';
import 'package:windfull_server/src/appliance/appliance_repository.dart';
import 'package:windfull_server/src/host/windfull_host.dart';
import 'package:windfull_server/src/network/host_secret_store.dart';
import 'package:windfull_server/src/network/host_settings_store.dart';
import 'package:windfull_server/src/network/server_identity.dart';
import 'package:windfull_server/src/network/windfull_network_server.dart';
import 'package:windfull_server/src/ui/host_controller.dart';

void main() {
  test(
    'keeps a valid server identity and refuses to replace corrupt identity',
    () async {
      final secretStore = MemoryHostSecretStore();
      final first = await ServerIdentity.loadOrCreate(secretStore);
      final second = await ServerIdentity.loadOrCreate(secretStore);
      expect(second.serverId, first.serverId);
      expect(second.fingerprint, first.fingerprint);

      final corruptStore = MemoryHostSecretStore()
        ..values[ServerIdentity.storageKey] = '{"serverId":"incomplete"}';
      final before = corruptStore.values[ServerIdentity.storageKey];
      await expectLater(
        ServerIdentity.loadOrCreate(corruptStore),
        throwsA(isA<HostIdentityException>()),
      );
      expect(corruptStore.values[ServerIdentity.storageKey], before);
    },
  );

  test(
    'binds pinned HTTPS, pairs, serves real capabilities, and revokes access',
    () async {
      final temp = await Directory.systemTemp.createTemp('windfull-host-test-');
      final secretStore = MemoryHostSecretStore();
      final repository = FakeApplianceRepository();
      final host = WindfullHost(
        applianceRepository: repository,
        secretStore: secretStore,
        settingsStore: MemoryHostSettingsStore(),
        dataDirectory: temp,
        bindAddress: InternetAddress.loopbackIPv4,
        httpsPort: 0,
        discoveryPort: 0,
        enableDiscovery: false,
        autoDiscover: false,
      );
      final client = HttpClient();
      addTearDown(() async {
        client.close(force: true);
        await host.shutdown();
        await temp.delete(recursive: true);
      });

      await host.start();
      expect(host.state.status, HostStatus.ready);
      await host.configureApplianceManually(host: '192.168.1.30');
      final fingerprint = host.state.certificateFingerprint!;
      client.badCertificateCallback = (certificate, _, _) =>
          sha256.convert(certificate.der).toString() == fingerprint;

      const requestId = '00112233445566778899aabbccddeeff';
      const clientId = 'ffeeddccbbaa99887766554433221100';
      const secret =
          '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
      final createPairing = await _send(
        client,
        host.state.serverPort!,
        'POST',
        '/v1/pairings',
        body: {
          'requestId': requestId,
          'clientId': clientId,
          'clientName': 'Celular da Ana\nNome informado pelo cliente',
          'secret': secret,
        },
      );
      expect(createPairing.statusCode, HttpStatus.accepted);
      expect(createPairing.json['status'], 'pending');
      expect(
        host.state.pendingPairings.single.verificationCode,
        _comparisonCode(requestId, fingerprint),
      );
      expect(
        host.state.pendingPairings.single.deviceName,
        'Celular da AnaNome informado pelo cliente',
      );

      const otherRequestId = '11223344556677889900aabbccddeeff';
      const otherClientId = '00112233445566778899aabbccddeeff';
      const otherSecret =
          'abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789';
      await _send(
        client,
        host.state.serverPort!,
        'POST',
        '/v1/pairings',
        body: {
          'requestId': otherRequestId,
          'clientId': otherClientId,
          'clientName': 'Outro celular',
          'secret': otherSecret,
        },
      );
      final crossRequestPoll = await _send(
        client,
        host.state.serverPort!,
        'GET',
        '/v1/pairings/$otherRequestId',
        clientId: clientId,
        secret: secret,
      );
      expect(crossRequestPoll.statusCode, HttpStatus.unauthorized);

      final unauthenticatedState = await _send(
        client,
        host.state.serverPort!,
        'GET',
        '/v1/state',
      );
      expect(unauthenticatedState.statusCode, HttpStatus.unauthorized);

      final pending = await _send(
        client,
        host.state.serverPort!,
        'GET',
        '/v1/pairings/$requestId',
        clientId: clientId,
        secret: secret,
      );
      expect(pending.json['status'], 'pending');

      await host.approvePairingRequest(requestId);
      expect(
        host.state.pairedDevices.single.name,
        'Celular da AnaNome informado pelo cliente',
      );
      final approved = await _send(
        client,
        host.state.serverPort!,
        'GET',
        '/v1/pairings/$requestId',
        clientId: clientId,
        secret: secret,
      );
      expect(approved.json['status'], 'approved');

      final state = await _send(
        client,
        host.state.serverPort!,
        'GET',
        '/v1/state',
        clientId: clientId,
        secret: secret,
      );
      expect(state.statusCode, HttpStatus.ok);
      expect(state.json['connected'], isTrue);
      expect(state.json['device']['host'], '192.168.1.30');
      expect(state.json['capabilities']['modes'], ['cool']);
      expect(state.json['capabilities']['windFree'], isFalse);
      expect(state.json['state']['power'], isFalse);

      final power = await _send(
        client,
        host.state.serverPort!,
        'POST',
        '/v1/commands',
        clientId: clientId,
        secret: secret,
        body: {'type': 'power', 'value': true},
      );
      expect(power.statusCode, HttpStatus.ok);
      expect(power.json['state']['power'], isTrue);
      expect(repository.setPowerCalls, 1);

      final unsupported = await _send(
        client,
        host.state.serverPort!,
        'POST',
        '/v1/commands',
        clientId: clientId,
        secret: secret,
        body: {'type': 'windFree', 'value': true},
      );
      expect(unsupported.statusCode, HttpStatus.unprocessableEntity);
      expect(repository.setWindFreeCalls, 0);

      final outOfRange = await _send(
        client,
        host.state.serverPort!,
        'POST',
        '/v1/commands',
        clientId: clientId,
        secret: secret,
        body: {'type': 'temperature', 'value': 31},
      );
      expect(outOfRange.statusCode, HttpStatus.unprocessableEntity);
      expect(repository.setTemperatureCalls, 0);

      expect(secretStore.values.values.join('\n'), isNot(contains(secret)));

      await host.revokePairedDevice(clientId);
      final revoked = await _send(
        client,
        host.state.serverPort!,
        'GET',
        '/v1/state',
        clientId: clientId,
        secret: secret,
      );
      expect(revoked.statusCode, HttpStatus.unauthorized);
    },
  );

  test(
    'serializes approve, reject and revoke for one pairing request',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'windfull-host-pair-race-test-',
      );
      final secretStore = MemoryHostSecretStore();
      final host = WindfullHost(
        applianceRepository: FakeApplianceRepository(),
        secretStore: secretStore,
        settingsStore: MemoryHostSettingsStore(),
        dataDirectory: temp,
        bindAddress: InternetAddress.loopbackIPv4,
        httpsPort: 0,
        discoveryPort: 0,
        enableDiscovery: false,
        autoDiscover: false,
      );
      final client = HttpClient();
      addTearDown(() async {
        client.close(force: true);
        await host.shutdown();
        await temp.delete(recursive: true);
      });
      await host.start();
      final fingerprint = host.state.certificateFingerprint!;
      client.badCertificateCallback = (certificate, _, _) =>
          sha256.convert(certificate.der).toString() == fingerprint;
      const requestId = '223344556677889900aabbccddeeff11';
      const clientId = '3344556677889900aabbccddeeff1122';
      const secret =
          'fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210';
      await _send(
        client,
        host.state.serverPort!,
        'POST',
        '/v1/pairings',
        body: {
          'requestId': requestId,
          'clientId': clientId,
          'clientName': 'Celular de teste',
          'secret': secret,
        },
      );

      final writeStarted = Completer<void>();
      final writeGate = Completer<void>();
      secretStore
        ..pairedWriteStarted = writeStarted
        ..pairedWriteGate = writeGate;
      final approval = host.approvePairingRequest(requestId);
      await writeStarted.future.timeout(const Duration(seconds: 2));
      final rejection = host.rejectPairingRequest(requestId);
      final revocation = host.revokePairedDevice(clientId);
      writeGate.complete();
      await approval;
      await expectLater(rejection, throwsA(isA<HostActionException>()));
      await revocation;

      expect(host.state.pendingPairings, isEmpty);
      expect(host.state.pairedDevices, isEmpty);
      final unauthorized = await _send(
        client,
        host.state.serverPort!,
        'GET',
        '/v1/state',
        clientId: clientId,
        secret: secret,
      );
      expect(unauthorized.statusCode, HttpStatus.unauthorized);

      const secondRequestId = '44556677889900aabbccddeeff112233';
      await _send(
        client,
        host.state.serverPort!,
        'POST',
        '/v1/pairings',
        body: {
          'requestId': secondRequestId,
          'clientId': clientId,
          'clientName': 'Celular de teste',
          'secret': secret,
        },
      );
      await host.approvePairingRequest(secondRequestId);
      final revokeStarted = Completer<void>();
      final revokeGate = Completer<void>();
      secretStore
        ..pairedWriteStarted = revokeStarted
        ..pairedWriteGate = revokeGate;
      final revokeInFlight = host.revokePairedDevice(clientId);
      await revokeStarted.future.timeout(const Duration(seconds: 2));
      final blockedDuringRevoke = await _send(
        client,
        host.state.serverPort!,
        'GET',
        '/v1/state',
        clientId: clientId,
        secret: secret,
      );
      expect(blockedDuringRevoke.statusCode, HttpStatus.unauthorized);
      revokeGate.complete();
      await revokeInFlight;
    },
  );

  test(
    'rejects browser origins, invalid content types and oversized JSON',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'windfull-host-input-test-',
      );
      final host = WindfullHost(
        applianceRepository: FakeApplianceRepository(),
        secretStore: MemoryHostSecretStore(),
        settingsStore: MemoryHostSettingsStore(),
        dataDirectory: temp,
        bindAddress: InternetAddress.loopbackIPv4,
        httpsPort: 0,
        discoveryPort: 0,
        enableDiscovery: false,
        autoDiscover: false,
      );
      final client = HttpClient();
      addTearDown(() async {
        client.close(force: true);
        await host.shutdown();
        await temp.delete(recursive: true);
      });
      await host.start();
      final fingerprint = host.state.certificateFingerprint!;
      client.badCertificateCallback = (certificate, _, _) =>
          sha256.convert(certificate.der).toString() == fingerprint;
      final port = host.state.serverPort!;

      final origin = await _send(
        client,
        port,
        'POST',
        '/v1/pairings',
        body: const {},
        origin: 'https://example.test',
      );
      expect(origin.statusCode, HttpStatus.forbidden);

      final wrongContentType = await _send(
        client,
        port,
        'POST',
        '/v1/pairings',
        body: const {},
        contentType: ContentType.text,
      );
      expect(wrongContentType.statusCode, HttpStatus.unsupportedMediaType);

      final tooLarge = await _sendRaw(
        client,
        port,
        'POST',
        '/v1/pairings',
        '{"padding":"${'x' * 9000}"}',
        contentType: ContentType.json,
      );
      expect(tooLarge.statusCode, 413);
    },
  );

  test('times out a client that stalls while streaming a JSON body', () async {
    final temp = await Directory.systemTemp.createTemp(
      'windfull-host-body-timeout-test-',
    );
    final host = WindfullHost(
      applianceRepository: FakeApplianceRepository(),
      secretStore: MemoryHostSecretStore(),
      settingsStore: MemoryHostSettingsStore(),
      dataDirectory: temp,
      bindAddress: InternetAddress.loopbackIPv4,
      httpsPort: 0,
      discoveryPort: 0,
      enableDiscovery: false,
      autoDiscover: false,
      requestBodyTimeout: const Duration(milliseconds: 75),
    );
    await host.start();
    final fingerprint = host.state.certificateFingerprint!;
    final socket = await SecureSocket.connect(
      '127.0.0.1',
      host.state.serverPort!,
      onBadCertificate: (certificate) =>
          sha256.convert(certificate.der).toString() == fingerprint,
    );
    addTearDown(() async {
      socket.destroy();
      await host.shutdown();
      await temp.delete(recursive: true);
    });
    socket.write(
      'POST /v1/pairings HTTP/1.1\r\n'
      'Host: 127.0.0.1\r\n'
      'Content-Type: application/json\r\n'
      'Transfer-Encoding: chunked\r\n'
      'Connection: close\r\n\r\n1\r\n{\r\n',
    );
    await socket.flush();
    final response = await utf8.decoder
        .bind(socket)
        .join()
        .timeout(const Duration(seconds: 2));
    expect(response, contains('408'));
    expect(response, contains('request_body_timeout'));
  });

  test(
    'persists server identity and paired credentials across restarts and revocation',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'windfull-persist-test-',
      );
      final secretStore = MemoryHostSecretStore();
      final settingsStore = MemoryHostSettingsStore();
      final client = HttpClient();
      final hosts = <WindfullHost>[];
      WindfullHost createHost() {
        final host = WindfullHost(
          applianceRepository: FakeApplianceRepository(),
          secretStore: secretStore,
          settingsStore: settingsStore,
          dataDirectory: temp,
          bindAddress: InternetAddress.loopbackIPv4,
          httpsPort: 0,
          discoveryPort: 0,
          enableDiscovery: false,
          autoDiscover: false,
        );
        hosts.add(host);
        return host;
      }

      addTearDown(() async {
        client.close(force: true);
        for (final host in hosts) {
          await host.shutdown();
        }
        await temp.delete(recursive: true);
      });

      const requestId = '102132435465768798a9bacbdcedfe0f';
      const clientId = 'f0edcdbcab9a89786756453423120110';
      const secret =
          'abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789';

      final firstHost = createHost();
      await firstHost.start();
      final originalFingerprint = firstHost.state.certificateFingerprint!;
      client.badCertificateCallback = (certificate, _, _) =>
          sha256.convert(certificate.der).toString() == originalFingerprint;
      await _send(
        client,
        firstHost.state.serverPort!,
        'POST',
        '/v1/pairings',
        body: {
          'requestId': requestId,
          'clientId': clientId,
          'clientName': 'Celular persistente',
          'secret': secret,
        },
      );
      await firstHost.approvePairingRequest(requestId);
      await firstHost.shutdown();

      final secondHost = createHost();
      await secondHost.start();
      expect(secondHost.state.certificateFingerprint, originalFingerprint);
      expect(secondHost.state.pairedDevices.single.id, clientId);
      final stillAuthorized = await _send(
        client,
        secondHost.state.serverPort!,
        'GET',
        '/v1/state',
        clientId: clientId,
        secret: secret,
      );
      expect(stillAuthorized.statusCode, HttpStatus.ok);
      await secondHost.revokePairedDevice(clientId);
      await secondHost.shutdown();

      final thirdHost = createHost();
      await thirdHost.start();
      expect(thirdHost.state.certificateFingerprint, originalFingerprint);
      expect(thirdHost.state.pairedDevices, isEmpty);
      final remainsRevoked = await _send(
        client,
        thirdHost.state.serverPort!,
        'GET',
        '/v1/state',
        clientId: clientId,
        secret: secret,
      );
      expect(remainsRevoked.statusCode, HttpStatus.unauthorized);
    },
  );

  test(
    'reconnects the persisted appliance by ID after its IP changes',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'windfull-reconnect-test-',
      );
      final repository = FakeApplianceRepository();
      final settings = MemoryHostSettingsStore();
      final host = WindfullHost(
        applianceRepository: repository,
        secretStore: MemoryHostSecretStore(),
        settingsStore: settings,
        dataDirectory: temp,
        bindAddress: InternetAddress.loopbackIPv4,
        httpsPort: 0,
        discoveryPort: 0,
        enableDiscovery: false,
        autoDiscover: false,
        applianceRefreshInterval: const Duration(milliseconds: 30),
      );
      addTearDown(() async {
        await host.shutdown();
        await temp.delete(recursive: true);
      });

      await host.start();
      await host.configureApplianceManually(host: '192.168.1.30');
      expect(settings.value?['applianceId'], 'unit-1');
      repository
        ..failReads = true
        ..discoveredHost = '192.168.1.31';
      await _waitFor(
        () => host.state.applianceConnection == ApplianceConnectionStatus.error,
        timeout: const Duration(seconds: 2),
      );

      repository.failReads = false;
      await _waitFor(
        () =>
            host.state.applianceConnection ==
                ApplianceConnectionStatus.connected &&
            host.state.appliance?.host == '192.168.1.31',
        timeout: const Duration(seconds: 8),
      );
      expect(repository.connectionHosts, contains('192.168.1.31'));
      expect(settings.value?['applianceId'], 'unit-1');
      expect(settings.value?['applianceHost'], '192.168.1.31');
    },
  );

  test(
    'retryServer keeps one appliance timer and shutdown stops the bridge',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'windfull-retry-timer-test-',
      );
      final repository = FakeApplianceRepository();
      final host = WindfullHost(
        applianceRepository: repository,
        secretStore: MemoryHostSecretStore(),
        settingsStore: MemoryHostSettingsStore(),
        dataDirectory: temp,
        bindAddress: InternetAddress.loopbackIPv4,
        httpsPort: 0,
        discoveryPort: 0,
        enableDiscovery: false,
        autoDiscover: false,
        applianceRefreshInterval: const Duration(milliseconds: 40),
      );
      addTearDown(() async {
        await host.shutdown();
        await temp.delete(recursive: true);
      });
      await host.start();
      await host.configureApplianceManually(host: '192.168.1.30');
      for (var index = 0; index < 4; index++) {
        await host.retryServer();
      }
      final baseline = repository.readStateCalls;
      await Future<void>.delayed(const Duration(milliseconds: 220));
      final refreshes = repository.readStateCalls - baseline;
      expect(refreshes, inInclusiveRange(3, 8));

      final disconnectsBeforeShutdown = repository.disconnectCalls;
      await host.shutdown();
      await host.shutdown();
      expect(repository.disconnectCalls, disconnectsBeforeShutdown + 1);
      final callsAfterShutdown = repository.readStateCalls;
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(repository.readStateCalls, callsAfterShutdown);
    },
  );

  test('cleans up HTTPS listener if exclusive discovery bind fails', () async {
    final identity = await ServerIdentity.loadOrCreate(MemoryHostSecretStore());
    final udpInUse = await RawDatagramSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    final tcpReservation = await ServerSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    final httpsPort = tcpReservation.port;
    await tcpReservation.close();
    final server = WindfullNetworkServer(
      identity: identity,
      onRequest: (_) async {},
      bindAddress: InternetAddress.loopbackIPv4,
      httpsPort: httpsPort,
      discoveryPort: udpInUse.port,
      enableDiscovery: true,
    );
    addTearDown(udpInUse.close);

    await expectLater(server.start(), throwsA(isA<SocketException>()));
    final reclaimed = await HttpServer.bindSecure(
      InternetAddress.loopbackIPv4,
      httpsPort,
      identity.createSecurityContext(),
      shared: false,
    );
    await reclaimed.close(force: true);
    await server.stop();
  });

  test(
    'answers LAN discovery datagrams with the pinned server identity',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'windfull-host-discovery-test-',
      );
      final host = WindfullHost(
        applianceRepository: FakeApplianceRepository(),
        secretStore: MemoryHostSecretStore(),
        settingsStore: MemoryHostSettingsStore(),
        dataDirectory: temp,
        bindAddress: InternetAddress.loopbackIPv4,
        httpsPort: 0,
        discoveryPort: 0,
        enableDiscovery: true,
        autoDiscover: false,
      );
      addTearDown(() async {
        await host.shutdown();
        await temp.delete(recursive: true);
      });
      await host.start();

      final socket = await RawDatagramSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      addTearDown(socket.close);
      final replyCompleter = Completer<Datagram>();
      final subscription = socket.listen((event) {
        if (event != RawSocketEvent.read) return;
        Datagram? packet;
        while ((packet = socket.receive()) != null) {
          if (!replyCompleter.isCompleted) replyCompleter.complete(packet);
        }
      });
      addTearDown(subscription.cancel);
      socket.send(
        utf8.encode('WINDFULL_DISCOVER_V1'),
        InternetAddress.loopbackIPv4,
        host.boundDiscoveryPort!,
      );
      final reply = await replyCompleter.future.timeout(
        const Duration(seconds: 2),
      );
      final json = jsonDecode(utf8.decode(reply.data)) as Map<String, dynamic>;
      expect(json['protocol'], 'windfull/1');
      expect(json['id'], isNotEmpty);
      expect(json['port'], host.state.serverPort);
      expect(json['fingerprint'], host.state.certificateFingerprint);
    },
  );
}

String _comparisonCode(String requestId, String fingerprint) {
  final bytes = sha256
      .convert(utf8.encode('windfull-pair-v1:$requestId:$fingerprint'))
      .bytes;
  final number =
      ((bytes[0] << 24) | (bytes[1] << 16) | (bytes[2] << 8) | bytes[3]) %
      1000000;
  return number.toString().padLeft(6, '0');
}

Future<_Response> _send(
  HttpClient client,
  int port,
  String method,
  String path, {
  Map<String, Object?>? body,
  String? clientId,
  String? secret,
  String? origin,
  ContentType? contentType,
}) async {
  final request = await client.openUrl(
    method,
    Uri(scheme: 'https', host: '127.0.0.1', port: port, path: path),
  );
  if (clientId != null) request.headers.set('X-Windfull-Client', clientId);
  if (secret != null) {
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $secret');
  }
  if (origin != null) request.headers.set('Origin', origin);
  if (body != null) {
    request.headers.contentType = contentType ?? ContentType.json;
    request.write(jsonEncode(body));
  }
  return _finish(request);
}

Future<_Response> _sendRaw(
  HttpClient client,
  int port,
  String method,
  String path,
  String body, {
  required ContentType contentType,
}) async {
  final request = await client.openUrl(
    method,
    Uri(scheme: 'https', host: '127.0.0.1', port: port, path: path),
  );
  request.headers.contentType = contentType;
  request.write(body);
  return _finish(request);
}

Future<_Response> _finish(HttpClientRequest request) async {
  final response = await request.close();
  final text = await response.transform(utf8.decoder).join();
  return _Response(
    response.statusCode,
    text.isEmpty ? {} : jsonDecode(text) as Map<String, dynamic>,
  );
}

class _Response {
  const _Response(this.statusCode, this.json);
  final int statusCode;
  final Map<String, dynamic> json;
}

class MemoryHostSecretStore implements HostSecretStore {
  final Map<String, String> values = {};
  Completer<void>? pairedWriteStarted;
  Completer<void>? pairedWriteGate;
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async {
    if (key == 'windfull.paired_devices.v1' && pairedWriteGate != null) {
      final started = pairedWriteStarted;
      if (started != null && !started.isCompleted) started.complete();
      await pairedWriteGate!.future;
      pairedWriteGate = null;
    }
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async => values.remove(key);
}

class MemoryHostSettingsStore implements HostSettingsStore {
  Map<String, Object?>? value;
  @override
  Future<Map<String, Object?>?> read() async => value;
  @override
  Future<void> write(Map<String, Object?> settings) async =>
      value = Map.of(settings);
}

class FakeApplianceRepository implements ApplianceRepository {
  bool failReads = false;
  String discoveredHost = '192.168.1.30';
  final List<String> connectionHosts = [];
  int readStateCalls = 0;
  int disconnectCalls = 0;
  ApplianceSnapshot snapshot = ApplianceSnapshot(power: false, temperature: 23);
  int setPowerCalls = 0;
  int setTemperatureCalls = 0;
  int setWindFreeCalls = 0;

  @override
  Stream<List<ApplianceDevice>> discover({
    Duration timeout = const Duration(seconds: 8),
  }) async* {
    yield [
      ApplianceDevice(
        id: 'unit-1',
        host: discoveredHost,
        name: 'Sala',
        model: 'Test AC',
      ),
    ];
  }

  @override
  Future<ApplianceDevice> connect(String host, {int? port}) async {
    connectionHosts.add(host);
    return ApplianceDevice(
      id: 'unit-1',
      host: host,
      name: 'Sala',
      model: 'Test AC',
      port: port,
    );
  }

  @override
  Future<ApplianceSnapshot> readState() async {
    readStateCalls++;
    if (failReads) throw const ApplianceException('Ar indisponível.');
    return snapshot;
  }

  @override
  Future<ApplianceCapabilities> readCapabilities() async =>
      ApplianceCapabilities(
        power: true,
        temperature: TemperatureLimits(
          available: true,
          minimum: 16,
          maximum: 30,
          step: 1,
        ),
        modes: [AcMode.cool],
        fanSpeeds: [FanSpeed.high],
        windFree: false,
      );

  @override
  Future<ApplianceSnapshot> setPower(bool enabled) async {
    setPowerCalls++;
    snapshot = ApplianceSnapshot(
      power: enabled,
      temperature: snapshot.temperature,
    );
    return snapshot;
  }

  @override
  Future<ApplianceSnapshot> setTemperature(double celsius) async {
    setTemperatureCalls++;
    snapshot = ApplianceSnapshot(power: snapshot.power, temperature: celsius);
    return snapshot;
  }

  @override
  Future<ApplianceSnapshot> setMode(AcMode mode) async => snapshot;

  @override
  Future<ApplianceSnapshot> setFanSpeed(FanSpeed speed) async => snapshot;

  @override
  Future<ApplianceSnapshot> setWindFree(bool enabled) async {
    setWindFreeCalls++;
    return snapshot;
  }

  @override
  Future<void> disconnect() async {
    disconnectCalls++;
  }
}

Future<void> _waitFor(
  bool Function() condition, {
  required Duration timeout,
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Timed out waiting for condition.');
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}
