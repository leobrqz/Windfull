import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'host_controller.dart';
import 'windfull_brand_mark.dart';
import 'windfull_theme.dart';

class WindfullServerScreen extends StatefulWidget {
  const WindfullServerScreen({
    required this.controller,
    this.onMinimize,
    super.key,
  });

  final WindfullHostController controller;
  final VoidCallback? onMinimize;

  @override
  State<WindfullServerScreen> createState() => _WindfullServerScreenState();
}

class _WindfullServerScreenState extends State<WindfullServerScreen> {
  final _ipController = TextEditingController();
  final _nameController = TextEditingController();
  var _settingsOpen = false;
  var _settingsTab = 0;
  var _configuring = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _invoke(widget.controller.start),
    );
  }

  @override
  void dispose() {
    _ipController.dispose();
    _nameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.controller,
    builder: (context, _) {
      final state = widget.controller.state;
      return Scaffold(
        backgroundColor: Colors.transparent,
        body: LayoutBuilder(
          builder: (context, bounds) => Align(
            alignment: Alignment.topRight,
            child: SizedBox(
              key: const ValueKey('popover-panel'),
              width: math.min(380, bounds.maxWidth),
              height: math.min(680, bounds.maxHeight),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [Color(0xFF151A1C), WindfullTheme.canvas],
                  ),
                  borderRadius: BorderRadius.circular(20),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x88000000),
                      blurRadius: 34,
                      offset: Offset(0, 16),
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(19),
                  child: Column(
                    children: [
                      _header(state),
                      Expanded(
                        child: AnimatedSwitcher(
                          duration: const Duration(milliseconds: 160),
                          layoutBuilder: (currentChild, previousChildren) =>
                              Stack(
                                alignment: Alignment.topCenter,
                                children: [
                                  ...previousChildren,
                                  ...?(currentChild == null
                                      ? null
                                      : <Widget>[currentChild]),
                                ],
                              ),
                          child: _settingsOpen
                              ? _settingsView(state)
                              : _controlView(state),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    },
  );

  Widget _header(HostViewState state) {
    if (_settingsOpen) {
      return _PanelHeader(
        leading: _HeaderButton(
          icon: Icons.arrow_back_rounded,
          tooltip: 'Voltar aos controles',
          onPressed: () => setState(() => _settingsOpen = false),
        ),
        title: 'Ajustes',
        subtitle: 'Dispositivos, rede e energia',
        trailing: _HeaderButton(
          icon: Icons.close_rounded,
          tooltip: 'Fechar painel',
          onPressed: widget.onMinimize,
        ),
      );
    }
    final ready = state.status == HostStatus.ready;
    return _PanelHeader(
      leading: const WindfullBrandMark(size: 36),
      title: 'WindFull',
      subtitle: ready ? 'Controle local' : _serverStatusLabel(state.status),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (state.status == HostStatus.error)
            _HeaderButton(
              icon: Icons.refresh_rounded,
              tooltip: 'Tentar iniciar servidor',
              onPressed: () => _invoke(widget.controller.retryServer),
            ),
          _HeaderButton(
            icon: Icons.tune_rounded,
            tooltip: 'Ajustes',
            onPressed: () => setState(() {
              _settingsOpen = true;
              _settingsTab = 0;
            }),
          ),
          _HeaderButton(
            icon: Icons.minimize_rounded,
            tooltip: 'Minimizar',
            onPressed: widget.onMinimize,
          ),
        ],
      ),
    );
  }

  Widget _controlView(HostViewState state) {
    final appliance = state.appliance;
    final connected =
        state.applianceConnection == ApplianceConnectionStatus.connected &&
        appliance != null;
    final hasApplianceData =
        appliance != null &&
        (appliance.isPoweredOn != null ||
            appliance.targetTemperature != null ||
            appliance.roomTemperature != null ||
            appliance.humidity != null ||
            appliance.instantaneousPowerW != null ||
            appliance.cumulativeEnergyWh != null ||
            appliance.mode != null ||
            appliance.fanSpeed != null ||
            appliance.supportedModes.isNotEmpty ||
            appliance.fanSpeeds.isNotEmpty ||
            appliance.features.isNotEmpty);
    final temp = appliance?.targetTemperature;
    final minTemp = appliance?.minimumTemperature;
    final maxTemp = appliance?.maximumTemperature;
    final step = appliance?.temperatureStep;
    final normalizedMode = appliance?.mode?.toLowerCase().replaceAll(
      RegExp(r'[^a-z]'),
      '',
    );
    final purifierMode = const {
      'purify',
      'purifier',
      'airpurify',
      'airpurifier',
      'purification',
      'airpurification',
    }.contains(normalizedMode);
    final fanOnlyMode =
        purifierMode || const {'fan', 'wind'}.contains(normalizedMode);
    final canSetTemperature =
        connected &&
        !fanOnlyMode &&
        temp != null &&
        minTemp != null &&
        maxTemp != null &&
        step != null &&
        minTemp < maxTemp &&
        step > 0;
    final powerSupported =
        appliance?.features.containsKey('power') == true ||
        appliance?.isPoweredOn != null;
    final featureEntries =
        appliance?.features.entries ??
        const <MapEntry<String, ApplianceFeatureState>>[];
    final powerEnabled =
        state.applianceConnection == ApplianceConnectionStatus.connected &&
        powerSupported &&
        !state.busyActions.contains('power');
    final windFree = appliance?.features['windFree'];
    final telemetry = <Widget>[
      if (appliance?.roomTemperature != null)
        _MetricChip(
          icon: Icons.thermostat_rounded,
          label: 'Amb. ${_formatTemp(appliance!.roomTemperature!)}°',
        ),
      if (appliance?.humidity != null)
        _MetricChip(
          icon: Icons.water_drop_outlined,
          label: 'UR ${appliance!.humidity!.toStringAsFixed(0)}%',
        ),
    ];

    return SingleChildScrollView(
      key: const ValueKey('controls'),
      padding: const EdgeInsets.fromLTRB(18, 8, 18, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (state.status == HostStatus.error)
            _InlineNotice(
              icon: Icons.wifi_off_rounded,
              message: _friendlyError(state.serverError, server: true),
              action: 'Tentar novamente',
              onAction: () => _invoke(widget.controller.retryServer),
            ),
          if (state.applianceError != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: _InlineNotice(
                icon: Icons.info_outline_rounded,
                message: _friendlyError(state.applianceError),
                action: 'Ajustes',
                onAction: () => setState(() {
                  _settingsOpen = true;
                  _settingsTab = 0;
                }),
              ),
            ),
          if (connected && !hasApplianceData)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: _InlineNotice(
                icon: Icons.sensors_off_rounded,
                message:
                    'A rede alcan\u00e7a o aparelho, mas ele ainda n\u00e3o retornou dados compat\u00edveis. Confira a conex\u00e3o ou o suporte a este modelo.',
                action: 'Ajustes',
                onAction: () => setState(() {
                  _settingsOpen = true;
                  _settingsTab = 0;
                }),
              ),
            ),
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      appliance?.name ?? 'Ar-condicionado',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: WindfullTheme.text,
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      connected
                          ? appliance.host
                          : _applianceStatusLabel(state.applianceConnection),
                      style: const TextStyle(
                        color: WindfullTheme.muted,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
              if (powerSupported)
                _PowerButton(
                  value: appliance?.isPoweredOn ?? false,
                  enabled: powerEnabled,
                  onPressed: () => _invoke(
                    () => widget.controller.setPower(
                      !(appliance?.isPoweredOn ?? false),
                    ),
                  ),
                )
              else
                const Tooltip(
                  message: 'Este aparelho não informou controle de energia',
                  child: Icon(
                    Icons.power_settings_new_rounded,
                    color: WindfullTheme.disabled,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 4),
          if (telemetry.isNotEmpty) ...[
            Wrap(spacing: 6, runSpacing: 6, children: telemetry),
            const SizedBox(height: 5),
          ],
          const _AirConditionerIllustration(),
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Text(
                temp == null ? '--' : _formatTemp(temp),
                style: const TextStyle(
                  color: WindfullTheme.text,
                  fontSize: 54,
                  height: 1,
                  letterSpacing: -2,
                  fontWeight: FontWeight.w300,
                ),
              ),
              const Padding(
                padding: EdgeInsets.only(top: 12),
                child: Text(
                  '°C',
                  style: TextStyle(color: WindfullTheme.muted, fontSize: 17),
                ),
              ),
              const Spacer(),
              if (windFree != null)
                _WindFreeButton(
                  enabled:
                      connected &&
                      (appliance.isPoweredOn ?? false) &&
                      !state.busyActions.contains('windFree'),
                  value: windFree.enabled,
                  onPressed: () => _invoke(
                    () => widget.controller.setFeature(
                      'windFree',
                      !windFree.enabled,
                    ),
                  ),
                ),
            ],
          ),
          if (canSetTemperature) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                Text(
                  '${minTemp.toStringAsFixed(0)}°',
                  style: const TextStyle(
                    color: WindfullTheme.muted,
                    fontSize: 10,
                  ),
                ),
                Expanded(
                  child: SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      trackHeight: 5,
                      activeTrackColor: WindfullTheme.accent,
                      inactiveTrackColor: WindfullTheme.rail,
                      thumbColor: Colors.white,
                      overlayColor: WindfullTheme.accent.withValues(alpha: .13),
                    ),
                    child: Slider(
                      value: temp.clamp(minTemp, maxTemp),
                      min: minTemp,
                      max: maxTemp,
                      divisions: _sliderDivisions(minTemp, maxTemp, step),
                      onChanged:
                          connected &&
                              (appliance.isPoweredOn ?? false) &&
                              !state.busyActions.contains('temperature')
                          ? (value) => _invoke(
                              () =>
                                  widget.controller.setTargetTemperature(value),
                            )
                          : null,
                    ),
                  ),
                ),
                Text(
                  '${maxTemp.toStringAsFixed(0)}°',
                  style: const TextStyle(
                    color: WindfullTheme.muted,
                    fontSize: 10,
                  ),
                ),
              ],
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _SmallButton(
                  icon: Icons.remove_rounded,
                  onPressed:
                      connected &&
                          (appliance.isPoweredOn ?? false) &&
                          temp - step >= minTemp &&
                          !state.busyActions.contains('temperature')
                      ? () => _invoke(
                          () => widget.controller.setTargetTemperature(
                            temp - step,
                          ),
                        )
                      : null,
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Text(
                    'Temperatura',
                    style: TextStyle(color: WindfullTheme.muted, fontSize: 11),
                  ),
                ),
                _SmallButton(
                  icon: Icons.add_rounded,
                  onPressed:
                      connected &&
                          (appliance.isPoweredOn ?? false) &&
                          temp + step <= maxTemp &&
                          !state.busyActions.contains('temperature')
                      ? () => _invoke(
                          () => widget.controller.setTargetTemperature(
                            temp + step,
                          ),
                        )
                      : null,
                ),
              ],
            ),
          ] else if (connected && fanOnlyMode)
            Padding(
              padding: const EdgeInsets.only(top: 5, bottom: 3),
              child: Text(
                'Ajuste indisponível no modo ${purifierMode ? 'Purificar' : 'Ventilar'}.',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: WindfullTheme.muted,
                  fontSize: 10,
                ),
              ),
            )
          else if (!connected)
            Padding(
              padding: const EdgeInsets.only(top: 2, bottom: 8),
              child: Text(
                'Selecione um aparelho para ver os controles disponíveis.',
                textAlign: TextAlign.center,
                style: TextStyle(color: WindfullTheme.muted, fontSize: 11),
              ),
            ),
          if (connected &&
              (appliance.supportedModes.isNotEmpty ||
                  appliance.fanSpeeds.isNotEmpty)) ...[
            const SizedBox(height: 14),
            Row(
              children: [
                if (appliance.supportedModes.isNotEmpty)
                  Expanded(
                    child: _OptionPicker(
                      icon: Icons.tune_rounded,
                      title: 'Modo',
                      value: appliance.mode,
                      options: appliance.supportedModes,
                      enabled:
                          (appliance.isPoweredOn ?? false) &&
                          !state.busyActions.contains('mode'),
                      onChanged: (value) => _invoke(
                        () => widget.controller.setOperatingMode(value),
                      ),
                    ),
                  ),
                if (appliance.supportedModes.isNotEmpty &&
                    appliance.fanSpeeds.isNotEmpty)
                  const SizedBox(width: 8),
                if (appliance.fanSpeeds.isNotEmpty)
                  Expanded(
                    child: _OptionPicker(
                      icon: Icons.air_rounded,
                      title: 'Ventilação',
                      value: appliance.fanSpeed,
                      options: appliance.fanSpeeds,
                      enabled:
                          (appliance.isPoweredOn ?? false) &&
                          !state.busyActions.contains('fanSpeed'),
                      onChanged: (value) =>
                          _invoke(() => widget.controller.setFanSpeed(value)),
                    ),
                  ),
              ],
            ),
          ],
          for (final feature in featureEntries)
            if (feature.key.toLowerCase() != 'windfree')
              _FeatureRow(
                label: feature.value.label,
                value: feature.value.enabled,
                icon: _featureIcon(feature.key),
                enabled: connected && (appliance.isPoweredOn ?? false),
                onChanged: (value) => _invoke(
                  () => widget.controller.setFeature(feature.key, value),
                ),
              ),
          const SizedBox(height: 14),
          Row(
            children: [
              Icon(
                connected ? Icons.check_circle_outline : Icons.circle_outlined,
                size: 13,
                color: connected ? WindfullTheme.accent : WindfullTheme.muted,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  _connectionLabel(state, connected),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: WindfullTheme.muted,
                    fontSize: 10,
                  ),
                ),
              ),
              if (state.status == HostStatus.error)
                IconButton(
                  tooltip: 'Tentar novamente',
                  visualDensity: VisualDensity.compact,
                  onPressed: () => _invoke(widget.controller.retryServer),
                  icon: const Icon(Icons.refresh_rounded, size: 17),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _settingsView(HostViewState state) => Column(
    key: const ValueKey('settings'),
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 9, 16, 10),
        child: Container(
          padding: const EdgeInsets.all(3),
          decoration: BoxDecoration(
            color: WindfullTheme.surface,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Row(
            children: [
              for (var index = 0; index < 4; index++)
                Expanded(
                  child: _TabButton(
                    label: switch (index) {
                      0 => 'Aparelho',
                      1 => 'Celulares',
                      2 => 'Rede',
                      _ => 'Energia',
                    },
                    selected: _settingsTab == index,
                    onPressed: () => setState(() => _settingsTab = index),
                  ),
                ),
            ],
          ),
        ),
      ),
      Expanded(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 2, 16, 16),
          child: switch (_settingsTab) {
            0 => _applianceSettings(state),
            1 => _pairingSettings(state),
            2 => _networkSettings(state),
            _ => _energySettings(state),
          },
        ),
      ),
    ],
  );

  Widget _energySettings(HostViewState state) =>
      _EnergySettingsPanel(usage: state.energyUsage, onSave: _saveEnergyPrice);

  Future<void> _saveEnergyPrice(double price) async {
    try {
      await widget.controller.setEnergyPricePerKWh(price);
      _showMessage('Tarifa de energia salva.');
    } catch (error) {
      _showMessage(_friendlyError(error));
      rethrow;
    }
  }

  Widget _applianceSettings(HostViewState state) {
    final canSearch =
        !state.isDiscovering &&
        !state.busyActions.contains('appliance.connect');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SectionLabel(
          title: 'Selecionar aparelho',
          trailing: IconButton(
            tooltip: 'Buscar na rede',
            onPressed: canSearch
                ? () => _invoke(widget.controller.discoverAppliances)
                : null,
            icon: state.isDiscovering
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh_rounded, size: 18),
          ),
        ),
        _DarkSurface(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (state.applianceConnection ==
                      ApplianceConnectionStatus.connected &&
                  state.appliance != null)
                _InfoLine(
                  icon: Icons.ac_unit_rounded,
                  title: state.appliance!.name,
                  subtitle: state.appliance!.host,
                  trailing: const Icon(
                    Icons.check_circle_rounded,
                    color: WindfullTheme.accent,
                    size: 18,
                  ),
                )
              else
                Text(
                  state.applianceError == null
                      ? 'Nenhum aparelho conectado.'
                      : _friendlyError(state.applianceError),
                  style: const TextStyle(
                    color: WindfullTheme.muted,
                    fontSize: 12,
                    height: 1.4,
                  ),
                ),
              if (state.discoveryError != null) ...[
                const SizedBox(height: 8),
                Text(
                  _friendlyError(state.discoveryError),
                  style: const TextStyle(
                    color: WindfullTheme.warning,
                    fontSize: 11,
                  ),
                ),
              ],
            ],
          ),
        ),
        if (state.discoveredAppliances.isNotEmpty) ...[
          const SizedBox(height: 10),
          for (final device in state.discoveredAppliances)
            _DarkSurface(
              margin: const EdgeInsets.only(bottom: 6),
              padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
              child: Row(
                children: [
                  const Icon(
                    Icons.ac_unit_rounded,
                    color: WindfullTheme.muted,
                    size: 17,
                  ),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          device.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: WindfullTheme.text,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        Text(
                          device.host,
                          style: const TextStyle(
                            color: WindfullTheme.muted,
                            fontSize: 10,
                          ),
                        ),
                      ],
                    ),
                  ),
                  TextButton(
                    onPressed: canSearch
                        ? () => _invoke(
                            () => widget.controller.selectAppliance(device.id),
                          )
                        : null,
                    child: const Text('Usar'),
                  ),
                ],
              ),
            ),
        ] else if (state.isDiscovering)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: LinearProgressIndicator(minHeight: 2),
          )
        else if (state.hasSearchedForAppliances)
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text(
              'Nenhum aparelho respondeu. Confira se está ligado e na mesma rede.',
              style: TextStyle(color: WindfullTheme.muted, fontSize: 11),
            ),
          ),
        const SizedBox(height: 16),
        const _SectionLabel(title: 'Configurar por IP'),
        _DarkSurface(
          child: Column(
            children: [
              TextField(
                controller: _ipController,
                keyboardType: TextInputType.url,
                style: const TextStyle(color: WindfullTheme.text, fontSize: 12),
                decoration: const InputDecoration(
                  hintText: 'Endereço IP do ar',
                  prefixIcon: Icon(Icons.lan_outlined, size: 17),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _nameController,
                style: const TextStyle(color: WindfullTheme.text, fontSize: 12),
                decoration: const InputDecoration(
                  hintText: 'Nome (opcional)',
                  prefixIcon: Icon(Icons.label_outline_rounded, size: 17),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 9),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: canSearch && !_configuring
                      ? _submitManualConfiguration
                      : null,
                  child: Text(_configuring ? 'Conectando…' : 'Conectar'),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _pairingSettings(HostViewState state) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _SectionLabel(
        title: 'Pedidos pendentes (${state.pendingPairings.length})',
      ),
      if (state.pendingPairings.isEmpty)
        const _DarkSurface(
          child: Text(
            'Novos pedidos do celular aparecerão aqui.',
            style: TextStyle(color: WindfullTheme.muted, fontSize: 12),
          ),
        )
      else
        for (final request in state.pendingPairings)
          _PairingRequestCard(
            request: request,
            busy: state.busyActions.contains('pairing.${request.id}'),
            onApprove: () => _approve(request),
            onReject: () => _invoke(
              () => widget.controller.rejectPairingRequest(request.id),
            ),
          ),
      const SizedBox(height: 16),
      _SectionLabel(
        title: 'Celulares pareados (${state.pairedDevices.length})',
      ),
      if (state.pairedDevices.isEmpty)
        const _DarkSurface(
          child: Text(
            'Nenhum celular autorizado.',
            style: TextStyle(color: WindfullTheme.muted, fontSize: 12),
          ),
        )
      else
        for (final device in state.pairedDevices)
          _DarkSurface(
            margin: const EdgeInsets.only(bottom: 7),
            padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
            child: Row(
              children: [
                const Icon(
                  Icons.phone_android_rounded,
                  color: WindfullTheme.accent,
                  size: 18,
                ),
                const SizedBox(width: 9),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        device.name,
                        style: const TextStyle(
                          color: WindfullTheme.text,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        'Pareado ${_formatDate(device.pairedAt)}',
                        style: const TextStyle(
                          color: WindfullTheme.muted,
                          fontSize: 10,
                        ),
                      ),
                    ],
                  ),
                ),
                TextButton(
                  onPressed: state.busyActions.contains('revoke.${device.id}')
                      ? null
                      : () => _revoke(device),
                  child: const Text('Revogar'),
                ),
              ],
            ),
          ),
    ],
  );

  Widget _networkSettings(HostViewState state) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const _SectionLabel(title: 'Servidor local'),
      _DarkSurface(
        child: Column(
          children: [
            _InfoLine(
              icon: state.status == HostStatus.ready
                  ? Icons.wifi_rounded
                  : Icons.wifi_off_rounded,
              title: _serverStatusLabel(state.status),
              subtitle: state.serverError == null
                  ? 'A comunicação com o celular é local.'
                  : _friendlyError(state.serverError, server: true),
              trailing: state.status == HostStatus.error
                  ? IconButton(
                      tooltip: 'Tentar novamente',
                      onPressed: () => _invoke(widget.controller.retryServer),
                      icon: const Icon(Icons.refresh_rounded, size: 18),
                    )
                  : const SizedBox.shrink(),
            ),
            const Divider(height: 20),
            _DataRow(
              label: 'Endereço(s)',
              value: state.localAddresses.isEmpty
                  ? 'Indisponível'
                  : state.localAddresses.join(' · '),
            ),
            _DataRow(
              label: 'Porta',
              value: state.serverPort?.toString() ?? '—',
            ),
            _DataRow(
              label: 'Impressão TLS',
              value: state.certificateFingerprint ?? 'Indisponível',
              selectable: true,
            ),
          ],
        ),
      ),
      const SizedBox(height: 14),
      const Text(
        'O celular precisa estar na mesma rede local. A identidade do servidor permanece a mesma entre atualizações.',
        style: TextStyle(color: WindfullTheme.muted, fontSize: 11, height: 1.5),
      ),
    ],
  );

  Future<void> _submitManualConfiguration() async {
    final host = _ipController.text.trim();
    if (host.isEmpty) {
      _showMessage('Informe o endereço IP do aparelho.');
      return;
    }
    setState(() => _configuring = true);
    try {
      await widget.controller.configureApplianceManually(
        host: host,
        name: _nameController.text.trim().isEmpty
            ? null
            : _nameController.text.trim(),
      );
      _ipController.clear();
      _nameController.clear();
      if (mounted) setState(() => _settingsOpen = false);
    } catch (error) {
      _showMessage(_friendlyError(error));
    } finally {
      if (mounted) setState(() => _configuring = false);
    }
  }

  Future<void> _approve(PendingPairingRequest request) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: WindfullTheme.surface,
        title: const Text('Comparar códigos'),
        content: Text(
          'Confira se ${request.verificationCode} também aparece no celular de “${request.deviceName}”. Aprove somente se os dois códigos forem iguais.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Voltar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Os códigos conferem'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await _invoke(() => widget.controller.approvePairingRequest(request.id));
    }
  }

  Future<void> _revoke(PairedDevice device) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: WindfullTheme.surface,
        title: const Text('Revogar celular?'),
        content: Text('${device.name} perderá o acesso ao WindFull.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancelar'),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Revogar'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await _invoke(() => widget.controller.revokePairedDevice(device.id));
    }
  }

  Future<void> _invoke(Future<void> Function() operation) async {
    try {
      await operation();
    } catch (error) {
      _showMessage(_friendlyError(error));
    }
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }
}

class _EnergySettingsPanel extends StatefulWidget {
  const _EnergySettingsPanel({required this.usage, required this.onSave});

  final EnergyUsageState usage;
  final Future<void> Function(double price) onSave;

  @override
  State<_EnergySettingsPanel> createState() => _EnergySettingsPanelState();
}

class _EnergySettingsPanelState extends State<_EnergySettingsPanel> {
  late final TextEditingController _priceController;
  final _priceFocus = FocusNode();
  var _saving = false;
  String? _validationMessage;

  @override
  void initState() {
    super.initState();
    _priceController = TextEditingController(
      text: _formatEnergyRate(widget.usage.pricePerKWh),
    );
  }

  @override
  void didUpdateWidget(covariant _EnergySettingsPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.usage.pricePerKWh != widget.usage.pricePerKWh &&
        !_priceFocus.hasFocus) {
      _priceController.text = _formatEnergyRate(widget.usage.pricePerKWh);
    }
  }

  @override
  void dispose() {
    _priceController.dispose();
    _priceFocus.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final price = double.tryParse(
      _priceController.text.trim().replaceAll(',', '.'),
    );
    if (price == null || !price.isFinite || price <= 0 || price > 100) {
      setState(() {
        _validationMessage = 'Informe um valor entre R\$ 0,01 e R\$ 100,00.';
      });
      return;
    }

    setState(() {
      _saving = true;
      _validationMessage = null;
    });
    try {
      await widget.onSave(price);
    } catch (_) {
      // The host screen reports the persistence error in its snackbar.
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _EnergyOverviewCard(usage: widget.usage),
      const SizedBox(height: 11),
      _HourlyEnergyCard(usage: widget.usage),
      const SizedBox(height: 11),
      _DarkSurface(
        padding: const EdgeInsets.all(13),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const _SectionLabel(title: 'Tarifa de energia'),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: TextField(
                    controller: _priceController,
                    focusNode: _priceFocus,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    textInputAction: TextInputAction.done,
                    onSubmitted: (_) => _save(),
                    onChanged: (_) {
                      if (_validationMessage != null) {
                        setState(() => _validationMessage = null);
                      }
                    },
                    style: const TextStyle(
                      color: WindfullTheme.text,
                      fontSize: 12,
                    ),
                    decoration: const InputDecoration(
                      prefixText: 'R\$ ',
                      suffixText: '/ kWh',
                      hintText: '0,95',
                      isDense: true,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton.icon(
                  onPressed: _saving ? null : _save,
                  icon: _saving
                      ? const SizedBox.square(
                          dimension: 13,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.check_rounded, size: 15),
                  label: const Text('Salvar'),
                ),
              ],
            ),
            if (_validationMessage != null) ...[
              const SizedBox(height: 6),
              Text(
                _validationMessage!,
                style: const TextStyle(
                  color: WindfullTheme.warning,
                  fontSize: 10,
                ),
              ),
            ],
            const SizedBox(height: 8),
            const Text(
              'A projeção mensal usa o consumo de hoje multiplicado por 30.',
              style: TextStyle(
                color: WindfullTheme.muted,
                fontSize: 10,
                height: 1.35,
              ),
            ),
          ],
        ),
      ),
      const SizedBox(height: 9),
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(
            Icons.info_outline_rounded,
            color: WindfullTheme.muted,
            size: 14,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              widget.usage.hasBaseline
                  ? 'O histórico começa na primeira leitura recebida pelo WindFull; o aparelho não fornece dados anteriores.'
                  : 'Aguardando uma leitura do medidor de energia do aparelho para iniciar o histórico.',
              style: const TextStyle(
                color: WindfullTheme.muted,
                fontSize: 10,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    ],
  );
}

class _EnergyOverviewCard extends StatelessWidget {
  const _EnergyOverviewCard({required this.usage});

  final EnergyUsageState usage;

  @override
  Widget build(BuildContext context) {
    final hasData = usage.hasBaseline;
    return Container(
      padding: const EdgeInsets.all(15),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF233332), WindfullTheme.surface],
        ),
        borderRadius: BorderRadius.circular(17),
        border: Border.all(color: WindfullTheme.accent.withValues(alpha: .12)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(
                Icons.electric_bolt_rounded,
                color: WindfullTheme.accent,
                size: 17,
              ),
              const SizedBox(width: 7),
              const Expanded(
                child: Text(
                  'CONSUMO DE HOJE',
                  style: TextStyle(
                    color: WindfullTheme.muted,
                    fontSize: 9,
                    fontWeight: FontWeight.w700,
                    letterSpacing: .8,
                  ),
                ),
              ),
              if (usage.lastSampleAt != null)
                Text(
                  'Atualizado ${_formatSampleTime(usage.lastSampleAt!)}',
                  style: const TextStyle(
                    color: WindfullTheme.muted,
                    fontSize: 9,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 9),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                hasData ? _formatEnergy(usage.todayKWh) : '—',
                style: const TextStyle(
                  color: WindfullTheme.text,
                  fontSize: 31,
                  height: 1,
                  fontWeight: FontWeight.w600,
                  letterSpacing: -.8,
                ),
              ),
              const Padding(
                padding: EdgeInsets.only(left: 6, bottom: 3),
                child: Text(
                  'kWh',
                  style: TextStyle(color: WindfullTheme.muted, fontSize: 12),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Container(height: 1, color: WindfullTheme.border),
          const SizedBox(height: 11),
          Row(
            children: [
              const Expanded(
                child: Text(
                  'Estimativa mensal',
                  style: TextStyle(color: WindfullTheme.muted, fontSize: 10),
                ),
              ),
              Text(
                hasData ? '${_formatCurrency(usage.monthlyEstimate)}/mês' : '—',
                style: const TextStyle(
                  color: WindfullTheme.accent,
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          if (usage.meterKWh != null) ...[
            const SizedBox(height: 7),
            Text(
              'Medidor acumulado  ${_formatEnergy(usage.meterKWh!)} kWh',
              style: const TextStyle(color: WindfullTheme.muted, fontSize: 9),
            ),
          ],
        ],
      ),
    );
  }
}

class _HourlyEnergyCard extends StatelessWidget {
  const _HourlyEnergyCard({required this.usage});

  final EnergyUsageState usage;

  @override
  Widget build(BuildContext context) {
    final values = List<double>.generate(
      24,
      (hour) => hour < usage.hourlyKWh.length ? usage.hourlyKWh[hour] : 0,
      growable: false,
    );
    final maximum = values.fold<double>(0, math.max);
    return _DarkSurface(
      padding: const EdgeInsets.fromLTRB(13, 12, 13, 11),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'Consumo por hora',
            style: TextStyle(
              color: WindfullTheme.text,
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 2),
          const Text(
            'kWh registrados hoje',
            style: TextStyle(color: WindfullTheme.muted, fontSize: 9),
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 78,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                for (var hour = 0; hour < values.length; hour++)
                  Expanded(
                    child: Tooltip(
                      message:
                          '${hour.toString().padLeft(2, '0')}:00 · ${_formatEnergy(values[hour])} kWh',
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 1.2),
                        child: Align(
                          alignment: Alignment.bottomCenter,
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 240),
                            curve: Curves.easeOutCubic,
                            height: maximum == 0
                                ? 3
                                : math.max(3, values[hour] / maximum * 74),
                            decoration: BoxDecoration(
                              color: values[hour] == 0
                                  ? WindfullTheme.rail
                                  : WindfullTheme.accent.withValues(
                                      alpha: .42 + .58 * values[hour] / maximum,
                                    ),
                              borderRadius: BorderRadius.circular(3),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 5),
          const Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _ChartHourLabel('00h'),
              _ChartHourLabel('06h'),
              _ChartHourLabel('12h'),
              _ChartHourLabel('18h'),
              _ChartHourLabel('23h'),
            ],
          ),
        ],
      ),
    );
  }
}

class _ChartHourLabel extends StatelessWidget {
  const _ChartHourLabel(this.label);

  final String label;

  @override
  Widget build(BuildContext context) => Text(
    label,
    style: const TextStyle(color: WindfullTheme.muted, fontSize: 8),
  );
}

String _formatEnergy(double value) =>
    value.toStringAsFixed(2).replaceAll('.', ',');

String _formatEnergyRate(double value) =>
    value.toStringAsFixed(2).replaceAll('.', ',');

String _formatCurrency(double value) =>
    'R\$ ${value.toStringAsFixed(2).replaceAll('.', ',')}';

String _formatSampleTime(DateTime value) =>
    '${value.hour.toString().padLeft(2, '0')}:${value.minute.toString().padLeft(2, '0')}';

class _PanelHeader extends StatelessWidget {
  const _PanelHeader({
    required this.leading,
    required this.title,
    required this.subtitle,
    required this.trailing,
  });

  final Widget leading;
  final String title;
  final String subtitle;
  final Widget trailing;

  @override
  Widget build(BuildContext context) => Container(
    height: 64,
    padding: const EdgeInsets.fromLTRB(17, 7, 10, 7),
    decoration: const BoxDecoration(
      border: Border(bottom: BorderSide(color: WindfullTheme.border)),
    ),
    child: Row(
      children: [
        leading,
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  color: WindfullTheme.text,
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 1),
              Text(
                subtitle,
                style: const TextStyle(
                  color: WindfullTheme.muted,
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

class _HeaderButton extends StatelessWidget {
  const _HeaderButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: tooltip,
    visualDensity: VisualDensity.compact,
    onPressed: onPressed,
    icon: Icon(icon, size: 18),
  );
}

class _MetricChip extends StatelessWidget {
  const _MetricChip({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
    decoration: BoxDecoration(
      color: WindfullTheme.surface,
      borderRadius: BorderRadius.circular(10),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 11, color: WindfullTheme.accent),
        const SizedBox(width: 4),
        Text(
          label,
          style: const TextStyle(color: WindfullTheme.muted, fontSize: 9),
        ),
      ],
    ),
  );
}

class _PowerButton extends StatelessWidget {
  const _PowerButton({
    required this.value,
    required this.enabled,
    required this.onPressed,
  });

  final bool value;
  final bool enabled;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: value ? 'Desligar aparelho' : 'Ligar aparelho',
    child: IconButton.filledTonal(
      onPressed: enabled ? onPressed : null,
      style: IconButton.styleFrom(
        backgroundColor: value
            ? WindfullTheme.accent.withValues(alpha: .16)
            : WindfullTheme.surface,
        foregroundColor: value ? WindfullTheme.accent : WindfullTheme.muted,
        disabledForegroundColor: WindfullTheme.disabled,
        padding: const EdgeInsets.all(12),
        minimumSize: const Size(46, 46),
        shape: const CircleBorder(),
      ),
      icon: const Icon(Icons.power_settings_new_rounded, size: 18),
    ),
  );
}

class _WindFreeButton extends StatelessWidget {
  const _WindFreeButton({
    required this.value,
    required this.enabled,
    required this.onPressed,
  });

  final bool value;
  final bool enabled;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: value ? 'Desativar WindFree' : 'Ativar WindFree',
    child: TextButton.icon(
      onPressed: enabled ? onPressed : null,
      icon: Icon(Icons.air_rounded, size: 14),
      label: Text(value ? 'WindFree · Ligado' : 'WindFree · Desligado'),
      style: TextButton.styleFrom(
        backgroundColor: value
            ? WindfullTheme.accent.withValues(alpha: .13)
            : WindfullTheme.surface,
        foregroundColor: value ? WindfullTheme.accent : WindfullTheme.muted,
        disabledForegroundColor: WindfullTheme.disabled,
        minimumSize: const Size(0, 34),
        padding: const EdgeInsets.symmetric(horizontal: 10),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        textStyle: const TextStyle(fontSize: 10, fontWeight: FontWeight.w600),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    ),
  );
}

class _AirConditionerIllustration extends StatelessWidget {
  const _AirConditionerIllustration();

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 104,
    child: CustomPaint(
      painter: _AirConditionerPainter(),
      child: const SizedBox.expand(),
    ),
  );
}

class _AirConditionerPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final width = size.width * .72;
    final left = (size.width - width) / 2;
    final top = size.height * .22;
    final body = Rect.fromLTWH(left, top, width, size.height * .48);
    final shadow = Paint()
      ..color = const Color(0x55000000)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 12);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        body.shift(const Offset(0, 8)),
        const Radius.circular(13),
      ),
      shadow,
    );
    final shell = Paint()
      ..shader = const LinearGradient(
        colors: [Color(0xFFF4F6F4), Color(0xFFDDE2E1)],
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
      ).createShader(body);
    canvas.drawRRect(
      RRect.fromRectAndRadius(body, const Radius.circular(12)),
      shell,
    );
    final lip = Paint()..color = const Color(0xFFFFFFFF);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(left + 5, top + 3, width - 10, 10),
        const Radius.circular(5),
      ),
      lip,
    );
    final seam = Paint()
      ..color = const Color(0xFFAAB4B3)
      ..strokeWidth = 1;
    canvas.drawLine(
      Offset(left + 12, top + 16),
      Offset(left + width - 12, top + 16),
      seam,
    );
    final vent = Paint()
      ..color = const Color(0xFF9DA8A7)
      ..strokeWidth = 1.4
      ..strokeCap = StrokeCap.round;
    final ventY = top + body.height - 10;
    for (var index = 0; index < 28; index++) {
      final x = left + 18 + index * ((width - 36) / 27);
      canvas.drawLine(Offset(x, ventY), Offset(x - 2, ventY + 5), vent);
    }
    final outlet = Paint()
      ..color = const Color(0xFF7C8988)
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(
      Offset(left + 18, ventY + 8),
      Offset(left + width - 18, ventY + 8),
      outlet,
    );
    final air = Paint()
      ..color = WindfullTheme.accent.withValues(alpha: .42)
      ..strokeWidth = 1.2
      ..strokeCap = StrokeCap.round;
    for (var index = 0; index < 4; index++) {
      final y = top + body.height + 13 + index * 7;
      final spread = 26.0 + index * 13;
      canvas.drawLine(
        Offset(size.width / 2 - spread, y),
        Offset(size.width / 2 + spread, y),
        air,
      );
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _OptionPicker extends StatelessWidget {
  const _OptionPicker({
    required this.icon,
    required this.title,
    required this.value,
    required this.options,
    required this.enabled,
    required this.onChanged,
  });

  final IconData icon;
  final String title;
  final String? value;
  final List<String> options;
  final bool enabled;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) => Container(
    decoration: BoxDecoration(
      color: WindfullTheme.surface,
      borderRadius: BorderRadius.circular(15),
    ),
    child: InkWell(
      borderRadius: BorderRadius.circular(15),
      onTap: enabled ? () => _selectOption(context) : null,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(11, 9, 10, 9),
        child: Row(
          children: [
            Container(
              width: 30,
              height: 30,
              decoration: BoxDecoration(
                color: WindfullTheme.surfaceRaised,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, color: WindfullTheme.accent, size: 15),
            ),
            const SizedBox(width: 9),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      color: WindfullTheme.muted,
                      fontSize: 10,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    value != null && options.contains(value)
                        ? _formatOption(value!)
                        : '—',
                    style: const TextStyle(
                      color: WindfullTheme.text,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
            const Icon(
              Icons.keyboard_arrow_down_rounded,
              color: WindfullTheme.muted,
              size: 18,
            ),
          ],
        ),
      ),
    ),
  );

  Future<void> _selectOption(BuildContext context) async {
    final anchor = context.findRenderObject();
    final overlay = Overlay.of(context).context.findRenderObject();
    if (anchor is! RenderBox || overlay is! RenderBox) return;
    final anchorRect = Rect.fromPoints(
      anchor.localToGlobal(Offset.zero, ancestor: overlay),
      anchor.localToGlobal(
        anchor.size.bottomRight(Offset.zero),
        ancestor: overlay,
      ),
    );
    final selected = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(anchorRect, Offset.zero & overlay.size),
      color: WindfullTheme.surfaceRaised,
      elevation: 16,
      constraints: BoxConstraints(
        minWidth: anchor.size.width,
        maxWidth: overlay.size.width - 24,
        maxHeight: overlay.size.height - 24,
      ),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
      items: [
        for (final option in options)
          PopupMenuItem<String>(
            value: option,
            height: 38,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    _formatOption(option),
                    style: TextStyle(
                      color: option == value
                          ? WindfullTheme.accent
                          : WindfullTheme.text,
                      fontSize: 12,
                      fontWeight: option == value
                          ? FontWeight.w600
                          : FontWeight.w400,
                    ),
                  ),
                ),
                if (option == value)
                  const Icon(
                    Icons.check_rounded,
                    color: WindfullTheme.accent,
                    size: 16,
                  ),
              ],
            ),
          ),
      ],
    );
    if (selected != null && selected != value) onChanged(selected);
  }
}

class _FeatureRow extends StatelessWidget {
  const _FeatureRow({
    required this.label,
    required this.value,
    required this.icon,
    required this.enabled,
    required this.onChanged,
  });

  final String label;
  final bool value;
  final IconData icon;
  final bool enabled;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 8),
    child: Row(
      children: [
        Icon(icon, color: WindfullTheme.muted, size: 15),
        const SizedBox(width: 7),
        Expanded(
          child: Text(
            label,
            style: const TextStyle(color: WindfullTheme.text, fontSize: 11),
          ),
        ),
        Switch.adaptive(
          value: value,
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          onChanged: enabled ? onChanged : null,
        ),
      ],
    ),
  );
}

class _SmallButton extends StatelessWidget {
  const _SmallButton({required this.icon, required this.onPressed});
  final IconData icon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => IconButton(
    visualDensity: VisualDensity.compact,
    onPressed: onPressed,
    icon: Icon(icon, size: 16),
    style: IconButton.styleFrom(
      backgroundColor: WindfullTheme.surface,
      foregroundColor: WindfullTheme.text,
      disabledForegroundColor: WindfullTheme.disabled,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
    ),
  );
}

class _InlineNotice extends StatelessWidget {
  const _InlineNotice({
    required this.icon,
    required this.message,
    required this.action,
    required this.onAction,
  });

  final IconData icon;
  final String message;
  final String action;
  final VoidCallback onAction;

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.only(bottom: 9),
    padding: const EdgeInsets.fromLTRB(10, 8, 6, 8),
    decoration: BoxDecoration(
      color: WindfullTheme.warning.withValues(alpha: .09),
      borderRadius: BorderRadius.circular(14),
    ),
    child: Row(
      children: [
        Icon(icon, color: WindfullTheme.warning, size: 16),
        const SizedBox(width: 7),
        Expanded(
          child: Text(
            message,
            style: const TextStyle(color: WindfullTheme.text, fontSize: 10),
          ),
        ),
        TextButton(onPressed: onAction, child: Text(action)),
      ],
    ),
  );
}

class _TabButton extends StatelessWidget {
  const _TabButton({
    required this.label,
    required this.selected,
    required this.onPressed,
  });
  final String label;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => AnimatedContainer(
    duration: const Duration(milliseconds: 180),
    curve: Curves.easeOutCubic,
    decoration: BoxDecoration(
      color: selected ? const Color(0xFF2A383A) : Colors.transparent,
      borderRadius: BorderRadius.circular(11),
    ),
    child: TextButton(
      onPressed: onPressed,
      style: TextButton.styleFrom(
        foregroundColor: selected ? WindfullTheme.accent : WindfullTheme.muted,
        padding: const EdgeInsets.symmetric(vertical: 8),
        minimumSize: const Size(0, 34),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(11)),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 10,
          fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
        ),
      ),
    ),
  );
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel({required this.title, this.trailing});
  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(left: 2, bottom: 7),
    child: Row(
      children: [
        Expanded(
          child: Text(
            title,
            style: const TextStyle(
              color: WindfullTheme.text,
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        ?trailing,
      ],
    ),
  );
}

class _DarkSurface extends StatelessWidget {
  const _DarkSurface({
    required this.child,
    this.margin = EdgeInsets.zero,
    this.padding = const EdgeInsets.all(12),
  });
  final Widget child;
  final EdgeInsetsGeometry margin;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) => Container(
    margin: margin,
    padding: padding,
    decoration: BoxDecoration(
      color: WindfullTheme.surface,
      borderRadius: BorderRadius.circular(16),
    ),
    child: child,
  );
}

class _InfoLine extends StatelessWidget {
  const _InfoLine({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.trailing = const SizedBox.shrink(),
  });
  final IconData icon;
  final String title;
  final String subtitle;
  final Widget trailing;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Icon(icon, color: WindfullTheme.accent, size: 18),
      const SizedBox(width: 9),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: const TextStyle(
                color: WindfullTheme.text,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              subtitle,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: WindfullTheme.muted,
                fontSize: 10,
                height: 1.35,
              ),
            ),
          ],
        ),
      ),
      trailing,
    ],
  );
}

class _DataRow extends StatelessWidget {
  const _DataRow({
    required this.label,
    required this.value,
    this.selectable = false,
  });
  final String label;
  final String value;
  final bool selectable;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 5),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 84,
          child: Text(
            label,
            style: const TextStyle(color: WindfullTheme.muted, fontSize: 10),
          ),
        ),
        Expanded(
          child: selectable
              ? SelectableText(
                  value,
                  style: const TextStyle(
                    color: WindfullTheme.text,
                    fontSize: 10,
                  ),
                )
              : Text(
                  value,
                  style: const TextStyle(
                    color: WindfullTheme.text,
                    fontSize: 10,
                  ),
                ),
        ),
      ],
    ),
  );
}

class _PairingRequestCard extends StatelessWidget {
  const _PairingRequestCard({
    required this.request,
    required this.busy,
    required this.onApprove,
    required this.onReject,
  });
  final PendingPairingRequest request;
  final bool busy;
  final VoidCallback onApprove;
  final VoidCallback onReject;

  @override
  Widget build(BuildContext context) => _DarkSurface(
    margin: const EdgeInsets.only(bottom: 8),
    padding: const EdgeInsets.all(11),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const Icon(
              Icons.phone_android_rounded,
              color: WindfullTheme.accent,
              size: 17,
            ),
            const SizedBox(width: 7),
            Expanded(
              child: Text(
                request.deviceName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: WindfullTheme.text,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            IconButton(
              tooltip: 'Recusar pedido',
              visualDensity: VisualDensity.compact,
              onPressed: busy ? null : onReject,
              icon: const Icon(Icons.close_rounded, size: 16),
            ),
          ],
        ),
        const Text(
          'Compare o código abaixo com o que aparece no celular.',
          style: TextStyle(color: WindfullTheme.muted, fontSize: 10),
        ),
        const SizedBox(height: 7),
        Center(
          child: Text(
            request.verificationCode,
            style: const TextStyle(
              color: WindfullTheme.text,
              fontSize: 24,
              fontWeight: FontWeight.w700,
              letterSpacing: 4,
            ),
          ),
        ),
        Text(
          'Expira às ${_formatTime(request.expiresAt)}',
          textAlign: TextAlign.center,
          style: const TextStyle(color: WindfullTheme.muted, fontSize: 9),
        ),
        const SizedBox(height: 8),
        FilledButton(
          onPressed: busy ? null : onApprove,
          child: Text(busy ? 'Aprovando…' : 'Conferir e aprovar'),
        ),
      ],
    ),
  );
}

String _friendlyError(Object? error, {bool server = false}) {
  final value = error?.toString().toLowerCase() ?? '';
  if (value.contains('bridge_start_failed') ||
      value.contains('windfull-samsung-ocf') ||
      value.contains('bridge_closed')) {
    return 'A ponte Samsung não está disponível. Recompile o host incluindo a integração e reinicie o WindFull.';
  }
  if (server) {
    if (value.contains('address already in use') ||
        value.contains('socketexception')) {
      return 'A porta local está ocupada. Feche outra instância do WindFull e tente novamente.';
    }
    return 'O servidor local não iniciou. Tente novamente; seus pareamentos foram preservados.';
  }
  if (value.contains('timeout') ||
      value.contains('tempo limite') ||
      value.contains('sem resposta')) {
    return 'O ar não respondeu. Confira se está ligado e na mesma rede e tente buscar novamente.';
  }
  if (value.contains('unsupported') ||
      value.contains('disponível pelo aparelho')) {
    return 'Esse controle não está disponível no aparelho selecionado.';
  }
  return 'Não foi possível falar com o ar. Confira a conexão e tente novamente.';
}

String _connectionLabel(HostViewState state, bool connected) {
  if (state.status != HostStatus.ready) return _serverStatusLabel(state.status);
  if (connected) return 'Conectado · local';
  return 'Servidor pronto · ar ${_applianceStatusLabel(state.applianceConnection).toLowerCase()}';
}

String _serverStatusLabel(HostStatus status) => switch (status) {
  HostStatus.starting => 'Iniciando',
  HostStatus.ready => 'Servidor ativo',
  HostStatus.error => 'Servidor indisponível',
  HostStatus.stopped => 'Servidor parado',
};

String _applianceStatusLabel(ApplianceConnectionStatus status) =>
    switch (status) {
      ApplianceConnectionStatus.unknown => 'não conectado',
      ApplianceConnectionStatus.connected => 'conectado',
      ApplianceConnectionStatus.disconnected => 'desconectado',
      ApplianceConnectionStatus.error => 'indisponível',
    };

String _formatOption(String option) => switch (option.toLowerCase()) {
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
  _ =>
    option
        .replaceAll('_', ' ')
        .split(' ')
        .map(
          (word) => word.isEmpty
              ? word
              : '${word[0].toUpperCase()}${word.substring(1).toLowerCase()}',
        )
        .join(' '),
};

String _formatTemp(double value) =>
    value.toStringAsFixed(value % 1 == 0 ? 0 : 1);

String _formatDate(DateTime date) =>
    '${date.day.toString().padLeft(2, '0')}/${date.month.toString().padLeft(2, '0')}/${date.year}';

String _formatTime(DateTime date) =>
    '${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';

int? _sliderDivisions(double minimum, double maximum, double step) {
  if (step <= 0 || maximum <= minimum) return null;
  final divisions = ((maximum - minimum) / step).round();
  return divisions > 0 ? divisions : null;
}

IconData _featureIcon(String id) => switch (id.toLowerCase()) {
  'windfree' => Icons.air_rounded,
  'swing' || 'vertical_swing' || 'horizontal_swing' => Icons.swap_vert_rounded,
  'sleep' => Icons.nights_stay_outlined,
  'display' => Icons.lightbulb_outline_rounded,
  'beep' => Icons.volume_up_outlined,
  'auto_clean' => Icons.cleaning_services_outlined,
  _ => Icons.tune_rounded,
};
