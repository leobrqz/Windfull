import 'appliance_models.dart';

/// Local-only access to an OCF appliance.
abstract interface class ApplianceRepository {
  /// Scans the local network and emits discovered devices as they are verified.
  Stream<List<ApplianceDevice>> discover({
    Duration timeout = const Duration(seconds: 8),
  });

  /// Connects to a manually selected host or a previously discovered device.
  Future<ApplianceDevice> connect(String host, {int? port});

  Future<ApplianceSnapshot> readState();

  Future<ApplianceCapabilities> readCapabilities();

  Future<ApplianceSnapshot> setPower(bool enabled);

  Future<ApplianceSnapshot> setTemperature(double celsius);

  Future<ApplianceSnapshot> setMode(AcMode mode);

  Future<ApplianceSnapshot> setFanSpeed(FanSpeed speed);

  Future<ApplianceSnapshot> setWindFree(bool enabled);

  Future<void> disconnect();
}
