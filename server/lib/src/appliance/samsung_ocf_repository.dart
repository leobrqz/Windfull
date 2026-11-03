import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'appliance_models.dart';
import 'appliance_repository.dart';

/// Controls compatible Samsung OCF air conditioners over the local network.
///
/// The native bridge must be packaged beside the Windows host. The bridge
/// keeps one DTLS session open and stores its generated client identity under
/// [dataDirectory]. No SmartThings cloud calls are made.
class SamsungOcfRepository implements ApplianceRepository {
  SamsungOcfRepository({
    required this.bridgeExecutable,
    required this.dataDirectory,
    this.requestTimeout = const Duration(seconds: 30),
  });

  final String bridgeExecutable;
  final Directory dataDirectory;
  final Duration requestTimeout;

  Process? _process;
  Future<Process>? _starting;
  int _nextRequestId = 0;
  final Map<int, Completer<Map<String, Object?>>> _pending = {};
  ApplianceCapabilities? _capabilities;
  bool _closed = false;

  @override
  Stream<List<ApplianceDevice>> discover({
    Duration timeout = const Duration(seconds: 8),
  }) async* {
    final result = await _send('discover', {
      'timeoutMs': timeout.inMilliseconds,
    }, timeout: timeout + const Duration(seconds: 40));
    final devices = (result as List<Object?>)
        .whereType<Map<String, Object?>>()
        .map(_deviceFromJson)
        .toList(growable: false);
    yield devices;
  }

  @override
  Future<ApplianceDevice> connect(String host, {int? port}) async {
    final result = await _send('connect', {'host': host, 'port': ?port});
    _capabilities = null;
    return _deviceFromJson(_asObject(result));
  }

  @override
  Future<ApplianceSnapshot> readState() async =>
      _snapshotFromJson(await _send('state', const {}));

  @override
  Future<ApplianceCapabilities> readCapabilities() async {
    final cached = _capabilities;
    if (cached != null) return cached;
    final result = _asObject(await _send('capabilities', const {}));
    _capabilities = _capabilitiesFromJson(result);
    return _capabilities!;
  }

  @override
  Future<ApplianceSnapshot> setPower(bool enabled) async {
    final capabilities = await _loadCapabilities();
    if (capabilities.power != true) {
      throw const UnsupportedApplianceOperation(
        'O aparelho não anunciou um controle de energia compatível.',
      );
    }
    return _snapshotFromJson(await _send('setPower', {'enabled': enabled}));
  }

  @override
  Future<ApplianceSnapshot> setTemperature(double celsius) async {
    final capabilities = await _loadCapabilities();
    final limits = capabilities.temperature;
    if (limits?.available != true) {
      throw const UnsupportedApplianceOperation(
        'O aparelho não anunciou um controle de temperatura alvo.',
      );
    }
    final minimum = limits?.minimum;
    final maximum = limits?.maximum;
    final step = limits?.step;
    if (!celsius.isFinite ||
        (minimum != null && celsius < minimum) ||
        (maximum != null && celsius > maximum)) {
      throw const ApplianceException(
        'A temperatura solicitada está fora dos limites anunciados pelo aparelho.',
        code: 'invalid_argument',
      );
    }
    if (minimum != null && step != null && step > 0) {
      final increments = (celsius - minimum) / step;
      if ((increments - increments.round()).abs() > 1e-6) {
        throw const ApplianceException(
          'A temperatura solicitada não corresponde ao incremento anunciado pelo aparelho.',
          code: 'invalid_argument',
        );
      }
    }
    return _snapshotFromJson(
      await _send('setTemperature', {'celsius': celsius}),
    );
  }

  @override
  Future<ApplianceSnapshot> setMode(AcMode mode) async {
    final capabilities = await _loadCapabilities();
    if (!capabilities.modes.contains(mode)) {
      throw const UnsupportedApplianceOperation(
        'O aparelho não anunciou esse modo de operação.',
      );
    }
    final value = switch (mode) {
      AcMode.cool => 'cool',
      AcMode.dry => 'dry',
      AcMode.fan => 'fan',
      AcMode.auto => 'auto',
      AcMode.heat => 'heat',
      AcMode.unknown => throw const UnsupportedApplianceOperation(
        'Modo OCF desconhecido não pode ser enviado como comando.',
      ),
    };
    return _snapshotFromJson(await _send('setMode', {'value': value}));
  }

  @override
  Future<ApplianceSnapshot> setFanSpeed(FanSpeed speed) async {
    final capabilities = await _loadCapabilities();
    if (!capabilities.fanSpeeds.contains(speed)) {
      throw const UnsupportedApplianceOperation(
        'O aparelho não anunciou essa velocidade de ventilação.',
      );
    }
    final value = switch (speed) {
      FanSpeed.auto => 'auto',
      FanSpeed.low => 'low',
      FanSpeed.medium => 'medium',
      FanSpeed.high => 'high',
      FanSpeed.turbo => 'turbo',
      FanSpeed.unknown => throw const UnsupportedApplianceOperation(
        'Velocidade OCF desconhecida não pode ser enviada como comando.',
      ),
    };
    return _snapshotFromJson(await _send('setFanSpeed', {'value': value}));
  }

  @override
  Future<ApplianceSnapshot> setWindFree(bool enabled) async {
    final capabilities = await _loadCapabilities();
    if (capabilities.windFree != true) {
      throw const UnsupportedApplianceOperation(
        'O aparelho não anunciou suporte a WindFree.',
      );
    }
    return _snapshotFromJson(
      await _send('setWindFree', {'value': enabled.toString()}),
    );
  }

  @override
  Future<void> disconnect() async {
    if (_process == null) return;
    await _send('disconnect', const {});
    _capabilities = null;
  }

  /// Stops the child process and closes its DTLS session. Call when the host
  /// shuts down; [disconnect] alone leaves the bridge available for reconnect.
  Future<void> dispose() async {
    if (_closed) return;
    final process = _process;
    if (process == null) {
      _closed = true;
      return;
    }
    try {
      await _send('shutdown', const {}, timeout: const Duration(seconds: 2));
      await process.exitCode.timeout(const Duration(seconds: 2));
    } on Object {
      process.kill();
    } finally {
      _closed = true;
      _process = null;
      _failPending(
        const ApplianceException(
          'A ponte Samsung foi encerrada.',
          code: 'bridge_closed',
        ),
      );
    }
  }

  Future<ApplianceCapabilities> _loadCapabilities() async =>
      _capabilities ?? await readCapabilities();

  Future<Object?> _send(
    String method,
    Map<String, Object?> params, {
    Duration? timeout,
  }) async {
    if (_closed && method != 'shutdown') {
      throw const ApplianceException(
        'A ponte Samsung foi encerrada.',
        code: 'bridge_closed',
      );
    }
    final process = await _ensureStarted();
    final id = ++_nextRequestId;
    final completer = Completer<Map<String, Object?>>();
    _pending[id] = completer;
    try {
      process.stdin.writeln(
        jsonEncode({'id': id, 'method': method, 'params': params}),
      );
    } on Object catch (error) {
      _pending.remove(id);
      throw ApplianceException(
        'Não foi possível enviar uma solicitação à ponte Samsung: $error',
        code: 'bridge_io',
      );
    }
    try {
      final response = await completer.future.timeout(
        timeout ?? requestTimeout,
        onTimeout: () {
          _pending.remove(id);
          unawaited(_terminateAfterTimeout());
          throw const ApplianceException(
            'A ponte Samsung excedeu o tempo limite e foi encerrada.',
            code: 'timeout',
          );
        },
      );
      if (response['ok'] != true) {
        final error = _asObject(response['error']);
        throw ApplianceException(
          error['message'] as String? ?? 'A operação OCF falhou.',
          code: error['code'] as String? ?? 'ocf_error',
        );
      }
      return response['data'];
    } finally {
      _pending.remove(id);
    }
  }

  Future<Process> _ensureStarted() {
    if (_closed) {
      throw const ApplianceException(
        'A ponte Samsung foi encerrada.',
        code: 'bridge_closed',
      );
    }
    final running = _process;
    if (running != null) return Future.value(running);
    final starting = _starting;
    if (starting != null) return starting;
    final future =
        Process.start(bridgeExecutable, [
              '--data-dir',
              dataDirectory.path,
            ], runInShell: false)
            .then((process) {
              _process = process;
              process.stdout
                  .transform(utf8.decoder)
                  .transform(const LineSplitter())
                  .listen(
                    (line) => _handleLine(process, line),
                    onError: (Object error) =>
                        _onProcessFailure(process, error),
                  );
              // Native diagnostics never go to stdout and are intentionally discarded
              // so certificates and wire data cannot leak into app logs.
              process.stderr.drain<void>();
              unawaited(
                process.exitCode.then((code) => _onProcessExit(process, code)),
              );
              return process;
            })
            .catchError((Object error) {
              throw ApplianceException(
                'Não foi possível iniciar a ponte local em "$bridgeExecutable": $error',
                code: 'bridge_start_failed',
              );
            })
            .whenComplete(() => _starting = null);
    _starting = future;
    return future;
  }

  void _handleLine(Process process, String line) {
    if (!identical(process, _process)) return;
    try {
      final response = _asObject(jsonDecode(line));
      final id = response['id'];
      if (id is! int) return;
      final completer = _pending[id];
      if (completer != null && !completer.isCompleted) {
        completer.complete(response);
      }
    } on Object {
      _onProcessFailure(
        process,
        const FormatException('Resposta JSON inválida da ponte.'),
      );
    }
  }

  void _onProcessExit(Process process, int exitCode) {
    if (!identical(process, _process)) return;
    _process = null;
    _failPending(
      ApplianceException(
        'A ponte Samsung foi encerrada (código $exitCode).',
        code: 'bridge_exited',
      ),
    );
  }

  void _onProcessFailure(Process process, Object error) {
    if (!identical(process, _process)) return;
    process.kill();
    _process = null;
    _failPending(
      ApplianceException(
        'A comunicação com a ponte Samsung foi interrompida.',
        code: 'bridge_io',
      ),
    );
  }

  void _failPending(ApplianceException error) {
    for (final completer in _pending.values) {
      if (!completer.isCompleted) completer.completeError(error);
    }
    _pending.clear();
  }

  Future<void> _terminateAfterTimeout() async {
    final process = _process;
    _process = null;
    process?.kill();
    _failPending(
      const ApplianceException(
        'A ponte Samsung excedeu o tempo limite.',
        code: 'timeout',
      ),
    );
  }

  static ApplianceDevice _deviceFromJson(Map<String, Object?> json) =>
      ApplianceDevice(
        id: json['id'] as String,
        host: json['host'] as String,
        name: json['name'] as String?,
        model: json['model'] as String?,
        port: json['port'] as int?,
      );

  static ApplianceSnapshot _snapshotFromJson(Object? value) {
    final json = _asObject(value);
    final raw = _asObject(json['rawValues']);
    return ApplianceSnapshot(
      power: json['power'] as bool?,
      temperature: (json['temperature'] as num?)?.toDouble(),
      ambientTemperature: (json['ambientTemperature'] as num?)?.toDouble(),
      mode: _modeFromOcf(json['mode'] as String?),
      fanSpeed: _fanFromOcf(json['fanSpeed'] as String?),
      windFree: json['windFree'] as bool?,
      rawValues: raw,
    );
  }

  static ApplianceCapabilities _capabilitiesFromJson(
    Map<String, Object?> json,
  ) {
    final temperature = json['temperature'] is Map<String, Object?>
        ? _asObject(json['temperature'])
        : const <String, Object?>{};
    final rawModes = _stringList(json['modes']);
    final rawFanSpeeds = _stringList(json['fanSpeeds']);
    final resources = _asObject(json['rawResources']);
    return ApplianceCapabilities(
      power: json['power'] as bool?,
      temperature: temperature.isEmpty
          ? null
          : TemperatureLimits(
              available: temperature['available'] as bool?,
              minimum: (temperature['minimum'] as num?)?.toDouble(),
              maximum: (temperature['maximum'] as num?)?.toDouble(),
              step: (temperature['step'] as num?)?.toDouble(),
            ),
      modes: rawModes.map(_modeFromOcf).whereType<AcMode>().toList(),
      fanSpeeds: rawFanSpeeds.map(_fanFromOcf).whereType<FanSpeed>().toList(),
      windFree: json['windFree'] as bool?,
      rawModes: rawModes,
      rawFanSpeeds: rawFanSpeeds,
      rawResources: resources,
    );
  }

  static AcMode? _modeFromOcf(String? value) => switch (value) {
    'Cool' || 'cool' => AcMode.cool,
    'Dry' || 'dry' => AcMode.dry,
    'Wind' || 'wind' || 'Fan' || 'fan' => AcMode.fan,
    'Auto' || 'auto' => AcMode.auto,
    'Heat' || 'heat' => AcMode.heat,
    _ => null,
  };

  static FanSpeed? _fanFromOcf(String? value) => switch (value) {
    '0' || 'auto' => FanSpeed.auto,
    '1' || 'low' => FanSpeed.low,
    '2' || 'medium' => FanSpeed.medium,
    '3' || 'high' => FanSpeed.high,
    '4' || 'turbo' => FanSpeed.turbo,
    _ => null,
  };

  static List<String> _stringList(Object? value) => value is List<Object?>
      ? value.whereType<String>().toList(growable: false)
      : const [];

  static Map<String, Object?> _asObject(Object? value) =>
      value is Map<String, Object?> ? value : const {};
}
