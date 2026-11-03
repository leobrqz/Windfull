class EnergyTracker {
  EnergyTracker({this.pricePerKWh = 0.95})
    : _hourlyWattHours = List.filled(24, 0);

  static const _maximumPowerWatts = 10000.0;
  static const _minimumDeltaWh = 250.0;

  double pricePerKWh;
  String? _day;
  List<double> _hourlyWattHours;
  double? _lastMeterWattHours;
  DateTime? _lastSampleAt;

  bool get hasBaseline => _lastMeterWattHours != null;
  double? get meterKWh =>
      _lastMeterWattHours == null ? null : _lastMeterWattHours! / 1000;
  DateTime? get lastSampleAt => _lastSampleAt;
  double get todayKWh =>
      _hourlyWattHours.fold<double>(0, (a, b) => a + b) / 1000;
  double get monthlyEstimate => todayKWh * 30 * pricePerKWh;
  List<double> get hourlyKWh =>
      List.unmodifiable(_hourlyWattHours.map((value) => value / 1000));

  bool prepareDay(DateTime now) {
    final today = _dayKey(now);
    if (_day == today) return false;
    _day = today;
    _hourlyWattHours = List.filled(24, 0);
    return true;
  }

  /// Returns true when a meter baseline or today's hourly history changed.
  bool record(double cumulativeWattHours, DateTime now) {
    if (!cumulativeWattHours.isFinite || cumulativeWattHours < 0) return false;
    final previousDay = _dayKey(_lastSampleAt ?? now);
    final dayChanged = prepareDay(now);
    final previous = _lastMeterWattHours;
    var changed = dayChanged;
    if (previous != null &&
        _lastSampleAt != null &&
        previousDay == _dayKey(now) &&
        now.isAfter(_lastSampleAt!) &&
        cumulativeWattHours >= previous) {
      final delta = cumulativeWattHours - previous;
      final elapsedHours = now.difference(_lastSampleAt!).inSeconds / 3600;
      final reasonableDelta = (_maximumPowerWatts * elapsedHours).clamp(
        _minimumDeltaWh,
        double.infinity,
      );
      if (delta > 0 && delta <= reasonableDelta) {
        _hourlyWattHours[now.hour] += delta;
        changed = true;
      }
    }
    if (previous == null || cumulativeWattHours != previous) changed = true;
    _lastMeterWattHours = cumulativeWattHours;
    _lastSampleAt = now;
    return changed;
  }

  void loadFromJson(Object? raw) {
    if (raw is! Map) return;
    final price = raw['pricePerKWh'];
    if (price is num && price.isFinite && price > 0 && price <= 100) {
      pricePerKWh = price.toDouble();
    }
    final day = raw['day'];
    if (day is String && RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(day)) {
      _day = day;
    }
    final hourly = raw['hourlyWattHours'];
    if (hourly is List && hourly.length == 24) {
      final values = hourly.map(
        (value) => value is num ? value.toDouble() : double.nan,
      );
      final parsed = values.toList(growable: false);
      if (parsed.every((value) => value.isFinite && value >= 0)) {
        _hourlyWattHours = parsed;
      }
    }
    final meter = raw['lastMeterWattHours'];
    if (meter is num && meter.isFinite && meter >= 0) {
      _lastMeterWattHours = meter.toDouble();
    }
    final timestamp = raw['lastSampleAt'];
    if (timestamp is String) _lastSampleAt = DateTime.tryParse(timestamp);
  }

  Map<String, Object?> toJson() => {
    'pricePerKWh': pricePerKWh,
    'day': _day,
    'hourlyWattHours': _hourlyWattHours,
    'lastMeterWattHours': _lastMeterWattHours,
    'lastSampleAt': _lastSampleAt?.toIso8601String(),
  };

  static String _dayKey(DateTime date) =>
      '${date.year.toString().padLeft(4, '0')}-'
      '${date.month.toString().padLeft(2, '0')}-'
      '${date.day.toString().padLeft(2, '0')}';
}
