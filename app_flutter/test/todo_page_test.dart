// 待办页的交互测试：确认 / 完成 / 恢复 / 新建，都要真的改到数据上。

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:classout/data/backup.dart';
import 'package:classout/model/types.dart';
import 'package:classout/ui/app_frame.dart';
import 'package:classout/ui/todo_page.dart';

BackupBundle _demo() =>
    BackupBundle.decode(File('assets/demo_backup.json').readAsStringSync());

Todo _byId(BackupBundle b, int id) => b.todos.firstWhere((t) => t.id == id);

void main() {
  testWidgets('四段都画出来了', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: TodoPage(bundle: _demo(), onChanged: (_) {})),
    ));
    await tester.pumpAndSettle();
    expect(find.text('待确认'), findsOneWidget);
    expect(find.text('即将考试'), findsOneWidget);
    expect(find.text('待办'), findsWidgets);
    expect(find.text('已完成'), findsOneWidget);
    expect(find.text('第 3 周作业'), findsOneWidget);
    expect(find.text('线性代数 期中考试'), findsOneWidget);
    expect(find.text('听力练习'), findsOneWidget);
  });

  testWidgets('点圆圈完成 → 状态变 done 且带时间戳', (tester) async {
    BackupBundle? last;
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: StatefulBuilder(
          builder: (context, setState) => TodoPage(
            bundle: last ?? _demo(),
            onChanged: (next) => setState(() => last = next),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    // ⚠️ 第一张卡是「待确认」，它的圆圈本来就不响应（要先点「确认」）；
    // 这里精确点「实验报告」那张卡里的圆圈
    // 行首那颗「○」是文字（鸿蒙端也是 Text('○')，不是图标）
    final card = find.ancestor(of: find.text('实验报告'), matching: find.byType(Container)).first;
    await tester.tap(find.descendant(of: card, matching: find.text('○')));
    await tester.pumpAndSettle();

    expect(last, isNotNull, reason: '点圆圈应该触发 onChanged');
    final done = last!.todos.where((t) => t.status == TodoStatus.done).toList();
    expect(done.length, 2, reason: '原来 1 条已完成，勾掉一条变 2 条');
    expect(done.any((t) => t.doneAt > 0), isTrue);
  });

  testWidgets('点「确认」→ 待确认变 active', (tester) async {
    BackupBundle? last;
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: StatefulBuilder(
          builder: (context, setState) => TodoPage(
            bundle: last ?? _demo(),
            onChanged: (next) => setState(() => last = next),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认'));
    await tester.pumpAndSettle();
    expect(_byId(last!, 1).status, TodoStatus.active);
    expect(find.text('待确认'), findsNothing);
  });

  testWidgets('点卡片正文 → 编辑已有条目（id/状态/时间戳都保留）', (tester) async {
    BackupBundle? last;
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: StatefulBuilder(
          builder: (context, setState) => TodoPage(
            bundle: last ?? _demo(),
            onChanged: (next) => setState(() => last = next),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    final before = _byId(_demo(), 3);
    await tester.tap(find.text('实验报告'));
    await tester.pumpAndSettle();
    expect(find.text('编辑待办'), findsOneWidget, reason: '点正文应该进编辑窗');

    await tester.enterText(find.byType(TextField).first, '实验报告（改）');
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pumpAndSettle();

    expect(last, isNotNull);
    final after = _byId(last!, 3);
    expect(after.title, '实验报告（改）');
    expect(after.id, before.id, reason: 'id 不能变');
    expect(after.status, before.status, reason: '状态不能因为编辑被重置');
    expect(after.createdAt, before.createdAt);
    expect(after.estimateMin, before.estimateMin);
    // 没新建第二条
    expect(last!.todos.where((t) => t.title == '实验报告（改）').length, 1);
    expect(last!.todos.length, _demo().todos.length);
  });

  testWidgets('新建待办 → 出现在「待办」段里', (tester) async {
    BackupBundle? last;
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: StatefulBuilder(
          builder: (context, setState) => TodoPage(
            bundle: last ?? _demo(),
            onChanged: (next) => setState(() => last = next),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('+ 新建待办'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, '新的作业');
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pumpAndSettle();

    expect(last, isNotNull);
    final created = last!.todos.where((t) => t.title == '新的作业').toList();
    expect(created.length, 1);
    expect(created.first.id, greaterThan(0));
    expect(created.first.status, TodoStatus.active);
    // 界面上也看得到
    expect(find.text('新的作业'), findsOneWidget);
  });
}
