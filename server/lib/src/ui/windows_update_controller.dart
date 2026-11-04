import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

enum WindowsUpdateStatus {
  idle,
  checking,
  upToDate,
  available,
  downloading,
  downloaded,
  applying,
  notManaged,
  failed,
}

class WindowsUpdateController extends ChangeNotifier {
  static const _methods = MethodChannel('windfull/updater');
  static const _events = EventChannel('windfull/updater_events');

  StreamSubscription<Object?>? _subscription;
  WindowsUpdateStatus status = WindowsUpdateStatus.idle;
  String currentVersion = '—';
  String? availableVersion;
  String? releaseNotes;
  String? errorMessage;
  bool managedInstall = false;
  int progressPercent = 0;
  bool _initialized = false;

  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;
    _subscription = _events.receiveBroadcastStream().listen(
      _onEvent,
      onError: (Object error) => _fail(_friendlyError(error)),
    );
    try {
      final context = await _methods.invokeMapMethod<Object?, Object?>(
        'getContext',
      );
      if (context == null || context['version'] is! String) {
        throw const FormatException('Informações da instalação inválidas.');
      }
      currentVersion = context['version'] as String;
      managedInstall = context['managed'] == true;
      if (!managedInstall) {
        _setStatus(WindowsUpdateStatus.notManaged);
        return;
      }
      await check();
    } catch (error) {
      _fail(_friendlyError(error));
    }
  }

  Future<void> check() async {
    _setStatus(WindowsUpdateStatus.checking);
    try {
      final update = await _methods.invokeMapMethod<Object?, Object?>('check');
      if (update == null) {
        availableVersion = null;
        releaseNotes = null;
        _setStatus(WindowsUpdateStatus.upToDate);
        return;
      }
      if (update['version'] is! String || update['notes'] is! String) {
        throw const FormatException('Metadados da atualização inválidos.');
      }
      availableVersion = update['version'] as String;
      releaseNotes = update['notes'] as String;
      _setStatus(WindowsUpdateStatus.available);
    } catch (error) {
      _fail(_friendlyError(error));
    }
  }

  Future<void> download() async {
    if (status != WindowsUpdateStatus.available) return;
    progressPercent = 0;
    _setStatus(WindowsUpdateStatus.downloading);
    try {
      await _methods.invokeMethod<void>('download');
      progressPercent = 100;
      _setStatus(WindowsUpdateStatus.downloaded);
    } catch (error) {
      _fail(_friendlyError(error));
    }
  }

  Future<bool> apply() async {
    if (status != WindowsUpdateStatus.downloaded) return false;
    _setStatus(WindowsUpdateStatus.applying);
    try {
      await _methods.invokeMethod<void>('apply');
      return true;
    } catch (error) {
      _fail(_friendlyError(error));
      return false;
    }
  }

  Future<void> openReleasePage() async {
    try {
      await _methods.invokeMethod<void>(
        'openReleasePage',
        'https://github.com/leobrqz/Windfull/releases/latest',
      );
    } catch (error) {
      _fail(_friendlyError(error));
    }
  }

  void _onEvent(Object? event) {
    if (event is! Map) return;
    final progress = event['percent'];
    if (progress is int) {
      progressPercent = progress.clamp(0, 100);
      notifyListeners();
    }
    final error = event['error'];
    if (error is String) _fail(_friendlyErrorCode(error));
  }

  void _setStatus(WindowsUpdateStatus value) {
    status = value;
    errorMessage = null;
    notifyListeners();
  }

  void _fail(String message) {
    status = WindowsUpdateStatus.failed;
    errorMessage = message;
    notifyListeners();
  }

  String _friendlyError(Object error) {
    if (error is PlatformException) return _friendlyErrorCode(error.code);
    if (error is FormatException) return error.message;
    return 'Não foi possível concluir a atualização. Tente novamente.';
  }

  String _friendlyErrorCode(String code) => switch (code) {
    'not_managed' =>
      'Instale uma vez o pacote portátil oficial para habilitar atualizações automáticas.',
    'offline' ||
    'timeout' => 'O GitHub não respondeu. Confira a conexão e tente novamente.',
    'insufficient_space' =>
      'Libere espaço em disco antes de baixar a atualização.',
    'folder_access' =>
      'O WindFull não tem permissão para atualizar esta pasta. Extraia o app em uma pasta gravável.',
    'integrity' || 'invalid_metadata' =>
      'A validação do pacote falhou. A atualização foi interrompida.',
    _ => 'Não foi possível concluir a atualização. Tente novamente.',
  };

  @override
  void dispose() {
    unawaited(_subscription?.cancel());
    super.dispose();
  }
}
