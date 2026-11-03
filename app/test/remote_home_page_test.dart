import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:windfull_app/main.dart';

void main() {
  testWidgets('mostra desconex\u00e3o e mant\u00e9m comandos indispon\u00edveis',
      (tester) async {
    await tester.pumpWidget(const WindfullApp());

    expect(find.text('SEM CONEX\u00c3O'), findsOneWidget);
    expect(find.text('AGUARDANDO PAREAMENTO'), findsOneWidget);
    expect(find.text('Controles indispon\u00edveis'), findsOneWidget);

    expect(find.byType(Switch), findsNothing);
    await tester.pump(const Duration(seconds: 3));
    await tester.pump();
  });
}
