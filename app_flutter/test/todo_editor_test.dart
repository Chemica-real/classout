// 待办编辑窗（鸿蒙端 EditorPanel）：类型就地新建 / 自定义时长 / 两段式删除。

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:classout/data/backup.dart';
import 'package:classout/ui/todo_editor.dart';

BackupBundle _demo() =>
    BackupBundle.decode(File('assets/demo_backup.json').readAsStringSync());

void main() {
  testWidgets('「＋ 新建类型」原地建类型：立刻选中，并回写设置页那份列表',
      (tester) async {
    final demo = _demo();
    final added = <String>[];
    TodoEditorResult? result;
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) => TextButton(
            onPressed: () async {
              result = await showTodoEditor(ctx,
                  courses: demo.courses,
                  customCategories: const ['社团'],
                  onAddCategory: added.add);
            },
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('todo-new-category')));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const ValueKey('todo-cat-input')), '实验');
    await tester.pumpAndSettle();
    await tester.tap(find.text('添加'));
    await tester.pumpAndSettle();

    expect(added, ['实验']);
    expect(find.text('实验'), findsOneWidget, reason: '新类型应作为胶囊出现');

    await tester.enterText(
        find.byKey(const ValueKey('todo-title')), '写实验报告');
    await tester.tap(find.byKey(const ValueKey('todo-save')));
    await tester.pumpAndSettle();
    expect(result, isNotNull);
    expect(result!.todo!.category, '实验');
  });

  testWidgets('预计耗时「自定义」：输入 25 分钟 → 保存后 estimateMin=25',
      (tester) async {
    final demo = _demo();
    TodoEditorResult? result;
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) => TextButton(
            onPressed: () async {
              result = await showTodoEditor(ctx, courses: demo.courses);
            },
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.enterText(
        find.byKey(const ValueKey('todo-title')), '整理笔记');
    await tester.tap(find.byKey(const ValueKey('todo-est-custom')));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const ValueKey('todo-est-input')), '25');
    await tester.pumpAndSettle();
    // 抽屉内容一多就滚（鸿蒙也是抽屉内滚动），保存按钮在滚动区末尾
    final save = find.byKey(const ValueKey('todo-save'));
    await tester.ensureVisible(save);
    await tester.pumpAndSettle();
    await tester.tap(save);
    await tester.pumpAndSettle();

    expect(result!.todo!.estimateMin, 25);
  });

  testWidgets('已存在的待办：两段式「删除待办 → 确认删除」', (tester) async {
    final demo = _demo();
    final existing = demo.todos.first;
    TodoEditorResult? result;
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) => TextButton(
            onPressed: () async {
              result =
                  await showTodoEditor(ctx, courses: demo.courses, existing: existing);
            },
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.byKey(const ValueKey('todo-delete')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('todo-delete')));
    await tester.pumpAndSettle();
    expect(find.text('确定删除这条待办？删除后不可恢复。'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('todo-delete-confirm')));
    await tester.pumpAndSettle();
    expect(result, isNotNull);
    expect(result!.delete, isTrue);
  });

  testWidgets('截止「自定义…」→ 先选日期再选时间（鸿蒙 pickDateTime）', (tester) async {
    final demo = _demo();
    TodoEditorResult? result;
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) => TextButton(
            onPressed: () async {
              result = await showTodoEditor(ctx, courses: demo.courses);
            },
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.enterText(
        find.byKey(const ValueKey('todo-title')), '自定义截止');
    final custom = find.text('自定义…');
    await tester.ensureVisible(custom);
    await tester.pumpAndSettle();
    await tester.tap(custom);
    await tester.pumpAndSettle();
    // 日期选择器 → OK；时间选择器 → OK
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();

    expect(find.textContaining('截止：'), findsWidgets);
    await tester.tap(find.byKey(const ValueKey('todo-save')));
    await tester.pumpAndSettle();
    expect(result!.todo!.ddl.length, 16);
  });
}
