// 启动页状态行：首启「正在初始化…」、闲置重启「正在重新启动…」（鸿蒙 restart()）

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:classout/ui/boot_screen.dart';

Future<void> _pump(WidgetTester tester, {required bool restarting}) async {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    home: BootScreen(
      step: 0,
      motto: '',
      ready: false,
      restarting: restarting,
      onReveal: () {},
      onDone: () {},
    ),
  ));
  await tester.pump();
}

void main() {
  testWidgets('首启：状态行是「正在初始化…」', (tester) async {
    await _pump(tester, restarting: false);
    expect(find.text('正在初始化…'), findsOneWidget);
    expect(find.text('正在重新启动…'), findsNothing);
  });

  testWidgets('闲置重启：状态行是「正在重新启动…」', (tester) async {
    await _pump(tester, restarting: true);
    expect(find.text('正在重新启动…'), findsOneWidget);
    expect(find.text('正在初始化…'), findsNothing);
  });
}
