import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:windfull_app/data/pairing_client_name.dart';
import 'package:windfull_app/data/pairing_store.dart';
import 'package:windfull_app/data/windfull_client.dart';

void main() {
  test('rediscovery requires the saved server id and fingerprint', () {
    final credential = PairingCredential(
      serverId: 'pc-1',
      host: '192.168.1.10',
      port: 8443,
      clientId: 'client',
      secret: 'secret',
      fingerprint: List.filled(64, 'a').join(),
    );
    final candidates = [
      DiscoveredServer(
        id: 'pc-1',
        name: 'PC WindFull',
        host: '192.168.1.22',
        port: 9443,
        fingerprint: List.filled(64, 'a').join(),
      ),
      DiscoveredServer(
        id: 'pc-1',
        name: 'Changed certificate',
        host: '192.168.1.30',
        port: 8443,
        fingerprint: List.filled(64, 'b').join(),
      ),
      DiscoveredServer(
        id: 'other-pc',
        name: 'Another PC',
        host: '192.168.1.40',
        port: 8443,
        fingerprint: List.filled(64, 'a').join(),
      ),
    ];

    final client = WindfullClient();
    final match = client.matchPinnedServer(credential, candidates);
    expect(match?.host, '192.168.1.22');
    expect(match?.port, 9443);
    expect(client.matchPinnedServer(credential, candidates.skip(1)), isNull);
  });

  test('validates IPv4 and parses only valid WindFull announcements', () {
    expect(WindfullClient.parseIpv4('10.0.2.2').address, '10.0.2.2');
    expect(
      () => WindfullClient.parseIpv4('not-an-ip'),
      throwsA(isA<WindfullException>()),
    );
    final announcement = WindfullClient.parseAnnouncement({
      'protocol': 'windfull/1',
      'id': 'host-1',
      'name': 'PC WindFull',
      'port': 8443,
      'fingerprint': List.filled(64, 'A').join(),
    }, '10.0.2.2');
    expect(announcement?.host, '10.0.2.2');
    expect(announcement?.fingerprint, List.filled(64, 'a').join());
    expect(
      WindfullClient.parseAnnouncement({'protocol': 'other'}, '10.0.2.2'),
      isNull,
    );
  });

  test('builds a useful device name with a generic fallback', () {
    expect(
      buildPairingClientName(manufacturer: 'Samsung', model: 'SM-S921B'),
      'Samsung SM-S921B',
    );
    expect(
      buildPairingClientName(manufacturer: 'Google', model: 'Google Pixel 9'),
      'Google Pixel 9',
    );
    expect(
      buildPairingClientName(manufacturer: 'unknown', model: 'unknown'),
      'Celular Android',
    );
  });

  test('discovers a server by UDP unicast using the same announcement', () async {
    final responder = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
    final subscription = responder.listen((event) {
      if (event != RawSocketEvent.read) return;
      Datagram? datagram;
      while ((datagram = responder.receive()) != null) {
        if (utf8.decode(datagram!.data) != 'WINDFULL_DISCOVER_V1') continue;
        final response = jsonEncode({
          'protocol': 'windfull/1',
          'id': 'test-host',
          'name': 'Test PC',
          'port': 9443,
          'fingerprint': List.filled(64, 'c').join(),
        });
        responder.send(utf8.encode(response), datagram.address, datagram.port);
      }
    });
    try {
      final servers = await WindfullClient().discover(
        targetIp: '127.0.0.1',
        port: responder.port,
        timeout: const Duration(milliseconds: 300),
      );
      expect(servers, hasLength(1));
      expect(servers.single.id, 'test-host');
      expect(servers.single.host, '127.0.0.1');
      expect(servers.single.port, 9443);
    } finally {
      await subscription.cancel();
      responder.close();
    }
  });
}
