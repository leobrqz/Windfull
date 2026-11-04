import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

enum AndroidUpdateStatus {
  idle,
  checking,
  upToDate,
  available,
  downloading,
  downloaded,
  manualInstallRequired,
  permissionRequired,
  installing,
  failed,
}

class AndroidUpdateCandidate {
  const AndroidUpdateCandidate({
    required this.version,
    required this.versionCode,
    required this.size,
    required this.sha256,
    required this.signerSha256,
    required this.downloadUrl,
    required this.releaseUrl,
    required this.notes,
  });

  final String version;
  final int versionCode;
  final int size;
  final String sha256;
  final String signerSha256;
  final String downloadUrl;
  final String releaseUrl;
  final String notes;

  Map<String, Object?> toMap() => {
    'version': version,
    'versionCode': versionCode,
    'size': size,
    'sha256': sha256,
    'signerSha256': signerSha256,
    'downloadUrl': downloadUrl,
    'releaseUrl': releaseUrl,
    'notes': notes,
  };

  factory AndroidUpdateCandidate.fromMap(Map<Object?, Object?> map) {
    String string(String key) {
      final value = map[key];
      if (value is! String) throw FormatException('Invalid update field: $key');
      return value;
    }

    int integer(String key) {
      final value = map[key];
      if (value is! int || value < 1) {
        throw FormatException('Invalid update field: $key');
      }
      return value;
    }

    return AndroidUpdateCandidate(
      version: string('version'),
      versionCode: integer('versionCode'),
      size: integer('size'),
      sha256: string('sha256'),
      signerSha256: string('signerSha256').toLowerCase(),
      downloadUrl: string('downloadUrl'),
      releaseUrl: string('releaseUrl'),
      notes: string('notes'),
    );
  }
}

class AndroidUpdateController extends ChangeNotifier
    with WidgetsBindingObserver {
  AndroidUpdateController({HttpClient? httpClient})
    : _httpClient = httpClient ?? HttpClient() {
    _httpClient.connectionTimeout = const Duration(seconds: 10);
    WidgetsBinding.instance.addObserver(this);
  }

  static const _owner = 'leobrqz';
  static const _repository = 'Windfull';
  static const _catalogName = 'android-update.json';
  static const _apkName = 'Windfull-Android-universal-release.apk';
  static const _methodChannel = MethodChannel('windfull/updates');
  static const _apiUrl =
      'https://api.github.com/repos/$_owner/$_repository/releases/latest';
  static const _maxCatalogBytes = 64 * 1024;
  static const _maxReleaseBytes = 1024 * 1024;
  static const _maxApkBytes = 200 * 1024 * 1024;

  final HttpClient _httpClient;
  AndroidUpdateStatus status = AndroidUpdateStatus.idle;
  AndroidUpdateCandidate? candidate;
  String? currentVersion;
  int? currentBuild;
  String? errorMessage;
  int progressPercent = 0;
  int? _downloadId;
  Timer? _downloadPolling;
  bool _initialized = false;
  bool _operationBusy = false;

  bool get canApproveDownload =>
      status == AndroidUpdateStatus.available && candidate != null;

  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;
    try {
      final info = await _methodChannel.invokeMapMethod<Object?, Object?>(
        'getDeviceInfo',
      );
      if (info == null ||
          info['versionName'] is! String ||
          info['versionCode'] is! int) {
        throw const FormatException('Informações do aplicativo indisponíveis.');
      }
      currentVersion = info['versionName'] as String;
      currentBuild = info['versionCode'] as int;
      final pending = await _methodChannel.invokeMapMethod<Object?, Object?>(
        'getPendingDownload',
      );
      if (pending?['candidate'] is Map && pending?['downloadId'] is int) {
        candidate = AndroidUpdateCandidate.fromMap(
          Map<Object?, Object?>.from(pending!['candidate'] as Map),
        );
        _downloadId = pending['downloadId'] as int;
        await _pollDownload();
        if (status == AndroidUpdateStatus.downloading) _startPolling();
      }
      if (status != AndroidUpdateStatus.downloaded &&
          status != AndroidUpdateStatus.downloading) {
        await check();
      }
    } catch (error) {
      _fail(_friendlyError(error));
    }
  }

  Future<void> check() async {
    if (_operationBusy || status == AndroidUpdateStatus.downloading) {
      return;
    }
    _operationBusy = true;
    _setStatus(AndroidUpdateStatus.checking);
    try {
      final info = await _methodChannel.invokeMapMethod<Object?, Object?>(
        'getDeviceInfo',
      );
      if (info == null) throw const FormatException();
      currentVersion = info['versionName'] as String?;
      currentBuild = info['versionCode'] as int?;
      final response = await _getJson(Uri.parse(_apiUrl), _maxReleaseBytes);
      if (response.statusCode == HttpStatus.notFound) {
        throw const _UpdateException('Ainda não há uma versão publicada.');
      }
      if (response.statusCode != HttpStatus.ok) {
        throw const _UpdateException('Não foi possível consultar o GitHub.');
      }
      final release = jsonDecode(utf8.decode(response.body));
      if (release is! Map ||
          release['draft'] != false ||
          release['prerelease'] != false) {
        throw const _UpdateException('A publicação mais recente é inválida.');
      }
      final tag = release['tag_name'];
      final releaseUrl = release['html_url'];
      final body = release['body'];
      final assets = release['assets'];
      if (tag is! String ||
          !RegExp(r'^v\d+\.\d+\.\d+$').hasMatch(tag) ||
          releaseUrl !=
              'https://github.com/$_owner/$_repository/releases/tag/$tag' ||
          assets is! List) {
        throw const _UpdateException('Os dados da release não são válidos.');
      }
      final catalogAsset = _asset(assets, _catalogName);
      final apkAsset = _asset(assets, _apkName);
      final catalogUrl = _assetUrl(catalogAsset, tag, _catalogName);
      final apkUrl = _assetUrl(apkAsset, tag, _apkName);
      final catalogDigest = _digest(catalogAsset, _maxCatalogBytes);
      final apkDigest = _digest(apkAsset, _maxApkBytes);
      final catalogResponse = await _getBytes(catalogUrl, _maxCatalogBytes);
      if (catalogResponse.statusCode != HttpStatus.ok ||
          _sha256(catalogResponse.body) != catalogDigest) {
        throw const _UpdateException(
          'O catálogo da atualização está inválido.',
        );
      }
      final catalog = jsonDecode(utf8.decode(catalogResponse.body));
      if (catalog is! Map ||
          catalog['packageName'] != info['packageName'] ||
          catalog['versionName'] != tag.substring(1) ||
          catalog['versionCode'] is! int ||
          catalog['assetName'] != _apkName ||
          catalog['downloadUrl'] != apkUrl.toString() ||
          catalog['releaseUrl'] != releaseUrl ||
          catalog['sha256'] != apkDigest ||
          catalog['size'] != apkAsset['size'] ||
          catalog['signerSha256'] is! String ||
          !RegExp(
            r'^[a-fA-F0-9]{64}$',
          ).hasMatch(catalog['signerSha256'] as String) ||
          catalog['minSdk'] is! int ||
          catalog['abis'] is! List) {
        throw const _UpdateException(
          'O APK publicado não corresponde ao catálogo.',
        );
      }
      final versionCode = catalog['versionCode'] as int;
      final minSdk = catalog['minSdk'] as int;
      final sdkInt = info['sdkInt'];
      final abis = info['abis'];
      if (versionCode <= (currentBuild ?? 0)) {
        candidate = null;
        _setStatus(AndroidUpdateStatus.upToDate);
        return;
      }
      if (sdkInt is! int ||
          sdkInt < minSdk ||
          abis is! List ||
          !(catalog['abis'] as List).any((abi) => abis.contains(abi))) {
        throw const _UpdateException(
          'Esta versão não é compatível com este celular.',
        );
      }
      candidate = AndroidUpdateCandidate(
        version: catalog['versionName'] as String,
        versionCode: versionCode,
        size: catalog['size'] as int,
        sha256: apkDigest,
        signerSha256: (catalog['signerSha256'] as String).toLowerCase(),
        downloadUrl: apkUrl.toString(),
        releaseUrl: releaseUrl as String,
        notes: body is String ? body : '',
      );
      final installedSigners = info['signerSha256'];
      if (installedSigners is! List ||
          !installedSigners.contains(candidate!.signerSha256)) {
        _setStatus(AndroidUpdateStatus.manualInstallRequired);
      } else {
        _setStatus(AndroidUpdateStatus.available);
      }
    } catch (error) {
      _fail(_friendlyError(error));
    } finally {
      _operationBusy = false;
    }
  }

  Future<void> approveDownload() async {
    final update = candidate;
    if (update == null || status != AndroidUpdateStatus.available) return;
    _operationBusy = true;
    try {
      final result = await _methodChannel.invokeMapMethod<Object?, Object?>(
        'enqueueDownload',
        update.toMap(),
      );
      if (result?['downloadId'] is! int) {
        throw const _UpdateException('O download não pôde ser iniciado.');
      }
      _downloadId = result!['downloadId'] as int;
      progressPercent = 0;
      _setStatus(AndroidUpdateStatus.downloading);
      _startPolling();
    } catch (error) {
      _fail(_friendlyError(error));
    } finally {
      _operationBusy = false;
    }
  }

  Future<void> cancelDownload() async {
    final id = _downloadId;
    if (id == null) return;
    _downloadPolling?.cancel();
    try {
      await _methodChannel.invokeMethod<void>('cancelDownload', id);
      _downloadId = null;
      progressPercent = 0;
      _setStatus(AndroidUpdateStatus.available);
    } catch (error) {
      _fail(_friendlyError(error));
    }
  }

  Future<void> install() async {
    final update = candidate;
    final id = _downloadId;
    if (update == null ||
        id == null ||
        !{
          AndroidUpdateStatus.downloaded,
          AndroidUpdateStatus.permissionRequired,
        }.contains(status)) {
      return;
    }
    try {
      final result = await _methodChannel.invokeMethod<String>(
        'installDownload',
        {'downloadId': id, 'candidate': update.toMap()},
      );
      if (result == 'permissionRequired') {
        _setStatus(AndroidUpdateStatus.permissionRequired);
      } else {
        _setStatus(AndroidUpdateStatus.installing);
      }
    } catch (error) {
      _fail(_friendlyError(error));
    }
  }

  Future<void> openReleasePage() async {
    final url = candidate?.releaseUrl;
    if (url == null) return;
    try {
      await _methodChannel.invokeMethod<void>('openReleasePage', url);
    } on Object {
      // The release page remains available through the in-app update actions.
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed &&
        (status == AndroidUpdateStatus.installing ||
            status == AndroidUpdateStatus.permissionRequired)) {
      unawaited(_resumeAfterInstaller());
    }
  }

  Future<void> _resumeAfterInstaller() async {
    try {
      final info = await _methodChannel.invokeMapMethod<Object?, Object?>(
        'getDeviceInfo',
      );
      if (info == null) return;
      currentVersion = info['versionName'] as String?;
      currentBuild = info['versionCode'] as int?;
      final update = candidate;
      if (update != null && (currentBuild ?? 0) >= update.versionCode) {
        _downloadId = null;
        candidate = null;
        _setStatus(AndroidUpdateStatus.upToDate);
        return;
      }
      if (status == AndroidUpdateStatus.permissionRequired) {
        final allowed = await _methodChannel.invokeMethod<bool>(
          'canInstallPackages',
        );
        if (allowed == true) _setStatus(AndroidUpdateStatus.downloaded);
        return;
      }
      if (_downloadId != null) {
        _setStatus(AndroidUpdateStatus.downloaded);
      } else {
        await check();
      }
    } catch (error) {
      _fail(_friendlyError(error));
    }
  }

  void _startPolling() {
    _downloadPolling?.cancel();
    _downloadPolling = Timer.periodic(
      const Duration(seconds: 1),
      (_) => unawaited(_pollDownload()),
    );
    unawaited(_pollDownload());
  }

  Future<void> _pollDownload() async {
    final id = _downloadId;
    if (id == null || _operationBusy) return;
    _operationBusy = true;
    try {
      final result = await _methodChannel.invokeMapMethod<Object?, Object?>(
        'getDownloadState',
        {'downloadId': id, 'candidate': candidate?.toMap()},
      );
      switch (result?['status']) {
        case 'running':
          final downloaded = result?['downloadedBytes'];
          final total = result?['totalBytes'];
          if (downloaded is int && total is int && total > 0) {
            progressPercent = (downloaded * 100 / total).round().clamp(0, 100);
          }
          _setStatus(AndroidUpdateStatus.downloading);
        case 'complete':
          progressPercent = 100;
          _downloadPolling?.cancel();
          _setStatus(AndroidUpdateStatus.downloaded);
        case 'failed':
          _downloadPolling?.cancel();
          _fail('O download falhou. Verifique a conexão e tente novamente.');
        default:
          break;
      }
    } catch (error) {
      _downloadPolling?.cancel();
      _fail(_friendlyError(error));
    } finally {
      _operationBusy = false;
    }
  }

  void _setStatus(AndroidUpdateStatus value) {
    status = value;
    errorMessage = null;
    notifyListeners();
  }

  void _fail(String message) {
    status = AndroidUpdateStatus.failed;
    errorMessage = message;
    notifyListeners();
  }

  Future<_HttpResult> _getJson(Uri uri, int maxBytes) =>
      _getBytes(uri, maxBytes);

  Future<_HttpResult> _getBytes(Uri initial, int maxBytes) async {
    var uri = initial;
    for (var redirect = 0; redirect <= 3; redirect++) {
      _validateUri(uri, initial);
      final request = await _httpClient
          .getUrl(uri)
          .timeout(const Duration(seconds: 12));
      request.followRedirects = false;
      request.headers.set(
        HttpHeaders.acceptHeader,
        'application/vnd.github+json',
      );
      request.headers.set(HttpHeaders.userAgentHeader, 'WindFull-Android');
      request.headers.set('X-GitHub-Api-Version', '2022-11-28');
      final response = await request.close().timeout(
        const Duration(seconds: 20),
      );
      if (response.statusCode >= 300 && response.statusCode < 400) {
        final location = response.headers.value(HttpHeaders.locationHeader);
        await response.drain<void>();
        if (location == null || redirect == 3) {
          throw const _UpdateException(
            'O download redirecionou para um endereço inválido.',
          );
        }
        uri = uri.resolve(location);
        continue;
      }
      final bytes = <int>[];
      await for (final chunk in response.timeout(const Duration(seconds: 20))) {
        if (bytes.length + chunk.length > maxBytes) {
          throw const _UpdateException(
            'O arquivo da atualização excede o limite esperado.',
          );
        }
        bytes.addAll(chunk);
      }
      return _HttpResult(response.statusCode, bytes);
    }
    throw const _UpdateException('Não foi possível acessar o GitHub.');
  }

  static void _validateUri(Uri uri, Uri initial) {
    if (uri.scheme != 'https' || uri.userInfo.isNotEmpty || uri.hasPort) {
      throw const _UpdateException('O GitHub retornou um endereço inseguro.');
    }
    final host = uri.host.toLowerCase();
    final firstHost = initial.host.toLowerCase();
    final valid = firstHost == 'api.github.com'
        ? host == 'api.github.com' &&
              uri.path == initial.path &&
              uri.query == initial.query
        : (host == 'github.com' && uri.path == initial.path) ||
              host == 'release-assets.githubusercontent.com' ||
              host == 'objects.githubusercontent.com';
    if (!valid) {
      throw const _UpdateException('O GitHub retornou um host inválido.');
    }
  }

  static Map<String, Object?> _asset(List assets, String name) {
    final matches = assets.whereType<Map>().where(
      (asset) => asset['name'] == name,
    );
    if (matches.length != 1) {
      throw const _UpdateException(
        'A release está sem um artefato obrigatório.',
      );
    }
    return Map<String, Object?>.from(matches.single);
  }

  static Uri _assetUrl(Map<String, Object?> asset, String tag, String name) {
    final expected =
        'https://github.com/$_owner/$_repository/releases/download/$tag/$name';
    if (asset['browser_download_url'] != expected ||
        asset['state'] != 'uploaded') {
      throw const _UpdateException('O endereço do artefato não é válido.');
    }
    return Uri.parse(expected);
  }

  static String _digest(Map<String, Object?> asset, int maximumSize) {
    final size = asset['size'];
    final digest = asset['digest'];
    if (size is! int ||
        size < 1 ||
        size > maximumSize ||
        digest is! String ||
        !RegExp(r'^sha256:[a-fA-F0-9]{64}$').hasMatch(digest)) {
      throw const _UpdateException('A release não tem digest SHA-256 válido.');
    }
    return digest.substring('sha256:'.length).toLowerCase();
  }

  static String _sha256(List<int> bytes) {
    return sha256.convert(bytes).toString();
  }

  static String _friendlyError(Object error) {
    if (error is _UpdateException) return error.message;
    if (error is PlatformException) {
      return switch (error.code) {
        'network' => 'Não foi possível acessar o GitHub. Confira a conexão.',
        'integrity' =>
          'O arquivo baixado não passou na verificação de integridade.',
        'install_permission' =>
          'Permita a instalação de apps para concluir a atualização.',
        _ => 'A atualização não pôde ser concluída. Tente novamente.',
      };
    }
    if (error is SocketException || error is TimeoutException) {
      return 'Não foi possível acessar o GitHub. Confira a conexão.';
    }
    return 'Não foi possível verificar atualizações agora. Tente novamente.';
  }

  @override
  void dispose() {
    _downloadPolling?.cancel();
    _httpClient.close(force: true);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}

class _HttpResult {
  const _HttpResult(this.statusCode, this.body);
  final int statusCode;
  final List<int> body;
}

class _UpdateException implements Exception {
  const _UpdateException(this.message);
  final String message;
  @override
  String toString() => message;
}
