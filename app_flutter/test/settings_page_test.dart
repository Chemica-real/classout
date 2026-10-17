// 设置页：改动要真的落到 kv / 数据上，并反馈到其它页面。

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:classout/data/backup.dart';
import 'package:classout/data/repo.dart';
import 'package:classout/data/settings.dart';
import 'package:classout/domain/plan_math.dart';
import 'package:classout/ui/home_shell.dart';

BackupBundle _demo() =>
    BackupBundle.decode(File('assets/demo_backup.json').readAsStringSync());

Future<void> _pump(WidgetTester tester, MemoryRepo repo) async {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(home: HomeShell(repo: repo, fallback: _demo())));
  await tester.pumpAndSettle();
  await tester.tap(find.text('设置').last); // 底部导航
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('同步节奏改完写进 kv', (tester) async {
    final repo = MemoryRepo();
    await _pump(tester, repo);
    expect(find.text('设置'), findsWidgets);

    await tester.tap(find.text('15 分钟'));
    await tester.pumpAndSettle();
    expect(await repo.getKv('sync_interval_min'), '15');
  });

  testWidgets('时间范围加减 30 分钟后规范化并保存', (tester) async {
    final repo = MemoryRepo();
    await _pump(tester, repo);

    // 默认 07:00–24:00，点"开始时间 +"→ 07:30
    final plusButtons = find.byIcon(Icons.add);
    // 第一个 add 是"开始时间 +"（后面还有"新建类型"/"添加时段"的图标按键）
    await tester.tap(plusButtons.first);
    await tester.pumpAndSettle();

    final saved = parseWindow((await repo.getKv('plan_window'))!);
    expect(saved.startMin, 7 * 60 + 30);
    expect(saved.endMin, 24 * 60);
  });

  testWidgets('新建待办类型 → 出现在 chip 里并写进 kv', (tester) async {
    final repo = MemoryRepo();
    await _pump(tester, repo);

    await tester.tap(find.text('新建类型'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, '社团');
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pumpAndSettle();

    expect(await repo.getKv('todo_categories'), '社团');
    expect(find.text('社团'), findsWidgets);
  });

  testWidgets('内置类型不能删（没有删除按钮）', (tester) async {
    final repo = MemoryRepo();
    await _pump(tester, repo);
    for (final label in ['作业', '自学', '考试', '无']) {
      expect(find.text(label), findsWidgets);
    }
    // 内置的 chip 没有 onDeleted → 删除图标数量应该等于自定义类型数量（这里是 0）
    expect(find.byIcon(Icons.cancel), findsNothing);
  });

  testWidgets('不可排时段：删一条后写回数据', (tester) async {
    final repo = MemoryRepo();
    await _pump(tester, repo);
    expect(find.textContaining('午休'), findsWidgets);

    final before = (await repo.load())?.restWindows.length ?? 0;
    await tester.tap(find.text('删除').first);
    await tester.pumpAndSettle();
    final after = (await repo.load())?.restWindows.length ?? 0;
    expect(after, before > 0 ? before - 1 : 0);
  });

  test('AppSettings 默认值与规范化', () async {
    final repo = MemoryRepo();
    final s = await AppSettings.load(repo);
    expect(s.syncIntervalMin, 10);
    expect(s.planWindow, defaultWindow);
    expect(s.customCategories, isEmpty);
    await repo.setKv('sync_interval_min', '999'); // 越界要夹紧
    expect((await AppSettings.load(repo)).syncIntervalMin, 180);
    await repo.setKv('sync_interval_min', '乱写'); // 坏值回默认
    expect((await AppSettings.load(repo)).syncIntervalMin, 10);
  });
}
