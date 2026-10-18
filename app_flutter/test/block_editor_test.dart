// 计划块属性面板（鸿蒙端 BlockEditor）的交互测试。

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:classout/data/backup.dart';
import 'package:classout/model/types.dart';
import 'package:classout/domain/plan_math.dart';
import 'package:classout/ui/block_editor.dart';
import 'package:classout/ui/plan_page.dart';

BackupBundle _demo() =>
    BackupBundle.decode(File('assets/demo_backup.json').readAsStringSync());

Future<List<BackupBundle?>> _pump(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.reset);
  final seen = <BackupBundle?>[];
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: StatefulBuilder(
        builder: (context, setState) => PlanPage(
          bundle: seen.isEmpty ? _demo() : seen.last!,
          onChanged: (next) => setState(() => seen.add(next)),
          window: defaultWindow,
          initialDay: DateTime(2026, 10, 16),
          now: () => DateTime(2026, 10, 16, 9, 0),
        ),
      ),
    ),
  ));
  await tester.pumpAndSettle();
  return seen;
}

/// 点开演示数据里 10/16 的那个块（实验报告）
Future<Finder> _openBlock(WidgetTester tester) async {
  final before = _demo().blocks.firstWhere((b) => b.date == '2026-10-16');
  final block = find.byKey(ValueKey('plan-block-${before.id}'));
  await tester.ensureVisible(block);
  await tester.pumpAndSettle();
  // 日期条是浮层：把块挪到它下面再点（直接 drag 滚动会命中块自己的 Listener）
  final pos =
      tester.state<ScrollableState>(find.byType(Scrollable).first).position;
  for (var i = 0; i < 6; i++) {
    if (tester.getRect(block).top > 110) break;
    pos.jumpTo((pos.pixels - 60).clamp(0.0, pos.maxScrollExtent));
    await tester.pumpAndSettle();
  }
  // 鸿蒙两步模型：第一下选中，第二下才打开属性面板
  await tester.tap(block);
  await tester.pumpAndSettle();
  await tester.tap(block);
  await tester.pumpAndSettle();
  return block;
}

void main() {
  testWidgets('点块 → 右侧抽屉出现，显示时间与时长', (tester) async {
    await _pump(tester);
    await _openBlock(tester);

    expect(find.text('实验报告'), findsWidgets);
    expect(find.textContaining('2026-10-16 13:00 - 14:30'), findsOneWidget);
    expect(find.textContaining('（90 分钟）'), findsOneWidget);
    expect(find.text('开始时间（HH:MM）'), findsOneWidget);
    expect(find.text('时长（分钟）'), findsOneWidget);
  });

  testWidgets('开始时间 / 时长输入：错误按鸿蒙原文报，且不改数据', (tester) async {
    final seen = await _pump(tester);
    await _openBlock(tester);
    final before = _demo().blocks.firstWhere((b) => b.id == 1);

    // 时长 10 分钟 → 「一块至少 15 分钟」
    await tester.enterText(
        find.byKey(const ValueKey('block-dur-input')), '10');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(find.text('一块至少 15 分钟'), findsOneWidget);
    expect(seen, isEmpty, reason: '非法输入不落库');

    // 时长 22 分钟 → 不是 5 的倍数
    await tester.enterText(
        find.byKey(const ValueKey('block-dur-input')), '22');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(find.text('时长要是 5 分钟的整数倍'), findsOneWidget);

    // 开始时间写成 25:00 → 格式错
    await tester.enterText(
        find.byKey(const ValueKey('block-start-input')), '25:00');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(find.text('开始时间要写成 HH:MM，比如 14:30'), findsOneWidget);

    // 开始时间 13:07 → 不在 5 分钟刻度上
    await tester.enterText(
        find.byKey(const ValueKey('block-start-input')), '13:07');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(find.text('开始时间要落在 5 分钟刻度上，比如 14:30'), findsOneWidget);

    // 开始时间 23:00、时长 90 → 放不下
    await tester.enterText(
        find.byKey(const ValueKey('block-start-input')), '23:00');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(find.text('这个开始时间放不下当前时长（会超出 24:00）'), findsOneWidget);

    // 合法输入：13:30 → 时长不变、写回
    await tester.enterText(
        find.byKey(const ValueKey('block-start-input')), '13:30');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(seen, isNotEmpty);
    final after = seen.last!.blocks.firstWhere((b) => b.id == 1);
    expect(after.startMin, 13 * 60 + 30);
    expect(after.endMin - after.startMin,
        before.endMin - before.startMin);
  });

  testWidgets('标记完成 → done 变 true', (tester) async {
    final seen = await _pump(tester);
    await _openBlock(tester);
    await tester.tap(find.text('标记完成'));
    await tester.pumpAndSettle();

    final b = seen.last!;
    final block = b.blocks.firstWhere((x) => x.id == 1);
    expect(block.done, isTrue);
  });

  testWidgets('日期 › → 块挪到第二天', (tester) async {
    final seen = await _pump(tester);
    await _openBlock(tester);
    await tester.tap(find.text('›').last);
    await tester.pumpAndSettle();

    final block = seen.last!.blocks.firstWhere((x) => x.id == 1);
    expect(block.date, '2026-10-17');
  });

  testWidgets('时长 +15 → 结束时间加 15 分钟', (tester) async {
    final seen = await _pump(tester);
    await _openBlock(tester);
    // 第一行是「开始时间」的 ±，第二行才是「时长」的 ±
    await tester.tap(find.text('+15 分').at(1));
    await tester.pumpAndSettle();

    final block = seen.last!.blocks.firstWhere((x) => x.id == 1);
    expect(block.startMin, 13 * 60);
    expect(block.endMin, 14 * 60 + 45);
  });

  testWidgets('移除此块 → 块消失', (tester) async {
    final seen = await _pump(tester);
    await _openBlock(tester);
    await tester.tap(find.text('移除此块'));
    await tester.pumpAndSettle();

    final b = seen.last!;
    expect(b.blocks.any((x) => x.id == 1), isFalse);
  });

  testWidgets('截止「自定义…」→ 选日期 + 时间后写进待办', (tester) async {
    final seen = await _pump(tester);
    await _openBlock(tester);
    await tester.ensureVisible(find.text('自定义…'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('自定义…'));
    await tester.pumpAndSettle();
    // 日期选择器 → 确定；时间选择器 → 确定（Material 默认英文 OK）
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();

    final todo = seen.last!.todos.firstWhere((t) => t.id == 3);
    expect(todo.ddl.length, 16, reason: 'YYYY-MM-DD HH:mm');
    expect(todo.ddl.endsWith('23:59'), isTrue, reason: '初始时间就是原截止的 23:59');
  });

  testWidgets('虚拟课时块标完成 → 那一讲也标完成', (tester) async {
    final demo = _demo();
    final bundle = BackupBundle(
      app: demo.app,
      version: demo.version,
      exportedAt: demo.exportedAt,
      semesters: demo.semesters,
      sectionTimes: demo.sectionTimes,
      courses: demo.courses,
      rules: demo.rules,
      overrides: demo.overrides,
      todos: demo.todos,
      blocks: [
        PlanBlock(
            id: 77,
            todoId: 0,
            lessonId: 5,
            date: '2026-10-16',
            startMin: 10 * 60,
            endMin: 11 * 60 + 30),
      ],
      lessons: [
        VirtualLesson(id: 5, courseId: 1, seq: 1, title: '第一讲'),
      ],
    );
    BackupBundle? last;
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: StatefulBuilder(
          builder: (context, setState) => PlanPage(
            bundle: last ?? bundle,
            onChanged: (next) => setState(() => last = next),
            window: defaultWindow,
            initialDay: DateTime(2026, 10, 16),
            now: () => DateTime(2026, 10, 16, 9, 0),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    final block = find.byKey(const ValueKey('plan-block-77'));
    await tester.ensureVisible(block);
    await tester.pumpAndSettle();
    final pos =
        tester.state<ScrollableState>(find.byType(Scrollable).first).position;
    for (var i = 0; i < 6; i++) {
      if (tester.getRect(block).top > 110) break;
      pos.jumpTo((pos.pixels - 60).clamp(0.0, pos.maxScrollExtent));
      await tester.pumpAndSettle();
    }
    await tester.tap(block);
    await tester.pumpAndSettle();
    await tester.tap(block);
    await tester.pumpAndSettle();
    expect(find.textContaining('第一讲'), findsWidgets);
    await tester.tap(find.text('标记完成'));
    await tester.pumpAndSettle();

    expect(last, isNotNull);
    final l = last!.lessons.firstWhere((x) => x.id == 5);
    expect(l.done, isTrue);
    expect(l.doneAt, greaterThan(0));
  });

  testWidgets('对半分 → 变两块、总时长不变', (tester) async {
    final seen = await _pump(tester);
    await _openBlock(tester);
    // 字段变高之后「对半分」可能要先滚进视口（抽屉内部滚动，鸿蒙也是）
    final half = find.textContaining('对半分');
    await tester.ensureVisible(half);
    await tester.pumpAndSettle();
    await tester.tap(half);
    await tester.pumpAndSettle();

    final blocks = seen.last!.blocks.where((x) => x.todoId == 3).toList();
    expect(blocks.length, 2, reason: '90 分钟拆成 45 + 45');
    blocks.sort((a, b) => a.startMin - b.startMin);
    expect(blocks[0].startMin, 13 * 60);
    expect(blocks[0].endMin, 13 * 60 + 45);
    expect(blocks[1].startMin, 13 * 60 + 45);
    expect(blocks[1].endMin, 14 * 60 + 30);
  });

  testWidgets('删除整个待办：两段式确认，块与待办一起没', (tester) async {
    final demo = BackupBundle.decode(
        File('assets/demo_backup.json').readAsStringSync());
    final block = demo.blocks.first;
    final todoId = block.todoId;
    BackupBundle? last;
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) => TextButton(
            onPressed: () => showBlockEditor(ctx,
                bundle: demo,
                block: block,
                window: defaultWindow,
                onChanged: (next) => last = next),
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    final del = find.text('删除这个待办');
    await tester.ensureVisible(del);
    await tester.pumpAndSettle();
    await tester.tap(del);
    await tester.pumpAndSettle();
    expect(find.text('确定删除整个待办？它在别的日期的块也会一起没。'), findsOneWidget);

    await tester.tap(find.text('删除待办'));
    await tester.pumpAndSettle();
    expect(last, isNotNull);
    expect(last!.todos.any((t) => t.id == todoId), isFalse, reason: '待办被删');
    expect(last!.blocks.any((b) => b.todoId == todoId), isFalse, reason: '所有块一起删');
  });
}
