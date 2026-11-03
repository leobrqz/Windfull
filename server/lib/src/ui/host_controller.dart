import 'package:flutter/foundation.dart';

/// Presentation-facing contract implemented by the host/service layer.
///
/// The UI deliberately contains no appliance protocol or persistence logic.
abstract class WindfullHostController extends ChangeNotifier {
  HostViewState get state;

  Future<void> start();
  Future<void> retryServer();
  Future<void> discoverAppliances();
  Future<void> selectAppliance(String applianceId);
  Future<void> configureApplianceManually({required String host, String? name});
  Future<void> setPower(bool enabled);
  Future<void> setTargetTemperature(double temperature);
  Future<void> setOperatingMode(String mode);
  Future<void> setFanSpeed(String speed);
  Future<void> setFeature(String featureId, bool enabled);
  Future<void> approvePairingRequest(String requestId);
  Future<void> rejectPairingRequest(String requestId);
  Future<void> revokePairedDevice(String deviceId);
  Future<void> shutdown();
}

enum HostStatus { starting, ready, error, stopped }

enum ApplianceConnectionStatus { unknown, connected, disconnected, error }

@immutable
class HostViewState {
  const HostViewState({
    required this.status,
    this.serverError,
    this.localAddresses = const [],
    this.serverPort,
    this.certificateFingerprint,
    this.isDiscovering = false,
    this.hasSearchedForAppliances = false,
    this.discoveredAppliances = const [],
    this.discoveryError,
    this.selectedApplianceId,
    this.applianceConnection = ApplianceConnectionStatus.unknown,
    this.applianceError,
    this.appliance,
    this.pendingPairings = const [],
    this.pairedDevices = const [],
    this.busyActions = const {},
  });

  final HostStatus status;
  final String? serverError;
  final List<String> localAddresses;
  final int? serverPort;
  final String? certificateFingerprint;
  final bool isDiscovering;
  final bool hasSearchedForAppliances;
  final List<DiscoveredAppliance> discoveredAppliances;
  final String? discoveryError;
  final String? selectedApplianceId;
  final ApplianceConnectionStatus applianceConnection;
  final String? applianceError;
  final ApplianceState? appliance;
  final List<PendingPairingRequest> pendingPairings;
  final List<PairedDevice> pairedDevices;
  final Set<String> busyActions;
}

@immutable
class ApplianceState {
  const ApplianceState({
    required this.id,
    required this.name,
    required this.host,
    this.isPoweredOn,
    this.targetTemperature,
    this.roomTemperature,
    this.minimumTemperature,
    this.maximumTemperature,
    this.temperatureStep,
    this.mode,
    this.supportedModes = const [],
    this.fanSpeed,
    this.fanSpeeds = const [],
    this.features = const {},
  });

  final String id;
  final String name;
  final String host;
  final bool? isPoweredOn;
  final double? targetTemperature;
  final double? roomTemperature;
  final double? minimumTemperature;
  final double? maximumTemperature;
  final double? temperatureStep;
  final String? mode;
  final List<String> supportedModes;
  final String? fanSpeed;
  final List<String> fanSpeeds;

  /// Only capabilities exposed by the connected appliance should be present.
  final Map<String, ApplianceFeatureState> features;
}

@immutable
class ApplianceFeatureState {
  const ApplianceFeatureState({required this.label, required this.enabled});

  final String label;
  final bool enabled;
}

@immutable
class DiscoveredAppliance {
  const DiscoveredAppliance({
    required this.id,
    required this.name,
    required this.host,
    this.isReachable,
    this.isPoweredOn,
    this.targetTemperature,
    this.roomTemperature,
  });

  final String id;
  final String name;
  final String host;
  final bool? isReachable;
  final bool? isPoweredOn;
  final double? targetTemperature;
  final double? roomTemperature;
}

@immutable
class PendingPairingRequest {
  const PendingPairingRequest({
    required this.id,
    required this.deviceName,
    required this.verificationCode,
    required this.expiresAt,
    this.deviceDescription,
  });

  final String id;
  final String deviceName;
  final String? deviceDescription;

  /// Six-digit short authentication string to compare on both devices.
  final String verificationCode;
  final DateTime expiresAt;
}

@immutable
class PairedDevice {
  const PairedDevice({
    required this.id,
    required this.name,
    required this.pairedAt,
    this.description,
    this.lastSeenAt,
  });

  final String id;
  final String name;
  final String? description;
  final DateTime pairedAt;
  final DateTime? lastSeenAt;
}
