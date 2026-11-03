/// Builds a useful, privacy-conscious name from Android's public build fields.
/// The Android build API is available without runtime permissions.
String buildPairingClientName({
  required String manufacturer,
  required String model,
}) {
  const fallback = 'Celular Android';
  final maker = manufacturer.trim().replaceAll(RegExp(r'\s+'), ' ');
  final deviceModel = model.trim().replaceAll(RegExp(r'\s+'), ' ');
  final validMaker = maker.isEmpty || maker.toLowerCase() == 'unknown' ? '' : maker;
  final validModel = deviceModel.isEmpty || deviceModel.toLowerCase() == 'unknown'
      ? ''
      : deviceModel;

  if (validModel.isEmpty && validMaker.isEmpty) return fallback;
  if (validModel.isEmpty) return _limitName('$validMaker Android');
  if (validMaker.isEmpty ||
      validModel.toLowerCase().startsWith(validMaker.toLowerCase())) {
    return _limitName(validModel);
  }
  return _limitName('$validMaker $validModel');
}

String _limitName(String value) {
  final runes = value.runes.toList(growable: false);
  if (runes.length <= 120) return value;
  return String.fromCharCodes(runes.take(120));
}
