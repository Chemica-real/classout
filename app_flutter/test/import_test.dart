// 导入流程的端到端测试：点「导入」→ 粘贴 JSON → 界面换成新数据。
// 这条链路是「把鸿蒙端的数据搬到 iOS/Android」的唯一入口，必须测。

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:classout/data/backup.dart';
import 'package:classout/data/repo.dart';
import 'package:classout/ui/home_shell.dart';

String _demoJson() => File('assets/demo_backup.json').readAsStringSync();

Future<void> _pump(WidgetTester tester, MemoryRepo repo) async {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(home: HomeShell(repo: repo, fallback: BackupBundle.decode(_demoJson()))));
  await tester.pumpAndSettle();
}

/// 导入入口 = 设置页「数据 → 导入备份…」（跟鸿蒙端「管理课程 → 备份与恢复」对应）
Future<void> _openImport(WidgetTester tester) async {
  await tester.tap(find.text('设置').last);
  await tester.pumpAndSettle();
  final b = find.byKey(const ValueKey('settings-import'));
  await tester.ensureVisible(b);
  await tester.pumpAndSettle();
  await tester.tap(b);
  await tester.pumpAndSettle();
}

Future<void> _gotoTimetable(WidgetTester tester) async {
  // 导入成功的 SnackBar 会盖住底部标签栏，先等它自己消失
  await tester.pump(const Duration(seconds: 5));
  await tester.pumpAndSettle();
  final t = find.text('课表');
  if (t.evaluate().isNotEmpty) {
    await tester.tap(t.last);
    await tester.pumpAndSettle();
  }
}

void main() {
  testWidgets('粘贴合法备份 → 数据被整份替换', (tester) async {
    final demo = BackupBundle.decode(_demoJson());
    await _pump(tester, MemoryRepo(demo));
    expect(find.text('演示学期'), findsOneWidget);

    // 把学期名改一下，用于确认"新数据真的进来了"
    final incoming = _demoJson().replaceAll('演示学期', '导入学期');
    await _openImport(tester);
    await tester.enterText(find.byType(TextField), incoming);
    await tester.tap(find.widgetWithText(FilledButton, '导入'));
    await tester.pumpAndSettle();

    await _gotoTimetable(tester);
    expect(find.text('导入学期'), findsOneWidget);
    expect(find.text('演示学期'), findsNothing);
  });

  testWidgets('粘贴垃圾 → 报错且不关窗、不改数据', (tester) async {
    final demo = BackupBundle.decode(_demoJson());
    await _pump(tester, MemoryRepo(demo));

    await _openImport(tester);
    await tester.enterText(find.byType(TextField), '{"app":"别的App","version":1}');
    await tester.tap(find.widgetWithText(FilledButton, '导入'));
    await tester.pumpAndSettle();

    // 还在对话框里，并且给了原因
    expect(find.text('导入备份'), findsOneWidget);
    expect(find.textContaining('不是 ClassOUT'), findsOneWidget);
    // 取消之后数据还是原来的（对话框盖着时底层 widget 仍在树里，所以这里只验取消后的状态）
    await tester.tap(find.widgetWithText(TextButton, '取消'));
    await tester.pumpAndSettle();
    await _gotoTimetable(tester);
    expect(find.text('演示学期'), findsOneWidget);
  });

  testWidgets('空库时用兜底数据，并写回仓库', (tester) async {
    // 演示数据兜底后，课表页应该显示它的学期名
    final demo = BackupBundle.decode(_demoJson());
    final repo = MemoryRepo();
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: HomeShell(repo: repo, fallback: demo)));
    await tester.pumpAndSettle();
    expect(find.text('演示学期'), findsOneWidget);
    expect(await repo.load(), isNotNull, reason: '兜底数据应该被写进仓库');
  });
}
