import 'dart:convert';
import 'dart:io';

abstract interface class HostSettingsStore {
  Future<Map<String, Object?>?> read();
  Future<void> write(Map<String, Object?> settings);
}

/// Persists non-secret host preferences as JSON in app support storage.
class FileHostSettingsStore implements HostSettingsStore {
  FileHostSettingsStore({required Directory directory})
    : _file = File(
        '${directory.path}${Platform.pathSeparator}host_settings.json',
      );

  final File _file;

  @override
  Future<Map<String, Object?>?> read() async {
    if (!await _file.exists()) return null;
    final decoded = jsonDecode(await _file.readAsString());
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException(
        'O arquivo de configurações do host não contém um objeto JSON.',
      );
    }
    return decoded.map((key, value) => MapEntry(key, value));
  }

  @override
  Future<void> write(Map<String, Object?> settings) async {
    await _file.parent.create(recursive: true);
    final temp = File('${_file.path}.tmp');
    await temp.writeAsString(jsonEncode(settings), flush: true);
    if (await _file.exists()) await _file.delete();
    await temp.rename(_file.path);
  }
}
