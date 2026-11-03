/// Values exposed by the Samsung OCF appliance profile.
///
/// Raw values are retained so an appliance option not yet modeled by Windfull
/// is not silently translated into a different mode.
enum AcMode { cool, dry, fan, auto, heat, unknown }

enum FanSpeed { auto, low, medium, high, turbo, unknown }

class ApplianceDevice {
  const ApplianceDevice({
    required this.id,
    required this.host,
    this.name,
    this.model,
    this.port,
  });

  final String id;
  final String host;
  final String? name;
  final String? model;
  final int? port;
}

class TemperatureLimits {
  const TemperatureLimits({
    this.available,
    this.minimum,
    this.maximum,
    this.step,
  });

  final bool? available;
  final double? minimum;
  final double? maximum;
  final double? step;
}

class ApplianceCapabilities {
  ApplianceCapabilities({
    this.power,
    this.temperature,
    List<AcMode> modes = const [],
    List<FanSpeed> fanSpeeds = const [],
    this.windFree,
    List<String> rawModes = const [],
    List<String> rawFanSpeeds = const [],
    Map<String, Object?> rawResources = const {},
  }) : modes = List.unmodifiable(modes),
       fanSpeeds = List.unmodifiable(fanSpeeds),
       rawModes = List.unmodifiable(rawModes),
       rawFanSpeeds = List.unmodifiable(rawFanSpeeds),
       rawResources = Map.unmodifiable(rawResources);

  /// Null means the profile did not establish whether this operation exists.
  final bool? power;
  final TemperatureLimits? temperature;
  final List<AcMode> modes;
  final List<FanSpeed> fanSpeeds;
  final bool? windFree;
  final List<String> rawModes;
  final List<String> rawFanSpeeds;
  final Map<String, Object?> rawResources;
}

class ApplianceSnapshot {
  ApplianceSnapshot({
    this.power,
    this.temperature,
    this.ambientTemperature,
    this.mode,
    this.fanSpeed,
    this.windFree,
    Map<String, Object?> rawValues = const {},
  }) : rawValues = Map.unmodifiable(rawValues);

  /// Null means unknown or unavailable, not off.
  final bool? power;
  final double? temperature;
  final double? ambientTemperature;
  final AcMode? mode;
  final FanSpeed? fanSpeed;
  final bool? windFree;

  /// OCF resource fields retained by the driver when no typed mapping exists.
  final Map<String, Object?> rawValues;
}

class ApplianceException implements Exception {
  const ApplianceException(this.message, {this.code});

  final String message;
  final String? code;

  @override
  String toString() => code == null ? message : '$code: $message';
}

class UnsupportedApplianceOperation extends ApplianceException {
  const UnsupportedApplianceOperation(super.message)
    : super(code: 'unsupported_operation');
}
