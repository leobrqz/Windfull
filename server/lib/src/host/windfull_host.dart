import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

import '../appliance/appliance_models.dart';
import '../appliance/appliance_repository.dart';
import '../appliance/samsung_ocf_repository.dart';
import '../network/host_secret_store.dart';
import '../network/host_settings_store.dart';
import '../network/server_identity.dart';
import '../network/windfull_network_server.dart';
import '../ui/host_controller.dart';

class WindfullHost extends WindfullHostController {
  WindfullHost({
    ApplianceRepository? applianceRepository,
    HostSecretStore? secretStore,
    HostSettingsStore? settingsStore,
    Directory? dataDirectory,
    InternetAddress? bindAddress,
    this._httpsPort = 47657,
    this._discoveryPort = 47656,
    this._enableDiscovery = true,
    this._autoDiscover = true,
    this._bridgeExecutable,
    this.applianceRefreshInterval = const Duration(seconds: 20),
    this.requestBodyTimeout = const Duration(seconds: 10),
  }) : _injectedApplianceRepository = applianceRepository,
       _secretStore = secretStore ?? FlutterHostSecretStore(),
       _injectedSettingsStore = settingsStore,
       _providedDataDirectory = dataDirectory,
       _bindAddress = bindAddress ?? InternetAddress.anyIPv4;

  static const _pairedStorageKey = 'windfull.paired_devices.v1';
  static const _maxJsonBodyBytes = 8192;
  static const _maximumPendingPairings = 10;
  static const _pairingLifetime = Duration(minutes: 3);
  static const _expiredPairingRetention = Duration(minutes: 1);
  final ApplianceRepository? _injectedApplianceRepository;
  final HostSecretStore _secretStore;
  final HostSettingsStore? _injectedSettingsStore;
  final Directory? _providedDataDirectory;
  final InternetAddress _bindAddress;
  final int _httpsPort;
  final int _discoveryPort;
  final bool _enableDiscovery;
  final bool _autoDiscover;
  final String? _bridgeExecutable;
  final Duration applianceRefreshInterval;
  final Duration requestBodyTimeout;

  Directory? _dataDirectory;
  HostSettingsStore? _settingsStore;
  ApplianceRepository? _applianceRepository;
  ServerIdentity? _identity;
  WindfullNetworkServer? _networkServer;
  Timer? _expiryTimer;
  Timer? _applianceRefreshTimer;
  Timer? _applianceReconnectTimer;
  Future<void> _lifecycleQueue = Future<void>.value();
  bool _storageInitialized = false;
  bool _applianceBackgroundStarted = false;
  bool _isShuttingDown = false;
  bool _disposed = false;
  bool _discoveryBusy = false;
  bool _refreshBusy = false;
  int _reconnectAttempt = 0;
  int _consecutiveApplianceFailures = 0;

  HostStatus _hostStatus = HostStatus.stopped;
  String? _serverError;
  ApplianceConnectionStatus _applianceConnection =
      ApplianceConnectionStatus.unknown;
  String? _applianceError;
  List<String> _localAddresses = const [];
  int? _boundPort;
  String? _selectedApplianceId;
  String? _configuredApplianceName;
  String? _configuredApplianceHost;
  int? _configuredAppliancePort;
  ApplianceDevice? _applianceDevice;
  ApplianceSnapshot? _applianceSnapshot;
  ApplianceCapabilities? _applianceCapabilities;
  List<DiscoveredAppliance> _discoveredAppliances = const [];
  bool _hasSearchedForAppliances = false;
  String? _discoveryError;
  final Map<String, _PairingRequest> _pairingRequests = {};
  Map<String, _PairedDeviceRecord> _pairedRecords = {};
  final Set<String> _revokingClientIds = {};
  final Set<String> _busyActions = {};

  Future<void> _applianceQueue = Future<void>.value();
  Future<void> _pairStorageQueue = Future<void>.value();
  final Map<String, int> _busyActionCounts = {};

  @override
  HostViewState get state => HostViewState(
    status: _hostStatus,
    serverError: _serverError,
    localAddresses: List.unmodifiable(_localAddresses),
    serverPort: _boundPort,
    certificateFingerprint: _identity?.fingerprint,
    isDiscovering: _discoveryBusy,
    hasSearchedForAppliances: _hasSearchedForAppliances,
    discoveredAppliances: List.unmodifiable(_discoveredAppliances),
    discoveryError: _discoveryError,
    selectedApplianceId: _selectedApplianceId,
    applianceConnection: _applianceConnection,
    applianceError: _applianceError,
    appliance: _toUiAppliance(),
    pendingPairings: List.unmodifiable(_pendingUiRequests()),
    pairedDevices: List.unmodifiable(
      _pairedRecords.values.map((record) => record.toUiDevice()),
    ),
    busyActions: Set.unmodifiable(_busyActions),
  );

  int? get boundDiscoveryPort => _networkServer?.boundDiscoveryPort;

  @override
  Future<void> start() => _withLifecycleLock(_start);

  Future<void> _start() async {
    if (_networkServer != null || _hostStatus == HostStatus.starting) return;
    _isShuttingDown = false;
    _hostStatus = HostStatus.starting;
    _serverError = null;
    _notifyListeners();
    try {
      await _initializeStorageAndRepository();
      if (!_storageInitialized) {
        _identity = await ServerIdentity.loadOrCreate(_secretStore);
        await _loadPairedDevices();
        await _loadSettings();
        _storageInitialized = true;
      }
      final identity = _identity!;

      final server = WindfullNetworkServer(
        identity: identity,
        onRequest: _handleHttpRequest,
        bindAddress: _bindAddress,
        httpsPort: _httpsPort,
        discoveryPort: _discoveryPort,
        enableDiscovery: _enableDiscovery,
        onNetworkError: _onNetworkError,
      );
      await server.start();
      _networkServer = server;
      _boundPort = server.boundHttpsPort;
      _localAddresses = await _readLocalAddresses();
      _hostStatus = HostStatus.ready;
      _serverError = null;
      _notifyListeners();
      _expiryTimer = Timer.periodic(
        const Duration(seconds: 5),
        (_) => unawaited(_expirePairings()),
      );
      _startApplianceMonitor();
      if (!_applianceBackgroundStarted) {
        _applianceBackgroundStarted = true;
        unawaited(_initializeApplianceInBackground());
      }
    } on Object catch (error) {
      await _networkServer?.stop();
      _networkServer = null;
      _hostStatus = HostStatus.error;
      _serverError = _errorMessage(error);
      _notifyListeners();
    }
  }

  @override
  Future<void> retryServer() => _withLifecycleLock(() async {
    if (_isShuttingDown) return;
    _expiryTimer?.cancel();
    _expiryTimer = null;
    _applianceRefreshTimer?.cancel();
    _applianceRefreshTimer = null;
    _applianceReconnectTimer?.cancel();
    _applianceReconnectTimer = null;
    await _networkServer?.stop();
    _networkServer = null;
    _hostStatus = HostStatus.stopped;
    await _start();
  });

  @override
  Future<void> shutdown() => _withLifecycleLock(_shutdown);

  Future<void> _shutdown() async {
    if (_isShuttingDown) return;
    _isShuttingDown = true;
    _expiryTimer?.cancel();
    _expiryTimer = null;
    _applianceRefreshTimer?.cancel();
    _applianceRefreshTimer = null;
    _applianceReconnectTimer?.cancel();
    _applianceReconnectTimer = null;
    await _networkServer?.stop();
    _networkServer = null;
    final repository = _applianceRepository;
    if (repository != null) {
      try {
        await _withApplianceLock(() async {
          if (repository is SamsungOcfRepository) {
            await repository.dispose();
            if (_injectedApplianceRepository == null) {
              _applianceRepository = null;
            }
          } else {
            await repository.disconnect();
          }
        });
      } on Object {
        // Shutdown still closes network listeners if an appliance is offline.
      }
    }
    _applianceDevice = null;
    _applianceSnapshot = null;
    _applianceCapabilities = null;
    _boundPort = null;
    _hostStatus = HostStatus.stopped;
    _applianceConnection = ApplianceConnectionStatus.unknown;
    _serverError = null;
    _applianceBackgroundStarted = false;
    _notifyListeners();
  }

  @override
  Future<void> discoverAppliances() async {
    final repository = _applianceRepository;
    if (repository == null) {
      _discoveryError =
          'O repositório de aparelhos ainda não foi inicializado.';
      _notifyListeners();
      return;
    }
    if (_discoveryBusy) return;
    _discoveryBusy = true;
    _discoveryError = null;
    _discoveredAppliances = const [];
    _notifyListeners();
    try {
      await _withApplianceLock(() async {
        await for (final devices in repository.discover()) {
          _discoveredAppliances = devices
              .map(_toDiscoveredAppliance)
              .toList(growable: false);
          _notifyListeners();
        }
      });
      _hasSearchedForAppliances = true;
    } on Object catch (error) {
      _discoveryError = _errorMessage(error);
    } finally {
      _discoveryBusy = false;
      _notifyListeners();
    }
  }

  @override
  Future<void> selectAppliance(String applianceId) async {
    final candidate = _discoveredAppliances
        .where((device) => device.id == applianceId)
        .firstOrNull;
    if (candidate == null) {
      throw const HostActionException(
        'O aparelho selecionado não está mais na lista de descoberta.',
      );
    }
    await _selectAndConnect(
      candidate.host,
      name: candidate.name,
      applianceId: candidate.id,
    );
  }

  @override
  Future<void> configureApplianceManually({
    required String host,
    String? name,
  }) async {
    final target = host.trim();
    if (InternetAddress.tryParse(target) == null) {
      throw const HostActionException(
        'Informe um endereço IP válido do ar-condicionado.',
        statusCode: HttpStatus.badRequest,
        code: 'invalid_address',
      );
    }
    await _selectAndConnect(
      target,
      name: name?.trim().isEmpty == true ? null : name?.trim(),
    );
  }

  @override
  Future<void> setPower(bool enabled) => _runApplianceCommand(
    actionId: 'power',
    validate: (capabilities) => capabilities.power == true,
    operation: (repository) => repository.setPower(enabled),
  );

  @override
  Future<void> setTargetTemperature(double temperature) => _runApplianceCommand(
    actionId: 'temperature',
    validate: (capabilities) => _supportsTemperature(capabilities, temperature),
    unsupportedMessage:
        'Temperatura fora dos limites ou passo não informado pelo aparelho.',
    operation: (repository) => repository.setTemperature(temperature),
  );

  @override
  Future<void> setOperatingMode(String mode) {
    final value = _modeFromString(mode);
    return _runApplianceCommand(
      actionId: 'mode',
      validate: (capabilities) =>
          value != null && capabilities.modes.contains(value),
      unsupportedMessage:
          'Esse modo não é informado como disponível pelo aparelho.',
      operation: (repository) => repository.setMode(value!),
    );
  }

  @override
  Future<void> setFanSpeed(String speed) {
    final value = _fanSpeedFromString(speed);
    return _runApplianceCommand(
      actionId: 'fanSpeed',
      validate: (capabilities) =>
          value != null && capabilities.fanSpeeds.contains(value),
      unsupportedMessage:
          'Essa velocidade não é informada como disponível pelo aparelho.',
      operation: (repository) => repository.setFanSpeed(value!),
    );
  }

  @override
  Future<void> setFeature(String featureId, bool enabled) {
    if (featureId.toLowerCase() != 'windfree') {
      throw const HostActionException(
        'Recurso não reconhecido.',
        statusCode: HttpStatus.unprocessableEntity,
        code: 'unsupported_capability',
      );
    }
    return _runApplianceCommand(
      actionId: 'windFree',
      validate: (capabilities) => capabilities.windFree == true,
      unsupportedMessage:
          'WindFree não está informado como disponível pelo aparelho.',
      operation: (repository) => repository.setWindFree(enabled),
    );
  }

  @override
  Future<void> approvePairingRequest(String requestId) async {
    await _withBusyAction('pairing.$requestId', () async {
      await _withPairStorageLock(() async {
        final request = _pairingRequests[requestId];
        if (request == null || request.status != _PairingStatus.pending) {
          throw const HostActionException(
            'Esta solicita\u00e7\u00e3o de pareamento n\u00e3o est\u00e1 mais pendente.',
          );
        }
        if (!DateTime.now().isBefore(request.expiresAt)) {
          request.status = _PairingStatus.expired;
          _notifyListeners();
          throw const HostActionException('O pedido de pareamento expirou.');
        }
        final record = _PairedDeviceRecord(
          id: request.clientId,
          name: request.clientName,
          description: request.deviceDescription,
          secretHash: request.secretHash,
          pairedAt: DateTime.now(),
          lastSeenAt: null,
        );
        final updated = Map<String, _PairedDeviceRecord>.of(_pairedRecords)
          ..[record.id] = record;
        final replacesCredential =
            _pairedRecords.containsKey(record.id) &&
            !_constantTimeEquals(
              _pairedRecords[record.id]!.secretHash,
              record.secretHash,
            );
        if (replacesCredential) _revokingClientIds.add(record.id);
        try {
          await _writePairedDevices(updated);
          _pairedRecords = updated;
          request.status = _PairingStatus.approved;
          _serverError = null;
        } finally {
          if (replacesCredential) _revokingClientIds.remove(record.id);
        }
      });
    });
  }

  @override
  Future<void> rejectPairingRequest(String requestId) async {
    await _withBusyAction('pairing.$requestId', () async {
      await _withPairStorageLock(() async {
        final request = _pairingRequests[requestId];
        if (request == null || request.status != _PairingStatus.pending) {
          throw const HostActionException(
            'Esta solicita\u00e7\u00e3o de pareamento n\u00e3o est\u00e1 mais pendente.',
          );
        }
        request.status = DateTime.now().isBefore(request.expiresAt)
            ? _PairingStatus.rejected
            : _PairingStatus.expired;
        _serverError = null;
      });
    });
  }

  @override
  Future<void> revokePairedDevice(String deviceId) async {
    await _withBusyAction('revoke.$deviceId', () async {
      await _withPairStorageLock(() async {
        if (!_pairedRecords.containsKey(deviceId)) {
          throw const HostActionException(
            'O dispositivo n\u00e3o est\u00e1 pareado.',
          );
        }
        _revokingClientIds.add(deviceId);
        final updated = Map<String, _PairedDeviceRecord>.of(_pairedRecords)
          ..remove(deviceId);
        await _writePairedDevices(updated);
        _pairedRecords = updated;
        _revokingClientIds.remove(deviceId);
      });
    });
  }

  Future<void> _initializeStorageAndRepository() async {
    if (_dataDirectory == null) {
      final supportDirectory =
          _providedDataDirectory ?? await getApplicationSupportDirectory();
      _dataDirectory = Directory(
        '${supportDirectory.path}${Platform.pathSeparator}Windfull',
      );
      await _dataDirectory!.create(recursive: true);
    }
    _settingsStore ??=
        _injectedSettingsStore ??
        FileHostSettingsStore(directory: _dataDirectory!);
    _applianceRepository ??=
        _injectedApplianceRepository ??
        SamsungOcfRepository(
          bridgeExecutable: _bridgeExecutable ?? _defaultBridgeExecutable(),
          dataDirectory: _dataDirectory!,
        );
  }

  String _defaultBridgeExecutable() {
    final executableDirectory = File(Platform.resolvedExecutable).parent.path;
    return '$executableDirectory${Platform.pathSeparator}windfull-samsung-ocf.exe';
  }

  Future<void> _loadSettings() async {
    final values = await _settingsStore!.read();
    if (values == null) return;
    final host = values['applianceHost'];
    final name = values['applianceName'];
    final port = values['appliancePort'];
    if (host != null &&
        (host is! String || InternetAddress.tryParse(host) == null)) {
      throw const HostStorageException(
        'O endereço do ar-condicionado salvo é inválido.',
      );
    }
    if (name != null && name is! String) {
      throw const HostStorageException(
        'O nome do ar-condicionado salvo é inválido.',
      );
    }
    if (port != null && (port is! int || port < 1 || port > 65535)) {
      throw const HostStorageException(
        'A porta do ar-condicionado salva é inválida.',
      );
    }
    _configuredApplianceHost = host as String?;
    _configuredApplianceName = name as String?;
    _configuredAppliancePort = port as int?;
    _selectedApplianceId = values['applianceId'] as String?;
  }

  Future<void> _saveApplianceSettings({
    required String host,
    String? name,
    String? applianceId,
    int? port,
  }) async {
    await _settingsStore!.write({
      'applianceHost': host,
      'applianceName': name,
      'applianceId': applianceId,
      'appliancePort': port,
    });
    _configuredApplianceHost = host;
    _configuredApplianceName = name;
    _selectedApplianceId = applianceId;
    _configuredAppliancePort = port;
  }

  Future<void> _initializeApplianceInBackground() async {
    final host = _configuredApplianceHost;
    if (host != null) {
      try {
        await _connectAppliance(
          host,
          name: _configuredApplianceName,
          applianceId: _selectedApplianceId,
          port: _configuredAppliancePort,
        );
      } on Object {
        // A missing/offline unit does not prevent the local pairing server from starting.
      }
    }
    if (_autoDiscover && !_isShuttingDown) {
      await discoverAppliances();
    }
  }

  void _startApplianceMonitor() {
    _applianceRefreshTimer?.cancel();
    _applianceRefreshTimer = Timer.periodic(
      applianceRefreshInterval,
      (_) => unawaited(_monitorAppliance()),
    );
  }

  Future<void> _monitorAppliance() async {
    if (_isShuttingDown || _refreshBusy || _discoveryBusy) return;
    if (_configuredApplianceHost == null) return;
    if (_busyActions.contains('appliance.connect') ||
        _busyActions.contains('appliance.reconnect')) {
      return;
    }
    if (_applianceConnection != ApplianceConnectionStatus.connected ||
        _applianceDevice == null) {
      _scheduleReconnect();
      return;
    }
    if (_busyActions.any(_isApplianceMutationBusy)) return;

    final repository = _applianceRepository;
    if (repository == null) return;
    _refreshBusy = true;
    _busyActions.add('appliance.refresh');
    _notifyListeners();
    try {
      await _withApplianceLock(_readApplianceStateLocked);
    } on Object catch (error) {
      _consecutiveApplianceFailures++;
      if (_consecutiveApplianceFailures >= 2) {
        _applianceConnection = ApplianceConnectionStatus.error;
        _applianceError = _errorMessage(error);
        _scheduleReconnect();
      }
    } finally {
      _busyActions.remove('appliance.refresh');
      _refreshBusy = false;
      _notifyListeners();
    }
  }

  bool _isApplianceMutationBusy(String action) =>
      const {
        'power',
        'temperature',
        'mode',
        'fanSpeed',
        'windFree',
      }.contains(action) ||
      action == 'appliance.connect' ||
      action == 'appliance.reconnect';

  void _scheduleReconnect() {
    if (_isShuttingDown ||
        _applianceReconnectTimer != null ||
        _configuredApplianceHost == null) {
      return;
    }
    final seconds = min(60, 2 * (1 << min(_reconnectAttempt, 5)));
    _reconnectAttempt = min(_reconnectAttempt + 1, 6);
    _applianceReconnectTimer = Timer(Duration(seconds: seconds), () {
      _applianceReconnectTimer = null;
      unawaited(_attemptApplianceReconnect());
    });
  }

  Future<void> _attemptApplianceReconnect() async {
    if (_isShuttingDown || _configuredApplianceHost == null) return;
    if (_discoveryBusy || _busyActions.any(_isApplianceMutationBusy)) {
      _scheduleReconnect();
      return;
    }
    final repository = _applianceRepository;
    if (repository == null) return;
    _busyActions.add('appliance.reconnect');
    _notifyListeners();
    try {
      await _withApplianceLock(() async {
        final persistentId = _selectedApplianceId;
        DiscoveredAppliance? matchingDevice;
        if (persistentId != null) {
          try {
            await for (final devices in repository.discover(
              timeout: const Duration(seconds: 4),
            )) {
              _discoveredAppliances = devices
                  .map(_toDiscoveredAppliance)
                  .toList(growable: false);
              matchingDevice = _discoveredAppliances
                  .where((device) => device.id == persistentId)
                  .firstOrNull;
              if (matchingDevice != null) break;
            }
            _hasSearchedForAppliances = true;
          } on Object {
            // Keep the saved host as a fallback if discovery is unavailable.
          }
        }

        final host = matchingDevice?.host ?? _configuredApplianceHost!;
        final port = matchingDevice == null ? _configuredAppliancePort : null;
        await repository.disconnect();
        final connectedDevice = await repository.connect(host, port: port);
        if (persistentId != null && connectedDevice.id != persistentId) {
          await repository.disconnect();
          throw const HostActionException(
            'O endereço salvo respondeu com uma identidade diferente; o vínculo não foi alterado.',
            code: 'appliance_identity_mismatch',
          );
        }
        _applianceDevice = connectedDevice;
        _selectedApplianceId = connectedDevice.id;
        _configuredApplianceHost = connectedDevice.host;
        _configuredAppliancePort = connectedDevice.port ?? port;
        await _saveApplianceSettings(
          host: connectedDevice.host,
          name: _configuredApplianceName,
          applianceId: connectedDevice.id,
          port: _configuredAppliancePort,
        );
        await _readApplianceStateLocked();
      });
      _reconnectAttempt = 0;
    } on Object catch (error) {
      _applianceConnection = ApplianceConnectionStatus.error;
      _applianceError = _errorMessage(error);
      _scheduleReconnect();
    } finally {
      _busyActions.remove('appliance.reconnect');
      _notifyListeners();
    }
  }

  Future<void> _selectAndConnect(
    String host, {
    String? name,
    String? applianceId,
  }) async {
    await _saveApplianceSettings(
      host: host,
      name: name,
      applianceId: applianceId,
    );
    await _connectAppliance(host, name: name, applianceId: applianceId);
  }

  Future<void> _connectAppliance(
    String host, {
    String? name,
    String? applianceId,
    int? port,
  }) async {
    final repository = _applianceRepository;
    if (repository == null) {
      throw const HostActionException(
        'O repositório do aparelho não está disponível.',
      );
    }
    _busyActions.add('appliance.connect');
    _applianceConnection = ApplianceConnectionStatus.disconnected;
    _applianceError = null;
    _notifyListeners();
    try {
      await _withApplianceLock(() async {
        await repository.disconnect();
        final connectedDevice = await repository.connect(host, port: port);
        if (applianceId != null && connectedDevice.id != applianceId) {
          await repository.disconnect();
          throw const HostActionException(
            'O aparelho respondeu com uma identidade diferente da selecionada.',
            statusCode: HttpStatus.conflict,
            code: 'appliance_identity_mismatch',
          );
        }
        _applianceDevice = connectedDevice;
        _selectedApplianceId = connectedDevice.id;
        _configuredApplianceHost = connectedDevice.host;
        _configuredApplianceName = name;
        _configuredAppliancePort = connectedDevice.port ?? port;
        await _saveApplianceSettings(
          host: connectedDevice.host,
          name: name,
          applianceId: connectedDevice.id,
          port: connectedDevice.port ?? port,
        );
        await _readApplianceStateLocked();
      });
      _reconnectAttempt = 0;
    } on Object catch (error) {
      _applianceDevice = null;
      _applianceSnapshot = null;
      _applianceCapabilities = null;
      _applianceConnection = ApplianceConnectionStatus.error;
      _applianceError = _errorMessage(error);
      _scheduleReconnect();
      _notifyListeners();
      rethrow;
    } finally {
      _busyActions.remove('appliance.connect');
      _notifyListeners();
    }
  }

  Future<void> _readApplianceStateLocked() async {
    final repository = _applianceRepository!;
    final capabilities = await repository.readCapabilities();
    final snapshot = await repository.readState();
    _applianceCapabilities = capabilities;
    _applianceSnapshot = snapshot;
    _applianceConnection = ApplianceConnectionStatus.connected;
    _applianceError = null;
    _consecutiveApplianceFailures = 0;
  }

  Future<void> _runApplianceCommand({
    required String actionId,
    required bool Function(ApplianceCapabilities capabilities) validate,
    required Future<ApplianceSnapshot> Function(ApplianceRepository repository)
    operation,
    String? unsupportedMessage,
  }) async {
    final repository = _applianceRepository;
    if (repository == null ||
        _applianceConnection != ApplianceConnectionStatus.connected ||
        _applianceDevice == null) {
      throw const HostActionException('O ar-condicionado não está conectado.');
    }
    _busyActions.add(actionId);
    _applianceError = null;
    _notifyListeners();
    try {
      await _withApplianceLock(() async {
        final capabilities = _applianceCapabilities;
        if (capabilities == null || !validate(capabilities)) {
          throw HostActionException(
            unsupportedMessage ??
                'O aparelho não informa suporte a este controle.',
            statusCode: HttpStatus.unprocessableEntity,
            code: 'unsupported_capability',
          );
        }
        _applianceSnapshot = await operation(repository);
        _applianceConnection = ApplianceConnectionStatus.connected;
        _applianceError = null;
        _consecutiveApplianceFailures = 0;
      });
    } on Object catch (error) {
      if (error is ApplianceException) {
        _consecutiveApplianceFailures++;
        if (_consecutiveApplianceFailures >= 2) {
          _applianceConnection = ApplianceConnectionStatus.error;
          _applianceError = _errorMessage(error);
          _scheduleReconnect();
        } else {
          _applianceError = null;
        }
      } else {
        _applianceError = _errorMessage(error);
      }
      _notifyListeners();
      rethrow;
    } finally {
      _busyActions.remove(actionId);
      _notifyListeners();
    }
  }

  Future<T> _withApplianceLock<T>(Future<T> Function() operation) async {
    final released = Completer<void>();
    final previous = _applianceQueue;
    _applianceQueue = released.future;
    await previous;
    try {
      return await operation();
    } finally {
      released.complete();
    }
  }

  Future<T> _withPairStorageLock<T>(Future<T> Function() operation) async {
    final released = Completer<void>();
    final previous = _pairStorageQueue;
    _pairStorageQueue = released.future;
    await previous;
    try {
      return await operation();
    } finally {
      released.complete();
    }
  }

  Future<T> _withLifecycleLock<T>(Future<T> Function() operation) async {
    final released = Completer<void>();
    final previous = _lifecycleQueue;
    _lifecycleQueue = released.future;
    await previous;
    try {
      return await operation();
    } finally {
      released.complete();
    }
  }

  Future<T> _withBusyAction<T>(
    String actionId,
    Future<T> Function() operation,
  ) async {
    _busyActionCounts.update(actionId, (count) => count + 1, ifAbsent: () => 1);
    _busyActions.add(actionId);
    _notifyListeners();
    try {
      return await operation();
    } finally {
      final count = _busyActionCounts[actionId] ?? 0;
      if (count <= 1) {
        _busyActionCounts.remove(actionId);
        _busyActions.remove(actionId);
      } else {
        _busyActionCounts[actionId] = count - 1;
      }
      _notifyListeners();
    }
  }

  bool _supportsTemperature(ApplianceCapabilities capabilities, double value) {
    final limits = capabilities.temperature;
    if (limits == null || limits.available != true || !value.isFinite) {
      return false;
    }
    final min = limits.minimum;
    final max = limits.maximum;
    final step = limits.step;
    if (min == null ||
        max == null ||
        step == null ||
        !min.isFinite ||
        !max.isFinite ||
        !step.isFinite ||
        step <= 0 ||
        max < min ||
        value < min ||
        value > max) {
      return false;
    }
    return (((value - min) / step) - ((value - min) / step).round()).abs() <
        0.000001;
  }

  ApplianceState? _toUiAppliance() {
    final device = _applianceDevice;
    if (device == null) return null;
    final capabilities = _applianceCapabilities;
    final snapshot = _applianceSnapshot;
    final limits = capabilities?.temperature;
    return ApplianceState(
      id: device.id,
      name:
          _configuredApplianceName ??
          device.name ??
          device.model ??
          'Ar-condicionado',
      host: device.host,
      isPoweredOn: snapshot?.power,
      targetTemperature: snapshot?.temperature,
      roomTemperature: snapshot?.ambientTemperature,
      minimumTemperature: limits?.minimum,
      maximumTemperature: limits?.maximum,
      temperatureStep: limits?.step,
      mode: _modeToString(snapshot?.mode),
      supportedModes: List.unmodifiable(
        (capabilities?.modes ?? const <AcMode>[])
            .where((mode) => mode != AcMode.unknown)
            .map((mode) => mode.name),
      ),
      fanSpeed: _fanSpeedToString(snapshot?.fanSpeed),
      fanSpeeds: List.unmodifiable(
        (capabilities?.fanSpeeds ?? const <FanSpeed>[])
            .where((speed) => speed != FanSpeed.unknown)
            .map((speed) => speed.name),
      ),
      features: capabilities?.windFree == true
          ? {
              'windFree': ApplianceFeatureState(
                label: 'WindFree',
                enabled: snapshot?.windFree ?? false,
              ),
            }
          : const {},
    );
  }

  DiscoveredAppliance _toDiscoveredAppliance(ApplianceDevice device) =>
      DiscoveredAppliance(
        id: device.id,
        name: device.name ?? device.model ?? 'Ar-condicionado',
        host: device.host,
        isReachable: true,
      );

  List<PendingPairingRequest> _pendingUiRequests() => _pairingRequests.values
      .where(
        (request) =>
            request.status == _PairingStatus.pending &&
            DateTime.now().isBefore(request.expiresAt),
      )
      .map(
        (request) => PendingPairingRequest(
          id: request.id,
          deviceName: request.clientName,
          deviceDescription: request.deviceDescription,
          verificationCode: request.verificationCode,
          expiresAt: request.expiresAt,
        ),
      )
      .toList(growable: false);

  Future<void> _loadPairedDevices() async {
    final stored = await _secretStore.read(_pairedStorageKey);
    if (stored == null) {
      _pairedRecords = {};
      return;
    }
    try {
      final decoded = jsonDecode(stored);
      if (decoded is! List) {
        throw const FormatException(
          'Formato de dispositivos pareados inválido.',
        );
      }
      final records = <String, _PairedDeviceRecord>{};
      for (final value in decoded) {
        if (value is! Map<String, dynamic>) {
          throw const FormatException('Registro de dispositivo inválido.');
        }
        final record = _PairedDeviceRecord.fromJson(value);
        if (records.containsKey(record.id)) {
          throw const FormatException('ID de dispositivo duplicado.');
        }
        records[record.id] = record;
      }
      _pairedRecords = records;
    } on Object catch (error) {
      throw HostStorageException(
        'Os dispositivos pareados salvos estão inválidos; nenhum dado foi apagado: $error',
      );
    }
  }

  Future<void> _writePairedDevices(Map<String, _PairedDeviceRecord> records) =>
      _secretStore.write(
        _pairedStorageKey,
        jsonEncode(records.values.map((record) => record.toJson()).toList()),
      );

  Future<void> _expirePairings() async {
    await _withPairStorageLock(() async {
      final now = DateTime.now();
      var changed = false;
      _pairingRequests.removeWhere((_, request) {
        if (request.status == _PairingStatus.pending &&
            !now.isBefore(request.expiresAt)) {
          request.status = _PairingStatus.expired;
          changed = true;
        }
        final expiredLongAgo = now.isAfter(
          request.expiresAt.add(_expiredPairingRetention),
        );
        if (expiredLongAgo) changed = true;
        return expiredLongAgo;
      });
      if (changed) _notifyListeners();
    });
  }

  Future<void> _handleHttpRequest(HttpRequest request) async {
    request.response.headers
      ..set(HttpHeaders.cacheControlHeader, 'no-store')
      ..set('X-Content-Type-Options', 'nosniff');
    if (request.headers.value('origin') != null) {
      await _writeError(
        request.response,
        HttpStatus.forbidden,
        'web_origin_rejected',
        'A API local não aceita solicitações de páginas web.',
      );
      return;
    }
    final path = request.uri.path;
    if (request.method == 'POST' && path == '/v1/pairings') {
      await _handlePairingCreate(request);
      return;
    }
    final pairingMatch = RegExp(
      r'^/v1/pairings/([0-9a-f]{32})$',
    ).firstMatch(path);
    if (request.method == 'GET' && pairingMatch != null) {
      await _handlePairingStatus(request, pairingMatch.group(1)!);
      return;
    }
    if (request.method == 'GET' && path == '/v1/state') {
      if (!await _authorize(request)) return;
      await _handleState(request);
      return;
    }
    if (request.method == 'POST' && path == '/v1/commands') {
      if (!await _authorize(request)) return;
      await _handleCommand(request);
      return;
    }
    if (request.method != 'GET' && request.method != 'POST') {
      request.response.headers.set(HttpHeaders.allowHeader, 'GET, POST');
      await _writeError(
        request.response,
        HttpStatus.methodNotAllowed,
        'method_not_allowed',
        'Método HTTP não permitido.',
      );
      return;
    }
    await _writeError(
      request.response,
      HttpStatus.notFound,
      'not_found',
      'Rota não encontrada.',
    );
  }

  Future<void> _handlePairingCreate(HttpRequest request) async {
    final body = await _readJsonBody(request);
    if (body == null) return;
    final requestId = body['requestId'];
    final clientId = body['clientId'];
    final secret = body['secret'];
    final clientName = body['clientName'];
    if (requestId is! String ||
        !RegExp(r'^[0-9a-f]{32}$').hasMatch(requestId) ||
        clientId is! String ||
        !RegExp(r'^[0-9a-f]{32}$').hasMatch(clientId) ||
        secret is! String ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(secret) ||
        clientName is! String ||
        clientName.trim().isEmpty ||
        clientName.length > 120) {
      await _writeError(
        request.response,
        HttpStatus.badRequest,
        'invalid_pairing_request',
        'Dados de pareamento inválidos.',
      );
      return;
    }
    final sanitizedName = _sanitizeClientName(clientName);
    final secretHash = sha256.convert(utf8.encode(secret)).toString();
    final existing = _pairingRequests[requestId];
    if (existing != null) {
      if (existing.clientId != clientId ||
          !_constantTimeEquals(existing.secretHash, secretHash)) {
        await _writeError(
          request.response,
          HttpStatus.conflict,
          'request_id_conflict',
          'O identificador de solicitação já está em uso.',
        );
        return;
      }
      await _writeJson(request.response, HttpStatus.accepted, {
        'status': existing.status.apiValue,
      });
      return;
    }
    final pendingCount = _pairingRequests.values
        .where(
          (entry) =>
              entry.status == _PairingStatus.pending &&
              DateTime.now().isBefore(entry.expiresAt),
        )
        .length;
    if (pendingCount >= _maximumPendingPairings) {
      await _writeError(
        request.response,
        HttpStatus.tooManyRequests,
        'too_many_pairing_requests',
        'O computador já tem solicitações pendentes demais.',
      );
      return;
    }
    final identity = _identity;
    if (identity == null) {
      await _writeError(
        request.response,
        HttpStatus.serviceUnavailable,
        'server_not_ready',
        'O servidor ainda não está pronto.',
      );
      return;
    }
    final now = DateTime.now();
    final entry = _PairingRequest(
      id: requestId,
      clientId: clientId,
      clientName: sanitizedName,
      deviceDescription: null,
      secretHash: secretHash,
      verificationCode: _pairingCode(requestId, identity.fingerprint),
      createdAt: now,
      expiresAt: now.add(_pairingLifetime),
    );
    _pairingRequests[requestId] = entry;
    _serverError = null;
    _notifyListeners();
    await _writeJson(request.response, HttpStatus.accepted, {
      'status': 'pending',
    });
  }

  Future<void> _handlePairingStatus(
    HttpRequest request,
    String requestId,
  ) async {
    if (!await _authorize(
      request,
      allowPendingPairing: true,
      pairingRequestId: requestId,
    )) {
      return;
    }
    final status = await _withPairStorageLock(() async {
      final pairing = _pairingRequests[requestId];
      if (pairing == null) return null;
      if (pairing.status == _PairingStatus.pending &&
          !DateTime.now().isBefore(pairing.expiresAt)) {
        pairing.status = _PairingStatus.expired;
        _notifyListeners();
      }
      return pairing.status;
    });
    if (status == null) {
      await _writeError(
        request.response,
        HttpStatus.notFound,
        'pairing_not_found',
        'Solicitação de pareamento não encontrada ou expirada.',
      );
      return;
    }
    await _writeJson(request.response, HttpStatus.ok, {
      'status': status.apiValue,
    });
  }

  Future<bool> _authorize(
    HttpRequest request, {
    bool allowPendingPairing = false,
    String? pairingRequestId,
  }) async {
    final clientId = request.headers.value('X-Windfull-Client');
    final authorization = request.headers.value(
      HttpHeaders.authorizationHeader,
    );
    if (clientId == null ||
        !RegExp(r'^[0-9a-f]{32}$').hasMatch(clientId) ||
        authorization == null ||
        !authorization.startsWith('Bearer ')) {
      await _writeError(
        request.response,
        HttpStatus.unauthorized,
        'unauthorized',
        'Credencial inválida ou dispositivo revogado.',
      );
      return false;
    }
    final secret = authorization.substring(7);
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(secret)) {
      await _writeError(
        request.response,
        HttpStatus.unauthorized,
        'unauthorized',
        'Credencial inválida ou dispositivo revogado.',
      );
      return false;
    }
    final secretHash = sha256.convert(utf8.encode(secret)).toString();
    if (allowPendingPairing && pairingRequestId != null) {
      final pending = _pairingRequests[pairingRequestId];
      if (pending != null &&
          pending.clientId == clientId &&
          _constantTimeEquals(pending.secretHash, secretHash)) {
        return true;
      }
    } else {
      final paired = _pairedRecords[clientId];
      if (!_revokingClientIds.contains(clientId) &&
          paired != null &&
          _constantTimeEquals(paired.secretHash, secretHash)) {
        return true;
      }
    }
    await _writeError(
      request.response,
      HttpStatus.unauthorized,
      'unauthorized',
      'Credencial inválida ou dispositivo revogado.',
    );
    return false;
  }

  Future<void> _handleState(HttpRequest request) async {
    // Android polls frequently so its controls stay responsive. Serve the most
    // recent snapshot instead of issuing an OCF/DTLS exchange for every poll;
    // the host monitor refreshes this cache independently.
    final connected =
        _applianceRepository != null &&
        _applianceDevice != null &&
        _applianceConnection == ApplianceConnectionStatus.connected;
    await _writeJson(
      request.response,
      HttpStatus.ok,
      _apiState(
        connected: connected,
        error: connected ? null : _applianceError,
      ),
    );
  }

  Future<void> _handleCommand(HttpRequest request) async {
    final body = await _readJsonBody(request);
    if (body == null) return;
    final type = body['type'];
    final value = body['value'];
    if (type is! String || !body.containsKey('value')) {
      await _writeError(
        request.response,
        HttpStatus.badRequest,
        'invalid_command',
        'Comando inválido.',
      );
      return;
    }
    try {
      switch (type) {
        case 'power':
          if (value is! bool) {
            throw const HostApiException(
              HttpStatus.badRequest,
              'invalid_value',
              'O valor de energia deve ser booleano.',
            );
          }
          await setPower(value);
        case 'temperature':
          if (value is! num || !value.toDouble().isFinite) {
            throw const HostApiException(
              HttpStatus.badRequest,
              'invalid_value',
              'A temperatura deve ser um número finito.',
            );
          }
          await setTargetTemperature(value.toDouble());
        case 'mode':
          if (value is! String) {
            throw const HostApiException(
              HttpStatus.badRequest,
              'invalid_value',
              'O modo deve ser texto.',
            );
          }
          await setOperatingMode(value);
        case 'fanSpeed':
          if (value is! String) {
            throw const HostApiException(
              HttpStatus.badRequest,
              'invalid_value',
              'A velocidade deve ser texto.',
            );
          }
          await setFanSpeed(value);
        case 'windFree':
          if (value is! bool) {
            throw const HostApiException(
              HttpStatus.badRequest,
              'invalid_value',
              'O valor de WindFree deve ser booleano.',
            );
          }
          await setFeature('windFree', value);
        default:
          throw const HostApiException(
            HttpStatus.badRequest,
            'unsupported_command',
            'Comando não reconhecido.',
          );
      }
      await _writeJson(
        request.response,
        HttpStatus.ok,
        _apiState(connected: true),
      );
    } on HostApiException catch (error) {
      await _writeError(
        request.response,
        error.statusCode,
        error.code,
        error.message,
      );
    } on HostActionException catch (error) {
      await _writeError(
        request.response,
        error.statusCode,
        error.code,
        error.message,
      );
    } on Object catch (error) {
      await _writeError(
        request.response,
        HttpStatus.badGateway,
        'appliance_command_failed',
        _errorMessage(error),
      );
    }
  }

  Future<Map<String, dynamic>?> _readJsonBody(HttpRequest request) async {
    if (request.headers.contentType?.mimeType.toLowerCase() !=
        'application/json') {
      await _writeError(
        request.response,
        HttpStatus.unsupportedMediaType,
        'content_type_required',
        'Envie o corpo como application/json.',
      );
      return null;
    }
    late final List<int> bodyBytes;
    try {
      bodyBytes = await _readBoundedRequestBody(request);
    } on HostApiException catch (error) {
      await _writeError(
        request.response,
        error.statusCode,
        error.code,
        error.message,
      );
      return null;
    } on TimeoutException {
      await _writeError(
        request.response,
        HttpStatus.requestTimeout,
        'request_body_timeout',
        'O corpo da solicitação não foi recebido dentro do prazo.',
      );
      return null;
    }
    try {
      final decoded = jsonDecode(utf8.decode(bodyBytes));
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('O JSON deve ser um objeto.');
      }
      return decoded;
    } on Object {
      await _writeError(
        request.response,
        HttpStatus.badRequest,
        'invalid_json',
        'O corpo JSON está malformado.',
      );
      return null;
    }
  }

  Future<List<int>> _readBoundedRequestBody(HttpRequest request) {
    final completer = Completer<List<int>>();
    final bytes = BytesBuilder(copy: false);
    var tooLarge = false;
    var timedOut = false;
    late StreamSubscription<List<int>> subscription;
    final timer = Timer(requestBodyTimeout, () {
      if (!completer.isCompleted) {
        timedOut = true;
        completer.completeError(TimeoutException('HTTP body timeout'));
      }
    });
    subscription = request.listen(
      (chunk) {
        if (tooLarge) return;
        if (bytes.length + chunk.length > _maxJsonBodyBytes) {
          tooLarge = true;
        } else {
          bytes.add(chunk);
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        if (!completer.isCompleted) {
          completer.completeError(error, stackTrace);
        }
      },
      onDone: () {
        if (completer.isCompleted) return;
        if (tooLarge) {
          completer.completeError(
            const HostApiException(
              413,
              'body_too_large',
              'O corpo da solicitação excede o limite permitido.',
            ),
          );
        } else {
          completer.complete(bytes.takeBytes());
        }
      },
      cancelOnError: true,
    );
    return completer.future.whenComplete(() async {
      timer.cancel();
      // Canceling an HttpRequest stream closes its connection immediately,
      // which prevents the 408 response from reaching the slow client.
      if (!timedOut) await subscription.cancel();
    });
  }

  Future<void> _writeJson(
    HttpResponse response,
    int status,
    Object? value,
  ) async {
    response
      ..statusCode = status
      ..headers.contentType = ContentType.json
      ..write(jsonEncode(value));
    await response.close();
  }

  Future<void> _writeError(
    HttpResponse response,
    int status,
    String code,
    String message,
  ) {
    response.persistentConnection = false;
    return _writeJson(response, status, {
      'error': {'code': code, 'message': message},
    });
  }

  Map<String, Object?> _apiState({required bool connected, String? error}) {
    final device = connected ? _applianceDevice : null;
    final snapshot = connected ? _applianceSnapshot : null;
    final capabilities = connected ? _applianceCapabilities : null;
    final limits = capabilities?.temperature;
    final temperatureCapability =
        limits != null &&
            limits.available == true &&
            limits.minimum != null &&
            limits.maximum != null &&
            limits.step != null &&
            limits.minimum!.isFinite &&
            limits.maximum!.isFinite &&
            limits.step!.isFinite &&
            limits.step! > 0 &&
            limits.maximum! >= limits.minimum!
        ? <String, Object?>{
            'min': limits.minimum,
            'max': limits.maximum,
            'step': limits.step,
          }
        : null;
    return {
      'connected': connected,
      'device': device == null
          ? null
          : {
              'id': device.id,
              'name':
                  _configuredApplianceName ??
                  device.name ??
                  device.model ??
                  'Ar-condicionado',
              'host': device.host,
              'model': device.model,
            },
      'state': snapshot == null
          ? null
          : {
              'power': snapshot.power,
              'temperature': snapshot.temperature,
              'ambientTemperature': snapshot.ambientTemperature,
              'mode': _modeToString(snapshot.mode),
              'fanSpeed': _fanSpeedToString(snapshot.fanSpeed),
              'windFree': snapshot.windFree,
            },
      'capabilities': {
        'power': capabilities?.power == true,
        'temperature': temperatureCapability,
        'modes': (capabilities?.modes ?? const <AcMode>[])
            .where((mode) => mode != AcMode.unknown)
            .map((mode) => mode.name)
            .toList(growable: false),
        'fanSpeeds': (capabilities?.fanSpeeds ?? const <FanSpeed>[])
            .where((speed) => speed != FanSpeed.unknown)
            .map((speed) => speed.name)
            .toList(growable: false),
        'windFree': capabilities?.windFree == true,
      },
      'error': error ?? _applianceError,
    };
  }

  String _pairingCode(String requestId, String fingerprint) {
    final bytes = sha256
        .convert(utf8.encode('windfull-pair-v1:$requestId:$fingerprint'))
        .bytes;
    final number =
        ((bytes[0] << 24) | (bytes[1] << 16) | (bytes[2] << 8) | bytes[3]) %
        1000000;
    return number.toString().padLeft(6, '0');
  }

  String _sanitizeClientName(String raw) {
    final sanitized = String.fromCharCodes(
      raw.runes.where((rune) => rune >= 32 && rune != 127),
    ).trim();
    if (sanitized.isEmpty) return 'Dispositivo Android';
    final runes = sanitized.runes.take(80).toList(growable: false);
    return String.fromCharCodes(runes);
  }

  bool _constantTimeEquals(String left, String right) {
    var difference = left.length ^ right.length;
    final count = max(left.length, right.length);
    for (var index = 0; index < count; index++) {
      final a = index < left.length ? left.codeUnitAt(index) : 0;
      final b = index < right.length ? right.codeUnitAt(index) : 0;
      difference |= a ^ b;
    }
    return difference == 0;
  }

  String? _modeToString(AcMode? mode) =>
      mode == null || mode == AcMode.unknown ? null : mode.name;
  String? _fanSpeedToString(FanSpeed? speed) =>
      speed == null || speed == FanSpeed.unknown ? null : speed.name;

  AcMode? _modeFromString(String value) {
    for (final mode in AcMode.values) {
      if (mode.name == value && mode != AcMode.unknown) return mode;
    }
    return null;
  }

  FanSpeed? _fanSpeedFromString(String value) {
    for (final speed in FanSpeed.values) {
      if (speed.name == value && speed != FanSpeed.unknown) return speed;
    }
    return null;
  }

  Future<List<String>> _readLocalAddresses() async {
    if (_bindAddress != InternetAddress.anyIPv4 && !_bindAddress.isLoopback) {
      return [_bindAddress.address];
    }
    if (_bindAddress.isLoopback) return [_bindAddress.address];
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: false,
      includeLinkLocal: false,
    );
    final addresses = <String>{};
    for (final interface in interfaces) {
      for (final address in interface.addresses) {
        if (address.type == InternetAddressType.IPv4 && !address.isLoopback) {
          addresses.add(address.address);
        }
      }
    }
    final sorted = addresses.toList()..sort();
    return sorted;
  }

  void _onNetworkError(Object error) {
    if (_isShuttingDown) return;
    _serverError = _errorMessage(error);
    _notifyListeners();
  }

  void _notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  String _errorMessage(Object error) =>
      error.toString().replaceFirst(RegExp(r'^Exception: '), '');

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _isShuttingDown = true;
    _expiryTimer?.cancel();
    _applianceRefreshTimer?.cancel();
    _applianceReconnectTimer?.cancel();
    final networkServer = _networkServer;
    _networkServer = null;
    unawaited(() async {
      await networkServer?.stop();
      final repository = _applianceRepository;
      if (repository == null) return;
      try {
        await _withApplianceLock(() async {
          if (repository is SamsungOcfRepository) {
            await repository.dispose();
          } else {
            await repository.disconnect();
          }
        });
      } on Object {
        // Disposal is best effort; explicit shutdown reports through state.
      }
    }());
    super.dispose();
  }
}

class _PairingRequest {
  _PairingRequest({
    required this.id,
    required this.clientId,
    required this.clientName,
    required this.deviceDescription,
    required this.secretHash,
    required this.verificationCode,
    required this.createdAt,
    required this.expiresAt,
  });

  final String id;
  final String clientId;
  final String clientName;
  final String? deviceDescription;
  final String secretHash;
  final String verificationCode;
  final DateTime createdAt;
  final DateTime expiresAt;
  _PairingStatus status = _PairingStatus.pending;
}

enum _PairingStatus {
  pending,
  approved,
  rejected,
  expired;

  String get apiValue => name;
}

class _PairedDeviceRecord {
  const _PairedDeviceRecord({
    required this.id,
    required this.name,
    required this.secretHash,
    required this.pairedAt,
    this.description,
    this.lastSeenAt,
  });

  final String id;
  final String name;
  final String? description;
  final String secretHash;
  final DateTime pairedAt;
  final DateTime? lastSeenAt;

  PairedDevice toUiDevice() => PairedDevice(
    id: id,
    name: name,
    description: description,
    pairedAt: pairedAt,
    lastSeenAt: lastSeenAt,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'description': description,
    'secretHash': secretHash,
    'pairedAt': pairedAt.toIso8601String(),
    'lastSeenAt': lastSeenAt?.toIso8601String(),
  };

  factory _PairedDeviceRecord.fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final name = json['name'];
    final secretHash = json['secretHash'];
    final pairedAt = json['pairedAt'];
    final description = json['description'];
    final lastSeenAt = json['lastSeenAt'];
    if (id is! String ||
        !RegExp(r'^[0-9a-f]{32}$').hasMatch(id) ||
        name is! String ||
        name.isEmpty ||
        secretHash is! String ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(secretHash) ||
        pairedAt is! String ||
        description != null && description is! String ||
        lastSeenAt != null && lastSeenAt is! String) {
      throw const FormatException('Campos de dispositivo pareado inválidos.');
    }
    return _PairedDeviceRecord(
      id: id,
      name: name,
      description: description as String?,
      secretHash: secretHash,
      pairedAt: DateTime.parse(pairedAt),
      lastSeenAt: lastSeenAt == null
          ? null
          : DateTime.parse(lastSeenAt as String),
    );
  }
}

class HostActionException implements Exception {
  const HostActionException(
    this.message, {
    this.statusCode = HttpStatus.serviceUnavailable,
    this.code = 'appliance_unavailable',
  });

  final String message;
  final int statusCode;
  final String code;
  @override
  String toString() => message;
}

class HostStorageException implements Exception {
  const HostStorageException(this.message);
  final String message;
  @override
  String toString() => message;
}

class HostApiException implements Exception {
  const HostApiException(this.statusCode, this.code, this.message);
  final int statusCode;
  final String code;
  final String message;
}
