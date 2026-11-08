// 底部导航的 1 秒冷却：连点时只认第一次，不能一次跳好几个页面。

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:classout/data/backup.dart';
import 'package:classout/data/repo.dart';
import 'package:classout/ui/home_shell.dart';
import 'package:classout/ui/plan_page.dart';
import 'package:classout/ui/todo_page.dart';

BackupBundle _demo() =>
    BackupBundle.decode(File('assets/demo_backup.json').readAsStringSync());

void main() {
  testWidgets('底部 tab：1 秒内连点只生效第一次', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: HomeShell(repo: MemoryRepo(), fallback: _demo()),
    ));
    await tester.pumpAndSettle();
    expect(find.byType(TodoPage), findsNothing);

    // 两次点击之间不 pump，模拟同一秒内的连点
    await tester.tap(find.text('待办').last);
    await tester.tap(find.text('计划').last);
    await tester.pumpAndSettle();

    expect(find.byType(TodoPage), findsOneWidget);
    expect(find.byType(PlanPage), findsNothing);
  });
}
