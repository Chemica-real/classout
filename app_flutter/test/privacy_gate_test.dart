// 首启隐私门：未同意时不挂业务子树；同意后才显示 child。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:classout/ui/privacy_gate.dart';

void main() {
  testWidgets('未同意 → 显示隐私政策；同意后进入应用', (tester) async {
    var accepted = false;
    var saved = 0;
    await tester.pumpWidget(MaterialApp(
      home: PrivacyGate(
        isAccepted: () async => accepted,
        accept: () async {
          accepted = true;
          saved++;
        },
        child: const Scaffold(body: Text('APP')),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('APP'), findsNothing);
    expect(find.text('隐私政策'), findsOneWidget);
    expect(find.text('同意并继续'), findsOneWidget);

    await tester.tap(find.text('同意并继续'));
    await tester.pumpAndSettle();
    expect(saved, 1);
    expect(find.text('APP'), findsOneWidget);
  });

  testWidgets('已同意 → 直接进入应用', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: PrivacyGate(
        isAccepted: () async => true,
        child: const Scaffold(body: Text('APP')),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('APP'), findsOneWidget);
  });
}
