// 计划块属性面板（鸿蒙端 BlockEditor）的交互测试。

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:classout/data/backup.dart';
import 'package:classout/domain/plan_math.dart';
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
    await tester.tap(find.byIcon(Icons.chevron_right).last);
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

  testWidgets('对半分 → 变两块、总时长不变', (tester) async {
    final seen = await _pump(tester);
    await _openBlock(tester);
    await tester.tap(find.textContaining('对半分'));
    await tester.pumpAndSettle();

    final blocks = seen.last!.blocks.where((x) => x.todoId == 3).toList();
    expect(blocks.length, 2, reason: '90 分钟拆成 45 + 45');
    blocks.sort((a, b) => a.startMin - b.startMin);
    expect(blocks[0].startMin, 13 * 60);
    expect(blocks[0].endMin, 13 * 60 + 45);
    expect(blocks[1].startMin, 13 * 60 + 45);
    expect(blocks[1].endMin, 14 * 60 + 30);
  });
}
