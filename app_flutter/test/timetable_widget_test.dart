// 课表页的冒烟测试：把演示备份喂进去，确认该出现的东西真的出现了。

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:classout/data/backup.dart';
import 'package:classout/data/repo.dart';
import 'package:classout/domain/timetable.dart';
import 'package:classout/ui/home_shell.dart';
import 'package:classout/ui/timetable_page.dart';

BackupBundle _demo() =>
    BackupBundle.decode(File('assets/demo_backup.json').readAsStringSync());

void main() {
  testWidgets('课表页能画出演示学期', (tester) async {
    final bundle = _demo();
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    final sem0 = bundle.semester!;
    final w0 = weekOfDate(sem0, DateTime.now()).clamp(1, sem0.totalWeeks);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: TimetablePage(bundle: bundle, week: w0))));
    await tester.pumpAndSettle();

    // 页头（学期名 / 第 N 周）在外壳 HomeShell 上，这里只测表格本体
    // 七天表头
    expect(find.text('周一'), findsOneWidget);
    expect(find.text('周日'), findsOneWidget);
    // 四门演示课的短名（第一周都该有课）
    final sem = bundle.semester!;
    final w = weekOfDate(sem, DateTime.now()).clamp(1, sem.totalWeeks);
    final sessions = computeWeekSessions(sem, bundle.courses, bundle.rules,
        bundle.overrides, bundle.sectionTimes, w);
    for (final s in sessions) {
      expect(find.text(s.course.label), findsWidgets,
          reason: '第 $w 周应该有「${s.course.label}」的课');
    }
  });

  testWidgets('左右切换周次', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    // 周次状态在**外壳**（页头也那儿），所以这条走 HomeShell
    final repo = MemoryRepo(_demo());
    await tester.pumpWidget(MaterialApp(home: HomeShell(repo: repo, fallback: _demo())));
    await tester.pumpAndSettle();

    final sem = _demo().semester!;
    final start = weekOfDate(sem, DateTime.now()).clamp(1, sem.totalWeeks);
    expect(find.text('第 $start 周'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.chevron_right));
    await tester.pumpAndSettle();
    final next = (start + 1).clamp(1, sem.totalWeeks);
    expect(find.text('第 $next 周'), findsOneWidget);
  });
}
