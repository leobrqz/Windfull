import 'dart:io';

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import 'src/host/windfull_host.dart';
import 'src/ui/windfull_server_app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  if (Platform.isWindows) {
    await windowManager.ensureInitialized();
    const options = WindowOptions(
      size: Size(380, 680),
      minimumSize: Size(360, 560),
      maximumSize: Size(380, 680),
      center: false,
      title: 'WindFull',
      titleBarStyle: TitleBarStyle.hidden,
      backgroundColor: Colors.transparent,
      alwaysOnTop: true,
      skipTaskbar: true,
    );
    await windowManager.waitUntilReadyToShow(options, () async {
      await windowManager.setAsFrameless();
      await windowManager.setHasShadow(true);
      await windowManager.setResizable(false);
      await windowManager.setMaximizable(false);
      await windowManager.hide();
    });
  }

  runApp(WindfullServerApp(controller: WindfullHost()));
}
