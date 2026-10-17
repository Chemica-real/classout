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

/// 导入入口 = 「管理课程 → 备份与恢复 → 导入备份…」（鸿蒙端同构）
Future<void> _openImport(WidgetTester tester) async {
  // 鸿蒙端入口：课表页 →「管理课程」→ 备份与恢复 → 导入备份…
  if (find.text('设置').evaluate().isNotEmpty) {
    await tester.tap(find.text('课表').last);
    await tester.pumpAndSettle();
  }
  await tester.tap(find.text('管理课程'));
  await tester.pumpAndSettle();
  // 鸿蒙结构：列表首屏三张入口卡 →「备份与恢复」→「从备份文件导入…」
  await tester.tap(find.byKey(const ValueKey('entry-backup')));
  await tester.pumpAndSettle();
  final b = find.byKey(const ValueKey('manager-import'));
  await tester.ensureVisible(b);
  await tester.pumpAndSettle();
  await tester.tap(b);
  await tester.pumpAndSettle();
}

Future<void> _gotoTimetable(WidgetTester tester) async {
  // 鸿蒙恢复完**留在「备份与恢复」页**并显示一行蓝框（不弹提示条），
  // 所以要先按「‹ 返回」把这一页关掉，再退一层「管理课程」，才点得到底部标签栏
  for (var i = 0; i < 2; i++) {
    final back = find.text('‹ 返回');
    if (back.evaluate().isEmpty) break;
    await tester.tap(back.last, warnIfMissed: false);
    await tester.pumpAndSettle();
  }
  // 再退一层「课程与学期」整页
  final close = find.text('关闭');
  if (close.evaluate().isNotEmpty) {
    await tester.tap(close.last, warnIfMissed: false);
    await tester.pumpAndSettle();
  }
  await tester.pump(const Duration(seconds: 1));
  await tester.pumpAndSettle();
  final t = find.text('课表');
  if (t.evaluate().isNotEmpty) {
    await tester.tap(t.last, warnIfMissed: false);
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
    // ⚠️ 设置页自己也有输入框（首页标语），必须限定在导入对话框里
    await tester.enterText(
        find.descendant(
            of: find.byType(AlertDialog), matching: find.byType(TextField)),
        incoming);
    await tester.tap(find.widgetWithText(FilledButton, '导入'));
    await tester.pumpAndSettle();

    await _gotoTimetable(tester);
    expect(find.text('导入学期'), findsOneWidget);
    expect(find.text('演示学期'), findsNothing);
  });

  testWidgets('恢复成功：留在「备份与恢复」页，并在页内显示「已从备份恢复：…」蓝框', (tester) async {
    final demo = BackupBundle.decode(_demoJson());
    await _pump(tester, MemoryRepo(demo));
    await _openImport(tester);
    await tester.enterText(
        find.descendant(
            of: find.byType(AlertDialog), matching: find.byType(TextField)),
        _demoJson().replaceAll('演示学期', '恢复学期'));
    await tester.tap(find.widgetWithText(FilledButton, '导入'));
    await tester.pumpAndSettle();

    // 鸿蒙 BackupView：`backupNote = '已从备份恢复：\n' + backupSummary(bundle)`
    expect(find.text('备份与恢复'), findsWidgets, reason: '不应该关掉这一页');
    expect(find.textContaining('已从备份恢复：'), findsOneWidget);
    expect(find.textContaining('恢复学期'), findsWidgets, reason: '蓝框里应该有摘要');
    // 也没有多出来的 SnackBar
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('粘贴垃圾 → 报错且不关窗、不改数据', (tester) async {
    final demo = BackupBundle.decode(_demoJson());
    await _pump(tester, MemoryRepo(demo));

    await _openImport(tester);
    await tester.enterText(
        find.descendant(
            of: find.byType(AlertDialog), matching: find.byType(TextField)),
        '{"app":"别的App","version":1}');
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
