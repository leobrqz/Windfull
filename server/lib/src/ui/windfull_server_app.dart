import 'package:flutter/material.dart';

import 'desktop_tray_host.dart';
import 'host_controller.dart';
import 'windfull_server_screen.dart';
import 'windfull_theme.dart';

class WindfullServerApp extends StatelessWidget {
  const WindfullServerApp({required this.controller, super.key});

  final WindfullHostController controller;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Windfull',
    debugShowCheckedModeBanner: false,
    theme: WindfullTheme.build(),
    home: WindfullDesktopHost(
      controller: controller,
      childBuilder: (context, onMinimize, _) =>
          WindfullServerScreen(controller: controller, onMinimize: onMinimize),
    ),
  );
}
