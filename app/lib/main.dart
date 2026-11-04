import 'dart:async';

import 'package:flutter/material.dart';
import 'package:device_info_plus/device_info_plus.dart';

import 'data/pairing_store.dart';
import 'data/pairing_client_name.dart';
import 'data/windfull_client.dart';
import 'updates/android_update_controller.dart';
import 'updates/android_updates_sheet.dart';
import 'ui/windfull_brand_mark.dart';
import 'ui/windfull_palette.dart';

void main() => runApp(const WindfullApp());

class WindfullApp extends StatelessWidget {
  const WindfullApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'WindFull',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: const ColorScheme.dark(
        primary: WindfullPalette.accent,
        onPrimary: WindfullPalette.canvas,
        secondary: WindfullPalette.accent,
        onSecondary: WindfullPalette.canvas,
        surface: WindfullPalette.surface,
        onSurface: WindfullPalette.text,
        error: Color(0xFFE7978C),
        onError: WindfullPalette.canvas,
      ),
      scaffoldBackgroundColor: WindfullPalette.canvas,
      textTheme: const TextTheme(
        bodyLarge: TextStyle(color: WindfullPalette.text),
        bodyMedium: TextStyle(color: WindfullPalette.muted),
        bodySmall: TextStyle(color: WindfullPalette.muted),
        titleLarge: TextStyle(color: WindfullPalette.text),
        titleMedium: TextStyle(color: WindfullPalette.text),
      ),
      iconTheme: const IconThemeData(color: WindfullPalette.muted),
      dividerTheme: const DividerThemeData(color: WindfullPalette.border),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: WindfullPalette.raised,
        hintStyle: const TextStyle(color: WindfullPalette.muted),
        prefixIconColor: WindfullPalette.muted,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: WindfullPalette.accent),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: WindfullPalette.accent,
          foregroundColor: WindfullPalette.canvas,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(15),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(foregroundColor: WindfullPalette.accent),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? WindfullPalette.canvas
              : WindfullPalette.muted,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? WindfullPalette.accent
              : WindfullPalette.raised,
        ),
      ),
      dialogTheme: const DialogThemeData(
        backgroundColor: WindfullPalette.surface,
        surfaceTintColor: Colors.transparent,
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: WindfullPalette.surface,
        surfaceTintColor: Colors.transparent,
        showDragHandle: true,
        dragHandleColor: WindfullPalette.muted,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: WindfullPalette.raised,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: WindfullPalette.raised,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
    ),
    home: const RemoteHomePage(),
  );
}

class RemoteHomePage extends StatefulWidget {
  const RemoteHomePage({super.key});

  @override
  State<RemoteHomePage> createState() => _RemoteHomePageState();
}

class _RemoteHomePageState extends State<RemoteHomePage> {
  final _client = WindfullClient();
  final _pairingStore = PairingStore();
  final _updates = AndroidUpdateController();
  PairingCredential? _credential;
  List<DiscoveredServer> _servers = const [];
  Map<String, dynamic>? _snapshot;
  String? _connectionError;
  String? _deviceError;
  bool _busy = false;
  bool _refreshing = false;
  DateTime _lastRediscovery = DateTime.fromMillisecondsSinceEpoch(0);
  int _consecutiveServerFailures = 0;
  Timer? _pollTimer;
  StreamSubscription<Map<String, dynamic>>? _stateSubscription;
  bool _eventsConnected = false;
  int _eventGeneration = 0;

  @override
  void initState() {
    super.initState();
    _restore();
    _discover();
    unawaited(_updates.initialize());
    _pollTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) {
        if (!_eventsConnected) _refreshState();
      },
    );
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    unawaited(_stateSubscription?.cancel());
    _updates.dispose();
    super.dispose();
  }

  Future<void> _restore() async {
    final credential = await _pairingStore.read();
    if (mounted) setState(() => _credential = credential);
    if (credential != null) {
      _startStateEvents(credential);
      _refreshState();
    }
  }

  void _startStateEvents(PairingCredential credential) {
    final generation = ++_eventGeneration;
    unawaited(_stateSubscription?.cancel());
    _eventsConnected = false;
    _stateSubscription = _client
        .watchState(
          credential,
          onConnectionChanged: (connected) {
            if (!mounted ||
                generation != _eventGeneration ||
                _eventsConnected == connected) {
              return;
            }
            setState(() => _eventsConnected = connected);
          },
        )
        .listen(
          _acceptSnapshot,
          onError: (Object error) {
            if (error is WindfullUnauthorizedException) {
              unawaited(_clearRevokedCredential(error));
            }
          },
          cancelOnError: true,
        );
  }

  void _acceptSnapshot(Map<String, dynamic> value) {
    if (!mounted) return;
    setState(() {
      _snapshot = value;
      _connectionError = null;
      _deviceError = value['error'] as String?;
      _consecutiveServerFailures = 0;
    });
  }

  Future<void> _clearRevokedCredential(WindfullUnauthorizedException error) async {
    await _pairingStore.clear();
    ++_eventGeneration;
    unawaited(_stateSubscription?.cancel());
    if (!mounted) return;
    setState(() {
      _credential = null;
      _snapshot = null;
      _connectionError = error.message;
      _deviceError = null;
      _eventsConnected = false;
    });
  }

  Future<void> _refreshState() async {
    final credential = _credential;
    if (credential == null || _busy || _refreshing) return;
    _refreshing = true;
    try {
      final value = await _client.getState(credential);
      if (!mounted) return;
      setState(() {
        _snapshot = value;
        _connectionError = null;
        _deviceError = value['error'] as String?;
        _consecutiveServerFailures = 0;
      });
    } on WindfullUnauthorizedException catch (error) {
      await _clearRevokedCredential(error);
    } on Object {
      _consecutiveServerFailures++;
      if (_consecutiveServerFailures < 2) return;
      if (mounted) {
        setState(() {
          _connectionError =
              'Servidor sem resposta. Tentando localizar novamente...';
          _deviceError = null;
        });
      }
      if (DateTime.now().difference(_lastRediscovery) >=
          const Duration(seconds: 10)) {
        _lastRediscovery = DateTime.now();
        DiscoveredServer? moved;
        try {
          moved = await _client.rediscover(credential);
        } on Object {
          // Keep controls disabled and retry after the rediscovery interval.
        }
        if (moved != null &&
            (moved.host != credential.host || moved.port != credential.port)) {
          final updated = PairingCredential(
            serverId: credential.serverId,
            host: moved.host,
            port: moved.port,
            clientId: credential.clientId,
            secret: credential.secret,
            fingerprint: credential.fingerprint,
          );
          await _pairingStore.save(updated);
          if (mounted) {
            setState(() {
              _credential = updated;
              _connectionError = null;
            });
            _startStateEvents(updated);
          }
        }
      }
    } finally {
      _refreshing = false;
    }
  }

  Future<void> _discover() async {
    if (mounted) {
      setState(() {
        _busy = true;
        if (_credential == null) _connectionError = null;
      });
    }
    try {
      final servers = await _client.discover();
      if (!mounted) return;
      final saved = _credential;
      setState(() {
        _servers = servers
            .where(
              (server) =>
                  saved == null ||
                  server.id != saved.serverId ||
                  server.fingerprint == saved.fingerprint,
            )
            .toList();
      });
      if (servers.isEmpty) {
        if (_credential == null) {
          setState(
            () => _connectionError =
                'Nenhum computador encontrado nesta rede. Confira se o WindFull est\u00e1 aberto no PC.',
          );
        }
        return;
      }
    } on Object catch (error) {
      if (mounted) setState(() => _connectionError = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _connectByIp() async {
    final address = await showDialog<String>(
      context: context,
      builder: (context) => const _ManualIpDialog(),
    );
    final ip = address?.trim();
    if (ip == null || ip.isEmpty || !mounted) return;
    setState(() {
      _busy = true;
      _connectionError = null;
    });
    try {
      final servers = await _client.discover(targetIp: ip);
      final pinned = _credential == null
          ? null
          : _client.matchPinnedServer(_credential!, servers);
      final saved = _credential;
      final visible = servers
          .where(
            (server) =>
                saved == null ||
                server.id != saved.serverId ||
                server.fingerprint == saved.fingerprint,
          )
          .toList();
      if (pinned != null &&
          saved != null &&
          (pinned.host != saved.host || pinned.port != saved.port)) {
        final moved = PairingCredential(
          serverId: saved.serverId,
          host: pinned.host,
          port: pinned.port,
          clientId: saved.clientId,
          secret: saved.secret,
          fingerprint: saved.fingerprint,
        );
        await _pairingStore.save(moved);
        if (mounted) {
          setState(() => _credential = moved);
          _startStateEvents(moved);
        }
      }
      if (!mounted) return;
      setState(() {
        _servers = visible;
        _connectionError = visible.isEmpty
            ? servers.isEmpty
                  ? 'Nenhum WindFull respondeu em $ip na porta ${WindfullClient.discoveryPort}.'
                  : 'A identidade do servidor mudou. O fingerprint salvo n\u00e3o confere; n\u00e3o pareie antes de verificar o PC.'
            : null;
      });
    } on Object catch (error) {
      if (mounted) setState(() => _connectionError = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _unlink() async {
    await _pairingStore.clear();
    ++_eventGeneration;
    unawaited(_stateSubscription?.cancel());
    _eventsConnected = false;
    if (!mounted) return;
    setState(() {
      _credential = null;
      _snapshot = null;
      _connectionError = null;
      _deviceError = null;
    });
    Navigator.pop(context);
  }

  Future<void> _pair(DiscoveredServer server) async {
    setState(() => _busy = true);
    try {
      final session = await _client.requestPairing(
        server,
        clientName: await _pairingClientName(),
      );
      if (!mounted) return;
      final confirmed = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (context) => AlertDialog(
          title: const Text('Compare os c\u00f3digos'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'No computador "${server.name}", aprove o celular somente se o c\u00f3digo abaixo for igual:',
              ),
              const SizedBox(height: 18),
              Center(
                child: Text(
                  session.comparisonCode,
                  style: const TextStyle(
                    fontSize: 30,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 4,
                  ),
                ),
              ),
              const SizedBox(height: 14),
              const Text(
                'O WindFull s\u00f3 guarda a credencial depois da aprova\u00e7\u00e3o. Se os c\u00f3digos forem diferentes, cancele.',
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancelar'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Os c\u00f3digos conferem'),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
      if (mounted) {
        setState(
          () => _connectionError =
              'Pedido enviado. Aguardando aprova\u00e7\u00e3o no computador...',
        );
      }
      final deadline = DateTime.now().add(const Duration(minutes: 3));
      var status = 'pending';
      while (status == 'pending' && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(seconds: 2));
        status = await _client.pairingStatus(session);
      }
      if (status != 'approved') {
        throw WindfullException(
          status == 'rejected'
              ? 'O pareamento foi recusado no computador.'
              : 'O pedido de pareamento expirou. Tente novamente.',
        );
      }
      final credential = _client.credentialFor(session);
      await _pairingStore.save(credential);
      if (!mounted) return;
      setState(() {
        _credential = credential;
        _connectionError = null;
        _deviceError = null;
      });
      _startStateEvents(credential);
      await _refreshState();
    } on Object catch (error) {
      if (mounted) setState(() => _connectionError = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<String> _pairingClientName() async {
    try {
      final info = await DeviceInfoPlugin().androidInfo;
      return buildPairingClientName(
        manufacturer: info.manufacturer,
        model: info.model,
      );
    } on Object {
      return 'Celular Android';
    }
  }

  Map<String, dynamic> get _deviceState =>
      (_snapshot?['state'] as Map?)?.cast<String, dynamic>() ?? const {};
  Map<String, dynamic> get _capabilities =>
      (_snapshot?['capabilities'] as Map?)?.cast<String, dynamic>() ?? const {};
  bool get _online =>
      _credential != null &&
      _snapshot?['connected'] == true &&
      _connectionError == null &&
      _deviceError == null;

  List<Widget> _buildControls() {
    final result = <Widget>[];
    final state = _deviceState;
    final caps = _capabilities;
    final mode = state['mode']?.toString();
    final normalizedMode = mode?.toLowerCase().replaceAll(
      RegExp(r'[^a-z]'),
      '',
    );
    final purifierMode = const {
      'purify',
      'purifier',
      'airpurify',
      'airpurifier',
      'purification',
    }.contains(normalizedMode);
    final fanOnlyMode =
        purifierMode || const {'fan', 'wind'}.contains(normalizedMode);
    void add(Widget widget) {
      if (result.isNotEmpty) result.add(const SizedBox(height: 10));
      result.add(widget);
    }

    final telemetry = <Widget>[];
    final ambient = state['ambientTemperature'];
    final humidity = state['humidity'];
    if (ambient is num && ambient.toDouble().isFinite) {
      telemetry.add(
        _TelemetryValue(
          icon: Icons.thermostat_rounded,
          label: 'Ambiente',
          value: '${ambient.toStringAsFixed(1).replaceAll('.0', '')}°',
        ),
      );
    }
    if (humidity is num && humidity.toDouble().isFinite) {
      telemetry.add(
        _TelemetryValue(
          icon: Icons.water_drop_outlined,
          label: 'Umidade',
          value: '${humidity.toStringAsFixed(0)}%',
        ),
      );
    }
    if (telemetry.isNotEmpty) add(_TelemetryPanel(values: telemetry));

    if (caps['power'] == true) {
      add(
        _ControlTile(
          icon: Icons.power_settings_new_rounded,
          title: 'Energia',
          subtitle: state['power'] == true
              ? 'Ligado'
              : state['power'] == false
              ? 'Desligado'
              : 'Estado desconhecido',
          trailing: Switch(
            value: state['power'] == true,
            onChanged: _online ? (value) => _sendCommand('power', value) : null,
          ),
        ),
      );
    }
    if (caps['temperature'] is Map) {
      final range = (caps['temperature'] as Map).cast<String, dynamic>();
      final minValue = range['min'];
      final maxValue = range['max'];
      final stepValue = range['step'];
      final min = minValue is num ? minValue.toDouble() : double.nan;
      final max = maxValue is num ? maxValue.toDouble() : double.nan;
      final step = stepValue is num ? stepValue.toDouble() : double.nan;
      final currentValue = state['temperature'];
      final current = currentValue is num && currentValue.toDouble().isFinite
          ? currentValue.toDouble()
          : null;
      if (!min.isFinite ||
          !max.isFinite ||
          !step.isFinite ||
          step <= 0 ||
          max < min) {
        add(
          const _ControlTile(
            icon: Icons.device_thermostat_rounded,
            title: 'Temperatura',
            subtitle:
                'Limites n\u00e3o informados corretamente pelo computador',
            trailing: SizedBox.shrink(),
          ),
        );
      } else {
        add(
          _ControlTile(
            icon: Icons.device_thermostat_rounded,
            title: 'Temperatura',
            subtitle: fanOnlyMode
                ? 'Indisponível no modo ${purifierMode ? 'Purificar' : 'Ventilar'}'
                : current == null
                ? 'Estado desconhecido - ${min.toStringAsFixed(0)}-${max.toStringAsFixed(0)} \u00b0C'
                : '${current.toStringAsFixed(1).replaceAll('.0', '')} \u00b0C${state['ambientTemperature'] is num && (state['ambientTemperature'] as num).toDouble().isFinite ? ' - ambiente ${(state['ambientTemperature'] as num).toStringAsFixed(1)} \u00b0C' : ''}',
            trailing: fanOnlyMode
                ? const SizedBox.shrink()
                : Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        onPressed:
                            _online && current != null && current - step >= min
                            ? () => _sendCommand('temperature', current - step)
                            : null,
                        icon: const Icon(Icons.remove_circle_outline),
                      ),
                      IconButton(
                        onPressed:
                            _online && current != null && current + step <= max
                            ? () => _sendCommand('temperature', current + step)
                            : null,
                        icon: const Icon(Icons.add_circle_outline),
                      ),
                    ],
                  ),
          ),
        );
      }
    }
    final modes =
        (caps['modes'] as List?)?.whereType<String>().toList() ??
        const <String>[];
    if (modes.isNotEmpty) {
      add(
        _choiceControl(
          'Modo',
          Icons.tune_rounded,
          modes,
          state['mode'] is String ? state['mode'] as String : null,
          'mode',
        ),
      );
    }
    final fanSpeeds =
        (caps['fanSpeeds'] as List?)?.whereType<String>().toList() ??
        const <String>[];
    if (fanSpeeds.isNotEmpty) {
      add(
        _choiceControl(
          'Ventilação',
          Icons.air_rounded,
          fanSpeeds,
          state['fanSpeed'] is String ? state['fanSpeed'] as String : null,
          'fanSpeed',
        ),
      );
    }
    if (caps['windFree'] == true) {
      add(
        _ControlTile(
          icon: Icons.air_rounded,
          title: 'WindFree',
          subtitle: state['windFree'] == true
              ? 'Ativado'
              : state['windFree'] == false
              ? 'Desativado'
              : 'Estado desconhecido',
          trailing: Switch(
            value: state['windFree'] == true,
            onChanged: _online
                ? (value) => _sendCommand('windFree', value)
                : null,
          ),
        ),
      );
    }
    if (result.isEmpty) {
      result.add(
        _ControlTile(
          icon: Icons.info_outline_rounded,
          title: 'Controles indispon\u00edveis',
          subtitle: _credential == null
              ? 'Pareie com o computador para ler as capacidades.'
              : 'O servidor ainda n\u00e3o anunciou capacidades control\u00e1veis.',
          trailing: const SizedBox.shrink(),
        ),
      );
    }
    return result;
  }

  Widget _choiceControl(
    String title,
    IconData icon,
    List<String> options,
    String? value,
    String type,
  ) => Material(
    color: WindfullPalette.surface,
    borderRadius: BorderRadius.circular(18),
    child: InkWell(
      borderRadius: BorderRadius.circular(18),
      onTap: _online
          ? () async {
              final selected = await showModalBottomSheet<String>(
                context: context,
                backgroundColor: Colors.transparent,
                showDragHandle: false,
                builder: (context) => _ChoiceSheet(
                  icon: icon,
                  title: title,
                  selected: value,
                  options: options,
                ),
              );
              if (selected != null) _sendCommand(type, selected);
            }
          : null,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 13, 10),
        child: Row(
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: WindfullPalette.raised,
                borderRadius: BorderRadius.circular(13),
              ),
              child: Icon(icon, color: WindfullPalette.accent, size: 20),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 12,
                      color: WindfullPalette.muted,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    value == null ? '—' : _displayOption(value),
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
            const Icon(
              Icons.keyboard_arrow_down_rounded,
              color: WindfullPalette.muted,
            ),
          ],
        ),
      ),
    ),
  );

  Future<void> _sendCommand(String type, Object value) async {
    final credential = _credential;
    if (credential == null || !_online) return;
    try {
      final response = await _client.command(credential, type, value);
      if (mounted) {
        setState(() {
          _snapshot = response;
          _connectionError = null;
          _deviceError = response['error'] as String?;
        });
      }
    } on Object catch (error) {
      if (mounted) {
        setState(() {
          _deviceError = error.toString();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      body: SafeArea(
        child: CustomScrollView(
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(22, 16, 22, 32),
              sliver: SliverList.list(
                children: [
                  Row(
                    children: [
                      const WindfullBrandMark(size: 42),
                      const SizedBox(width: 12),
                      const Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'WindFull',
                              style: TextStyle(
                                color: WindfullPalette.text,
                                fontWeight: FontWeight.w700,
                                fontSize: 19,
                              ),
                            ),
                            Text(
                              'Controle local do seu ar-condicionado',
                              style: TextStyle(
                                color: WindfullPalette.muted,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        tooltip: 'Configura\u00e7\u00f5es',
                        onPressed: () => _showSettings(context),
                        icon: const Icon(Icons.settings_outlined),
                      ),
                    ],
                  ),
                  const SizedBox(height: 28),
                  Container(
                    padding: const EdgeInsets.all(21),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(26),
                      gradient: const LinearGradient(
                        colors: [Color(0xFF1F4140), Color(0xFF142C2E)],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                      boxShadow: const [
                        BoxShadow(
                          color: Color(0x4210AAAA),
                          blurRadius: 30,
                          offset: Offset(0, 14),
                        ),
                      ],
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Container(
                              width: 9,
                              height: 9,
                              decoration: BoxDecoration(
                                color: _online
                                    ? WindfullPalette.accent
                                    : Color(0xFFF0BC70),
                                shape: BoxShape.circle,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              _credential == null
                                  ? 'SEM CONEX\u00c3O'
                                  : _connectionError != null
                                  ? 'PC SEM RESPOSTA'
                                  : _snapshot?['connected'] == true &&
                                        _deviceError == null
                                  ? 'PC E AR CONECTADOS'
                                  : _deviceError != null
                                  ? 'ERRO DO APARELHO'
                                  : _snapshot != null
                                  ? 'PC CONECTADO - AR OFFLINE'
                                  : 'CONECTANDO AO PC',
                              style: const TextStyle(
                                color: Color(0xFFD8E9E5),
                                letterSpacing: 1.1,
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const Spacer(),
                            Icon(
                              _credential == null
                                  ? Icons.wifi_off_rounded
                                  : Icons.wifi_rounded,
                              color: const Color(0xFFC0D9D2),
                              size: 19,
                            ),
                          ],
                        ),
                        const SizedBox(height: 27),
                        Text(
                          _snapshot?['device'] is Map
                              ? ((_snapshot!['device'] as Map)['name']
                                        as String? ??
                                    'WindFull conectado')
                              : 'Conecte seu computador',
                          style: TextStyle(
                            color: WindfullPalette.text,
                            fontSize: 24,
                            height: 1.1,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 9),
                        Text(
                          _credential == null
                              ? 'Conecte-se ao WindFull no computador para come\u00e7ar a controlar o aparelho.'
                              : (_connectionError ??
                                    _deviceError ??
                                    (_snapshot?['connected'] == false
                                        ? 'O computador respondeu, mas o aparelho est\u00e1 indispon\u00edvel.'
                                        : _snapshot?['device'] is Map
                                        ? '${(_snapshot!['device'] as Map)['model'] ?? 'Ar-condicionado'} - ${(_snapshot!['device'] as Map)['host'] ?? 'conectado localmente'}'
                                        : 'Servidor pareado. Aguardando o estado do aparelho.')),
                          style: TextStyle(
                            color: Color(0xFFD0E1DC),
                            fontSize: 14,
                            height: 1.45,
                          ),
                        ),
                        const SizedBox(height: 21),
                        SizedBox(
                          width: double.infinity,
                          child: FilledButton.icon(
                            onPressed: _busy ? null : _discover,
                            icon: const Icon(Icons.search_rounded, size: 19),
                            label: Text(
                              _busy
                                  ? 'Conectando...'
                                  : _credential == null
                                  ? 'Buscar computador na rede'
                                  : 'Adicionar outro computador',
                            ),
                            style: FilledButton.styleFrom(
                              foregroundColor: WindfullPalette.canvas,
                              backgroundColor: WindfullPalette.accent,
                              disabledBackgroundColor: WindfullPalette.accent,
                              disabledForegroundColor: WindfullPalette.canvas,
                              padding: const EdgeInsets.symmetric(vertical: 15),
                              textStyle: const TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ),
                        Center(
                          child: TextButton.icon(
                            onPressed: _busy ? null : _connectByIp,
                            icon: const Icon(
                              Icons.edit_location_alt_outlined,
                              size: 18,
                            ),
                            label: const Text('Inserir IP do computador'),
                            style: TextButton.styleFrom(
                              foregroundColor: WindfullPalette.accent,
                            ),
                          ),
                        ),
                        const SizedBox(height: 9),
                        Center(
                          child: Text(
                            _connectionError ??
                                (_credential == null
                                    ? 'A descoberta procura computadores WindFull nesta rede local.'
                                    : 'Credencial de pareamento protegida no armazenamento seguro do Android.'),
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 11,
                              color: Color(0xFFB8D2CB),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 25),
                  if (_servers.isNotEmpty) ...[
                    const Text(
                      'Computadores na rede',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 10),
                    ..._servers.map(
                      (server) => Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 11,
                          ),
                          decoration: BoxDecoration(
                            color: WindfullPalette.surface,
                            borderRadius: BorderRadius.circular(18),
                          ),
                          child: Row(
                            children: [
                              const Icon(
                                Icons.computer_rounded,
                                color: WindfullPalette.accent,
                              ),
                              const SizedBox(width: 11),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      server.name,
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                    Text(
                                      server.host,
                                      style: const TextStyle(
                                        color: WindfullPalette.muted,
                                        fontSize: 11,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              if (_credential?.serverId == server.id &&
                                  _credential?.fingerprint ==
                                      server.fingerprint)
                                const Text(
                                  'Pareado',
                                  style: TextStyle(
                                    color: WindfullPalette.accent,
                                    fontWeight: FontWeight.w700,
                                    fontSize: 12,
                                  ),
                                )
                              else
                                TextButton(
                                  onPressed: _busy ? null : () => _pair(server),
                                  child: const Text('Parear'),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                  ],
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Controles',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        _credential == null
                            ? 'AGUARDANDO PAREAMENTO'
                            : _connectionError != null
                            ? 'PC SEM RESPOSTA'
                            : _deviceError != null
                            ? 'ERRO DO APARELHO'
                            : (_snapshot?['connected'] == true
                                  ? 'ESTADO AO VIVO'
                                  : _snapshot != null
                                  ? 'AR OFFLINE'
                                  : 'AGUARDANDO ESTADO'),
                        style: TextStyle(
                          color: colors.primary,
                          letterSpacing: .7,
                          fontSize: 9,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  ..._buildControls(),
                  const SizedBox(height: 19),
                  Container(
                    padding: const EdgeInsets.all(15),
                    decoration: BoxDecoration(
                      color: WindfullPalette.surface,
                      borderRadius: BorderRadius.circular(18),
                    ),
                    child: const Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          Icons.lock_outline_rounded,
                          size: 19,
                          color: WindfullPalette.accent,
                        ),
                        SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            'Comunicação feita diretamente na rede local. O computador precisa aprovar o pareamento antes do primeiro uso.',
                            style: TextStyle(
                              color: WindfullPalette.muted,
                              fontSize: 12,
                              height: 1.45,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),
                  const Center(
                    child: Text(
                      'W I N D F U L L   \u2022   REDE LOCAL',
                      style: TextStyle(
                        color: WindfullPalette.muted,
                        fontSize: 9,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showSettings(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 30),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Configura\u00e7\u00f5es',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 14),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.computer_rounded),
                title: Text(_credential?.serverId ?? 'Nenhum servidor pareado'),
                subtitle: Text(
                  _credential == null
                      ? 'Nenhum v\u00ednculo salvo neste celular'
                      : '${_credential!.host}:${_credential!.port} - ${_snapshot?['connected'] == true ? 'conectado' : 'sem resposta'}',
                ),
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.system_update_alt_rounded),
                title: const Text('Atualizações'),
                subtitle: Text(_updateSummary),
                onTap: () {
                  Navigator.pop(context);
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (!mounted) return;
                    showModalBottomSheet<void>(
                      context: this.context,
                      isScrollControlled: true,
                      showDragHandle: true,
                      backgroundColor: WindfullPalette.canvas,
                      builder: (_) => AndroidUpdatesSheet(controller: _updates),
                    );
                  });
                },
              ),
              const ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.security_rounded),
                title: Text('Privacidade'),
                subtitle: Text(
                  'Comunica\u00e7\u00e3o restrita \u00e0 rede local',
                ),
              ),
              if (_credential != null)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(
                    Icons.link_off_rounded,
                    color: Color(0xFFE7978C),
                  ),
                  title: const Text('Desvincular este celular'),
                  subtitle: const Text(
                    'Apaga a credencial local; para reconectar, pareie novamente no PC.',
                  ),
                  onTap: _unlink,
                ),
            ],
          ),
        ),
      ),
    );
  }

  String get _updateSummary => switch (_updates.status) {
    AndroidUpdateStatus.checking => 'Verificando versões publicadas',
    AndroidUpdateStatus.available => 'Nova versão disponível',
    AndroidUpdateStatus.downloading => 'Baixando atualização',
    AndroidUpdateStatus.downloaded => 'Pronta para instalar',
    AndroidUpdateStatus.manualInstallRequired =>
      'Instalação inicial necessária',
    AndroidUpdateStatus.permissionRequired =>
      'Permissão de instalação necessária',
    AndroidUpdateStatus.installing => 'Aguardando confirmação do Android',
    AndroidUpdateStatus.failed => 'Não foi possível verificar atualizações',
    AndroidUpdateStatus.upToDate => 'WindFull atualizado',
    AndroidUpdateStatus.idle => 'Verifique a versão do aplicativo',
  };
}

class _ManualIpDialog extends StatefulWidget {
  const _ManualIpDialog();

  @override
  State<_ManualIpDialog> createState() => _ManualIpDialogState();
}

class _ManualIpDialogState extends State<_ManualIpDialog> {
  final _addressController = TextEditingController();

  @override
  void dispose() {
    _addressController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Conectar por IPv4'),
    content: TextField(
      controller: _addressController,
      autofocus: true,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      decoration: const InputDecoration(
        labelText: 'IP do computador',
        hintText: '192.168.1.20',
        border: OutlineInputBorder(),
      ),
      onSubmitted: (value) => Navigator.pop(context, value),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancelar'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(context, _addressController.text),
        child: const Text('Buscar'),
      ),
    ],
  );
}

class _TelemetryPanel extends StatelessWidget {
  const _TelemetryPanel({required this.values});

  final List<Widget> values;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: WindfullPalette.surface,
      borderRadius: BorderRadius.circular(18),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Row(
          children: [
            Icon(
              Icons.monitor_heart_outlined,
              size: 17,
              color: WindfullPalette.accent,
            ),
            SizedBox(width: 7),
            Text(
              'Ambiente',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Wrap(spacing: 8, runSpacing: 8, children: values),
      ],
    ),
  );
}

class _TelemetryValue extends StatelessWidget {
  const _TelemetryValue({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Container(
    width: 142,
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
    decoration: BoxDecoration(
      color: WindfullPalette.raised,
      borderRadius: BorderRadius.circular(13),
    ),
    child: Row(
      children: [
        Icon(icon, color: WindfullPalette.accent, size: 17),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: const TextStyle(
                  color: WindfullPalette.muted,
                  fontSize: 9,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                value,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

class _ControlTile extends StatelessWidget {
  const _ControlTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.trailing,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final Widget trailing;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.fromLTRB(15, 13, 10, 13),
    decoration: BoxDecoration(
      color: WindfullPalette.surface,
      borderRadius: BorderRadius.circular(18),
    ),
    child: Row(
      children: [
        Container(
          height: 38,
          width: 38,
          decoration: BoxDecoration(
            color: WindfullPalette.raised,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(icon, color: WindfullPalette.accent, size: 21),
        ),
        const SizedBox(width: 11),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                subtitle,
                style: const TextStyle(
                  color: WindfullPalette.muted,
                  fontSize: 10,
                ),
              ),
            ],
          ),
        ),
        trailing,
      ],
    ),
  );
}

class _ChoiceSheet extends StatelessWidget {
  const _ChoiceSheet({
    required this.icon,
    required this.title,
    required this.selected,
    required this.options,
  });

  final IconData icon;
  final String title;
  final String? selected;
  final List<String> options;

  @override
  Widget build(BuildContext context) => SafeArea(
    top: false,
    child: Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      decoration: const BoxDecoration(
        color: WindfullPalette.raised,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        boxShadow: [
          BoxShadow(
            color: Color(0x66000000),
            blurRadius: 30,
            offset: Offset(0, -8),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: Container(
              width: 34,
              height: 4,
              decoration: BoxDecoration(
                color: WindfullPalette.muted.withValues(alpha: .4),
                borderRadius: BorderRadius.circular(4),
              ),
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Icon(icon, color: WindfullPalette.accent, size: 19),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.close_rounded, size: 18),
              ),
            ],
          ),
          const SizedBox(height: 4),
          for (final option in options)
            Padding(
              padding: const EdgeInsets.only(bottom: 3),
              child: Material(
                color: option == selected
                    ? WindfullPalette.accent.withValues(alpha: .11)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(13),
                child: InkWell(
                  borderRadius: BorderRadius.circular(13),
                  onTap: () => Navigator.pop(context, option),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 13,
                      vertical: 12,
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            _displayOption(option),
                            style: TextStyle(
                              color: option == selected
                                  ? WindfullPalette.accent
                                  : WindfullPalette.text,
                              fontSize: 13,
                              fontWeight: option == selected
                                  ? FontWeight.w600
                                  : FontWeight.w400,
                            ),
                          ),
                        ),
                        if (option == selected)
                          const Icon(
                            Icons.check_rounded,
                            color: WindfullPalette.accent,
                            size: 18,
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    ),
  );
}

String _displayOption(String value) => switch (value.toLowerCase()) {
  'auto' => 'Automático',
  'cool' => 'Resfriar',
  'dry' => 'Desumidificar',
  'fan' || 'wind' => 'Ventilar',
  'purify' ||
  'purifier' ||
  'air_purify' ||
  'air_purifier' ||
  'airpurify' ||
  'airpurifier' ||
  'purification' ||
  'air_purification' ||
  'airpurification' => 'Purificar',
  'heat' => 'Aquecer',
  'low' => 'Baixa',
  'medium' => 'Média',
  'high' => 'Alta',
  'turbo' => 'Turbo',
  _ => value,
};
