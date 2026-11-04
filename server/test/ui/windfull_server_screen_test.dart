import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:windfull_server/src/ui/host_controller.dart';
import 'package:windfull_server/src/ui/windfull_server_screen.dart';
import 'package:windfull_server/src/ui/windfull_theme.dart';
import 'package:windfull_server/src/ui/windows_update_controller.dart';

void main() {
  testWidgets('renders only appliance capabilities in a compact panel', (
    tester,
  ) async {
    setWindow(tester);
    final controller = TestHostController(
      const HostViewState(
        status: HostStatus.ready,
        applianceConnection: ApplianceConnectionStatus.connected,
        appliance: ApplianceState(
          id: 'unit-1',
          name: 'Sala',
          host: '192.168.1.20',
          isPoweredOn: true,
          targetTemperature: 24,
          minimumTemperature: 16,
          maximumTemperature: 30,
          temperatureStep: 1,
          supportedModes: ['cool', 'auto'],
          mode: 'cool',
          features: {
            'windFree': ApplianceFeatureState(
              label: 'WindFree',
              enabled: false,
            ),
          },
        ),
      ),
    );

    await tester.pumpWidget(app(controller));
    await tester.pumpAndSettle();

    expect(find.text('WindFree'), findsOneWidget);
    expect(find.text('Sleep'), findsNothing);
    expect(find.text('Ambiente'), findsNothing);
    expect(find.text('Sala'), findsOneWidget);
    expect(
      tester.getSize(find.byKey(const ValueKey('popover-panel'))).width,
      380,
    );
  });

  testWidgets('shows a real disconnected state without raw appliance errors', (
    tester,
  ) async {
    setWindow(tester);
    final controller = TestHostController(
      const HostViewState(
        status: HostStatus.ready,
        applianceConnection: ApplianceConnectionStatus.disconnected,
        applianceError: 'Tempo limite ao consultar 192.168.1.20',
      ),
    );

    await tester.pumpWidget(app(controller));
    await tester.pumpAndSettle();

    expect(find.text('desconectado'), findsOneWidget);
    expect(find.textContaining('O ar não respondeu.'), findsOneWidget);
    expect(find.textContaining('192.168.1.20'), findsNothing);
    expect(find.byType(Slider), findsNothing);
  });

  testWidgets('approving a pairing requires comparing the six-digit code', (
    tester,
  ) async {
    setWindow(tester);
    final controller = TestHostController(
      HostViewState(
        status: HostStatus.ready,
        pendingPairings: [
          PendingPairingRequest(
            id: 'pair-1',
            deviceName: 'Celular da Ana',
            verificationCode: '482913',
            expiresAt: DateTime(2026, 11, 3, 18),
          ),
        ],
      ),
    );

    await tester.pumpWidget(app(controller));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Ajustes'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Celulares'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Conferir e aprovar'));
    await tester.pumpAndSettle();
    expect(find.text('482913'), findsOneWidget);
    expect(
      find.textContaining('tamb\u00e9m aparece no celular'),
      findsOneWidget,
    );

    await tester.tap(find.text('Os c\u00f3digos conferem'));
    await tester.pumpAndSettle();
    expect(controller.approvedRequestId, 'pair-1');
  });

  testWidgets('replaces bridge paths and stacks with an actionable message', (
    tester,
  ) async {
    setWindow(tester);
    final controller = TestHostController(
      const HostViewState(
        status: HostStatus.ready,
        applianceConnection: ApplianceConnectionStatus.error,
        applianceError:
            r'bridge_start_failed C:\private\build\windfull-samsung-ocf.exe ProcessException',
      ),
    );

    await tester.pumpWidget(app(controller));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('ponte Samsung n\u00e3o est\u00e1 dispon\u00edvel'),
      findsOneWidget,
    );
    expect(find.textContaining('C:\\private'), findsNothing);
    expect(find.textContaining('ProcessException'), findsNothing);
  });
}

Widget app(TestHostController controller) => MaterialApp(
  theme: WindfullTheme.build(),
  home: WindfullServerScreen(
    controller: controller,
    updates: WindowsUpdateController(),
  ),
);

void setWindow(WidgetTester tester) {
  tester.view.physicalSize = const Size(1440, 1100);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

class TestHostController extends WindfullHostController {
  TestHostController(this.state);

  @override
  HostViewState state;

  String? approvedRequestId;

  @override
  Future<void> start() async {}

  @override
  Future<void> retryServer() async {}

  @override
  Future<void> discoverAppliances() async {}

  @override
  Future<void> selectAppliance(String applianceId) async {}

  @override
  Future<void> configureApplianceManually({
    required String host,
    String? name,
  }) async {}

  @override
  Future<void> setPower(bool enabled) async {}

  @override
  Future<void> setTargetTemperature(double temperature) async {}

  @override
  Future<void> setOperatingMode(String mode) async {}

  @override
  Future<void> setFanSpeed(String speed) async {}

  @override
  Future<void> setFeature(String featureId, bool enabled) async {}

  @override
  Future<void> setEnergyPricePerKWh(double price) async {}

  @override
  Future<void> approvePairingRequest(String requestId) async {
    approvedRequestId = requestId;
  }

  @override
  Future<void> rejectPairingRequest(String requestId) async {}

  @override
  Future<void> revokePairedDevice(String deviceId) async {}

  @override
  Future<void> shutdown() async {}
}
