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

void main() {
  testWidgets('选到文件 → 填进输入框 → 导入成功', (tester) async {
    final repo = MemoryRepo();
    final json = File('assets/demo_backup.json')
        .readAsStringSync()
        .replaceAll('演示学期', '文件导入的学期');
    final picker = _FakePicker(text: json);
    await _pump(tester, repo, picker);

    expect(find.text('演示学期'), findsOneWidget);
    await tester.tap(find.text('导入'));
    await tester.pumpAndSettle();

    // 对话框里应有「选择文件…」
    expect(find.text('选择文件…'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('pick-file')));
    await tester.pumpAndSettle();

    expect(picker.calls, 1);
    // 内容已填进输入框（不是直接提交，用户还有机会看/改）
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller?.text.contains('文件导入的学期'), isTrue);

    await tester.tap(find.widgetWithText(FilledButton, '导入'));
    await tester.pumpAndSettle();

    expect(find.text('文件导入的学期'), findsOneWidget);
    expect(find.text('演示学期'), findsNothing);
    expect((await repo.load())?.semester?.name, '文件导入的学期');
  });

  testWidgets('用户取消选择 → 什么都不变', (tester) async {
    final repo = MemoryRepo();
    final picker = _FakePicker(text: null); // 取消
    await _pump(tester, repo, picker);

    await tester.tap(find.text('导入'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('pick-file')));
    await tester.pumpAndSettle();

    expect(picker.calls, 1);
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller?.text, isEmpty, reason: '取消不该写入任何内容');
    await tester.tap(find.widgetWithText(TextButton, '取消'));
    await tester.pumpAndSettle();
    expect(find.text('演示学期'), findsOneWidget);
  });

  testWidgets('文件读失败 → 显示原因且不关窗', (tester) async {
    final repo = MemoryRepo();
    final picker = _FakePicker(error: StateError('读不到文件内容'));
    await _pump(tester, repo, picker);

    await tester.tap(find.text('导入'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('pick-file')));
    await tester.pumpAndSettle();

    expect(find.textContaining('读取文件失败'), findsOneWidget);
    expect(find.text('导入备份'), findsOneWidget, reason: '对话框不能自己关掉');
  });

  testWidgets('选到垃圾 JSON → 导入时在对话框里报错', (tester) async {
    final repo = MemoryRepo();
    final picker = _FakePicker(text: '{"app":"别的App","version":1}');
    await _pump(tester, repo, picker);

    await tester.tap(find.text('导入'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('pick-file')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '导入'));
    await tester.pumpAndSettle();

    expect(find.textContaining('不是 ClassOUT'), findsOneWidget);
    // 取消后数据仍是最初那份
    await tester.tap(find.widgetWithText(TextButton, '取消'));
    await tester.pumpAndSettle();
    expect(find.text('演示学期'), findsOneWidget);
  });
}
