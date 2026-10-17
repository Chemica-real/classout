// 「从文件导入」这条路的测试：点「选择文件…」→ 内容填进输入框 → 点「导入」→ 数据被替换。
//
// file_picker 是平台插件，测试里用假实现（BackupPicker）注入，
// 这样除"系统文件选择框本身"之外的整条链路都被覆盖。

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:classout/data/backup.dart';
import 'package:classout/data/repo.dart';
import 'package:classout/ui/backup_picker.dart';
import 'package:classout/ui/home_shell.dart';

BackupBundle _demo() =>
    BackupBundle.decode(File('assets/demo_backup.json').readAsStringSync());

class _FakePicker implements BackupPicker {
  final String? text;
  final Object? error;
  int calls = 0;

  _FakePicker({this.text, this.error});

  @override
  Future<String?> pickBackupText() async {
    calls++;
    if (error != null) throw error!;
    return text;
  }
}

Future<void> _pump(WidgetTester tester, MemoryRepo repo, BackupPicker picker) async {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    home: HomeShell(repo: repo, fallback: _demo(), backupPicker: picker),
  ));
  await tester.pumpAndSettle();
}

/// 回到课表页（导入后要看学期名）
Future<void> _gotoTimetable(WidgetTester tester) async {
  // 导入成功的 SnackBar 会盖住底部标签栏，先等它自己消失
  await tester.pump(const Duration(seconds: 5));
  await tester.pumpAndSettle();
  await tester.tap(find.text('课表').last);
  await tester.pumpAndSettle();
}

/// 导入入口在「管理课程 → 备份与恢复 → 导入备份…」
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
  // 安卓专属入口：**长按**「从备份恢复」= 粘贴 / 选文件导入
  final btn = find.byKey(const ValueKey('manager-import'));
  await tester.ensureVisible(btn);
  await tester.pumpAndSettle();
  await tester.longPress(btn);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('选到文件 → 填进输入框 → 导入成功', (tester) async {
    final repo = MemoryRepo();
    final json = File('assets/demo_backup.json')
        .readAsStringSync()
        .replaceAll('演示学期', '文件导入的学期');
    final picker = _FakePicker(text: json);
    await _pump(tester, repo, picker);

    expect(find.text('演示学期'), findsOneWidget);
    await _openImport(tester);

    // 对话框里应有「选择文件…」
    expect(find.text('选择文件…'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('pick-file')));
    await tester.pumpAndSettle();

    expect(picker.calls, 1);
    // 内容已填进输入框（不是直接提交，用户还有机会看/改）
    final field = tester.widget<TextField>(find.descendant(
        of: find.byType(AlertDialog), matching: find.byType(TextField)));
    expect(field.controller?.text.contains('文件导入的学期'), isTrue);

    await tester.tap(find.widgetWithText(FilledButton, '导入'));
    await tester.pumpAndSettle();

    // 先看数据有没有换（失败时能区分"没导入"和"界面没刷新"）
    expect((await repo.load())?.semester?.name, '文件导入的学期',
        reason: '点「导入」后仓库里的学期名应该变了');
    await _gotoTimetable(tester);
    expect(find.text('文件导入的学期'), findsOneWidget);
  });

  testWidgets('用户取消选择 → 什么都不变', (tester) async {
    final repo = MemoryRepo();
    final picker = _FakePicker(text: null); // 取消
    await _pump(tester, repo, picker);

    await _openImport(tester);
    await tester.tap(find.byKey(const ValueKey('pick-file')));
    await tester.pumpAndSettle();

    expect(picker.calls, 1);
    final field = tester.widget<TextField>(find.descendant(
        of: find.byType(AlertDialog), matching: find.byType(TextField)));
    expect(field.controller?.text, isEmpty, reason: '取消不该写入任何内容');
    await tester.tap(find.widgetWithText(TextButton, '取消'));
    await tester.pumpAndSettle();
    expect(find.text('导入备份'), findsNothing, reason: '对话框应该关掉');
    expect((await repo.load())?.semester?.name ?? '演示学期', '演示学期');
  });

  testWidgets('文件读失败 → 显示原因且不关窗', (tester) async {
    final repo = MemoryRepo();
    final picker = _FakePicker(error: StateError('读不到文件内容'));
    await _pump(tester, repo, picker);

    await _openImport(tester);
    await tester.tap(find.byKey(const ValueKey('pick-file')));
    await tester.pumpAndSettle();

    expect(find.textContaining('读取文件失败'), findsOneWidget);
    expect(find.text('导入备份'), findsOneWidget, reason: '对话框不能自己关掉');
  });

  testWidgets('选到垃圾 JSON → 导入时在对话框里报错', (tester) async {
    final repo = MemoryRepo();
    final picker = _FakePicker(text: '{"app":"别的App","version":1}');
    await _pump(tester, repo, picker);

    await _openImport(tester);
    await tester.tap(find.byKey(const ValueKey('pick-file')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '导入'));
    await tester.pumpAndSettle();

    expect(find.textContaining('不是 ClassOUT'), findsOneWidget);
    expect(find.text('导入备份'), findsOneWidget, reason: '报错不关窗');
    await tester.tap(find.widgetWithText(TextButton, '取消'));
    await tester.pumpAndSettle();
    expect((await repo.load())?.semester?.name ?? '演示学期', '演示学期');
  });
}
