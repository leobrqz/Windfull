import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';

import 'desktop_tray_host.dart';
import 'host_controller.dart';
import 'windfull_server_screen.dart';
import 'windfull_theme.dart';
import 'windows_update_controller.dart';

class WindfullServerApp extends StatefulWidget {
  const WindfullServerApp({required this.controller, super.key});

  final WindfullHostController controller;

  @override
  State<WindfullServerApp> createState() => _WindfullServerAppState();
}

class _WindfullServerAppState extends State<WindfullServerApp> {
  final _updates = WindowsUpdateController();

  @override
  void initState() {
    super.initState();
    if (defaultTargetPlatform == TargetPlatform.windows) {
      _updates.initialize();
    }
  }

  @override
  void dispose() {
    _updates.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'WindFull',
    debugShowCheckedModeBanner: false,
    theme: WindfullTheme.build(),
    home: WindfullDesktopHost(
      controller: widget.controller,
      childBuilder: (context, onMinimize, exitApplication) =>
          WindfullServerScreen(
            controller: widget.controller,
            updates: _updates,
            onMinimize: onMinimize,
            onExitApplication: exitApplication,
          ),
    ),
  );
}
