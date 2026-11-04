import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import 'host_controller.dart';

typedef DesktopChildBuilder =
    Widget Function(
      BuildContext context,
      VoidCallback minimizeToTray,
      VoidCallback exitApplication,
    );

/// Owns Windows tray/window lifecycle while leaving host services in the
/// injected controller. Close and minimize requests hide the window; explicit
/// exit shuts down the host before destroying the desktop process.
class WindfullDesktopHost extends StatefulWidget {
  const WindfullDesktopHost({
    required this.controller,
    required this.childBuilder,
    super.key,
  });

  final WindfullHostController controller;
  final DesktopChildBuilder childBuilder;

  @override
  State<WindfullDesktopHost> createState() => _WindfullDesktopHostState();
}

class _WindfullDesktopHostState extends State<WindfullDesktopHost>
    with WindowListener, TrayListener {
  bool _desktopReady = false;
  bool _exiting = false;

  @override
  void initState() {
    super.initState();
    if (Platform.isWindows) {
      _initializeWindowsIntegration();
    } else {
      _desktopReady = true;
    }
  }

  Future<void> _initializeWindowsIntegration() async {
    trayManager.addListener(this);
    windowManager.addListener(this);
    await windowManager.setPreventClose(true);
    await windowManager.setMinimumSize(const Size(360, 560));
    await windowManager.setMaximumSize(const Size(380, 680));
    await windowManager.setAlwaysOnTop(true);
    await windowManager.setSkipTaskbar(true);
    await windowManager.setAsFrameless();
    await windowManager.setHasShadow(false);

    final iconBytes = await rootBundle.load('assets/windfull_tray.ico');
    final supportDirectory = await getApplicationSupportDirectory();
    final iconFile = File(
      '${supportDirectory.path}${Platform.pathSeparator}windfull_tray.ico',
    );
    await iconFile.parent.create(recursive: true);
    await iconFile.writeAsBytes(iconBytes.buffer.asUint8List(), flush: true);
    await trayManager.setIcon(iconFile.path);
    await trayManager.setToolTip('WindFull — controle local');
    await trayManager.setContextMenu(
      Menu(
        items: [
          MenuItem(key: 'show_window', label: 'Abrir'),
          MenuItem.separator(),
          MenuItem(key: 'exit_app', label: 'Fechar'),
        ],
      ),
    );
    _desktopReady = true;
    // The host starts in the notification area. The compact panel is shown
    // only after an explicit tray click or menu action.
  }

  Future<void> _showWindow() async {
    if (!Platform.isWindows || !_desktopReady || _exiting) return;
    await _positionWindowNearTray();
    await windowManager.show();
    await windowManager.focus();
  }

  Future<void> _positionWindowNearTray() async {
    final iconBounds = await trayManager.getBounds();
    final displays = await screenRetriever.getAllDisplays();
    if (displays.isEmpty) return;
    final primary = await screenRetriever.getPrimaryDisplay();
    var display = primary;
    final point =
        iconBounds?.center ?? await screenRetriever.getCursorScreenPoint();
    for (final candidate in displays) {
      final displayPosition = candidate.visiblePosition ?? Offset.zero;
      final displayRect = Rect.fromLTWH(
        displayPosition.dx,
        displayPosition.dy,
        candidate.size.width,
        candidate.size.height,
      );
      if (displayRect.contains(point)) {
        display = candidate;
        break;
      }
    }

    final workOrigin = display.visiblePosition ?? Offset.zero;
    final workSize = display.visibleSize ?? display.size;
    const edgePadding = 8.0;
    const iconGap = 6.0;
    final maxWidth = math.max(1.0, workSize.width - edgePadding * 2);
    final maxHeight = math.max(1.0, workSize.height - edgePadding * 2);
    final currentSize = await windowManager.getSize();
    final size = Size(
      math.min(currentSize.width, maxWidth),
      math.min(currentSize.height, maxHeight),
    );
    if (size != currentSize) await windowManager.setSize(size);

    final desiredLeft = iconBounds == null
        ? workOrigin.dx + workSize.width - size.width - edgePadding
        : iconBounds.center.dx - size.width / 2;
    final enoughSpaceBelow =
        iconBounds != null &&
        workOrigin.dy + workSize.height - iconBounds.center.dy >=
            size.height + iconGap;
    final desiredTop = iconBounds == null
        ? workOrigin.dy + workSize.height - size.height - edgePadding
        : enoughSpaceBelow
        ? iconBounds.center.dy + iconGap
        : iconBounds.center.dy - size.height - iconGap;
    final maxLeft = workOrigin.dx + workSize.width - size.width - edgePadding;
    final maxTop = workOrigin.dy + workSize.height - size.height - edgePadding;
    // A very small work area can be smaller than the platform-enforced
    // minimum window size. Keep the panel as close to the work area as
    // possible without passing an inverted range to clamp().
    final left = maxLeft < workOrigin.dx + edgePadding
        ? workOrigin.dx + edgePadding
        : desiredLeft.clamp(workOrigin.dx + edgePadding, maxLeft).toDouble();
    final top = maxTop < workOrigin.dy + edgePadding
        ? workOrigin.dy + edgePadding
        : desiredTop.clamp(workOrigin.dy + edgePadding, maxTop).toDouble();
    await windowManager.setPosition(Offset(left, top));
  }

  Future<void> _toggleWindow() async {
    if (!Platform.isWindows || !_desktopReady || _exiting) return;
    if (await windowManager.isVisible()) {
      await windowManager.hide();
    } else {
      await _showWindow();
    }
  }

  Future<void> _minimizeToTray() async {
    if (Platform.isWindows && _desktopReady) {
      await windowManager.hide();
    } else {
      await windowManager.minimize();
    }
  }

  Future<void> _exitApplication() async {
    if (_exiting) return;
    _exiting = true;
    try {
      await widget.controller.shutdown();
    } finally {
      if (Platform.isWindows) {
        await trayManager.destroy();
        await windowManager.setPreventClose(false);
        await windowManager.destroy();
      } else {
        await windowManager.close();
      }
    }
  }

  @override
  void onWindowClose() {
    _minimizeToTray();
  }

  @override
  void onWindowMinimize() {
    _minimizeToTray();
  }

  @override
  void onTrayIconMouseDown() {
    _toggleWindow();
  }

  @override
  void onTrayIconRightMouseDown() {
    if (Platform.isWindows && _desktopReady && !_exiting) {
      unawaited(trayManager.popUpContextMenu());
    }
  }

  @override
  void onWindowBlur() {
    if (Platform.isWindows && !_exiting) windowManager.hide();
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case 'show_window':
        _showWindow();
      case 'exit_app':
        _exitApplication();
    }
  }

  @override
  void dispose() {
    if (Platform.isWindows) {
      trayManager.removeListener(this);
      windowManager.removeListener(this);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      widget.childBuilder(context, _minimizeToTray, _exitApplication);
}
