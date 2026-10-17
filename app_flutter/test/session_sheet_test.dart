// 单周调整（停课 / 换教室 / 调课 / 补课 / 撤销）的端到端测试。
//
// 这条链路是鸿蒙端 §27「单周调整」的安卓版：点课表格子里的课 → 弹窗 → 写 SessionOverride，
// 课表页立刻按覆盖层重新算一遍（domain/timetable.dart 已经和鸿蒙端逐条对齐）。

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:classout/data/backup.dart';
import 'package:classout/data/repo.dart';
import 'package:classout/model/types.dart';
import 'package:classout/ui/home_shell.dart';
import 'package:classout/ui/timetable_page.dart';

BackupBundle _demo() =>
    BackupBundle.decode(File('assets/demo_backup.json').readAsStringSync());

String _semesterName(BackupBundle b) => b.semester!.name;

Future<MemoryRepo> _pump(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.reset);
  final repo = MemoryRepo(_demo());
  await tester.pumpWidget(MaterialApp(home: HomeShell(repo: repo, fallback: _demo())));
  await tester.pumpAndSettle();
  expect(find.text(_semesterName(_demo())), findsOneWidget,
      reason: '首页应该画出演示学期');
  return repo;
}

void main() {
  testWidgets('点课程块 → 本周停课 → 生成 cancel 覆盖且课上消失', (tester) async {
    final repo = await _pump(tester);
    // 演示数据里周五 3-4 节是「线代」
    final block = find.descendant(
        of: find.byType(TimetablePage), matching: find.text('线代'));
    expect(block, findsOneWidget, reason: '第 1 周周五应该有线代');
    await tester.tap(block);
    await tester.pumpAndSettle();

    expect(find.text('换教室（只改这一周）'), findsOneWidget, reason: '应该弹出单周调整');
    await tester.tap(find.text('本周停课'));
    await tester.pumpAndSettle();

    final saved = (await repo.load())!;
    expect(saved.overrides.length, 1);
    expect(saved.overrides.first.kind, OverrideKind.cancel);
    expect(saved.overrides.first.courseId, 4); // 线代
    // 这一周那节课不再画出来
    expect(find.descendant(of: find.byType(TimetablePage), matching: find.text('线代')),
        findsNothing);
  });

  testWidgets('换教室 → 卡片地点变成新教室', (tester) async {
    final repo = await _pump(tester);
    await tester.tap(
        find.descendant(of: find.byType(TimetablePage), matching: find.text('线代')));
    await tester.pumpAndSettle();

    final field = find.descendant(
        of: find.byType(Dialog), matching: find.byType(TextField));
    await tester.enterText(field, '理教 209');
    await tester.pumpAndSettle();
    await tester.tap(find.text('换到这儿'));
    await tester.pumpAndSettle();

    final saved = (await repo.load())!;
    expect(saved.overrides.length, 1);
    expect(saved.overrides.first.kind, OverrideKind.room);
    expect(saved.overrides.first.newLocation, '理教 209');
    expect(
        find.descendant(
            of: find.byType(TimetablePage), matching: find.text('理教 209')),
        findsOneWidget);
  });

  testWidgets('＋补课 → 生成 extra 覆盖，那节课出现在课表里', (tester) async {
    final repo = await _pump(tester);
    await tester.tap(find.text('＋补课'));
    await tester.pumpAndSettle();
    expect(find.text('补一节课'), findsOneWidget);
    await tester.tap(find.text('加上这节课'));
    await tester.pumpAndSettle();

    final saved = (await repo.load())!;
    expect(saved.overrides.length, 1);
    expect(saved.overrides.first.kind, OverrideKind.extra);
    // 演示数据第 1 周本来有 3 节高数（周一 1-2、周三 3-4、周三 10 习题课），
    // 补课默认落在周一 1-2 节 → 多一张卡 = 4 张
    expect(find.descendant(of: find.byType(TimetablePage), matching: find.text('高数')),
        findsNWidgets(4));
  });
}
