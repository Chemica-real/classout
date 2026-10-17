// 计划页的交互测试：选中待办 → 点网格落块 / ⚡找空档，且不能压在课表或不可排时段上。

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:classout/data/backup.dart';
import 'package:classout/domain/dates.dart';
import 'package:classout/domain/plan_math.dart';
import 'package:classout/domain/timetable.dart';
import 'package:classout/ui/plan_page.dart';

BackupBundle _demo() =>
    BackupBundle.decode(File('assets/demo_backup.json').readAsStringSync());

/// 返回一个"读最新数据"的闭包（StatefulBuilder 持有 last，测试里用 getter 取）
class _Harness {
  BackupBundle? last;
  BackupBundle get current => last ?? _demo();
}

Future<_Harness> _pump(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.reset);
  final h = _Harness();
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: StatefulBuilder(
        builder: (context, setState) => PlanPage(
          bundle: h.current,
          onChanged: (next) => setState(() => h.last = next),
        ),
      ),
    ),
  ));
  await tester.pumpAndSettle();
  return h;
}

void main() {
  testWidgets('页面上有课表灰带和已有的计划块', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: PlanPage(
          bundle: _demo(),
          onChanged: (_) {},
          // 固定看 2026-10-16（周五）：有「线代」课 + 一个计划块
          initialDay: DateTime(2026, 10, 16),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('线代'), findsWidgets, reason: '周五 3-4 节是线代的灰带');
    expect(find.text('实验报告'), findsWidgets, reason: '演示数据在周五放了一个块');
    expect(find.text('10/16 周五'), findsOneWidget);
  });

  testWidgets('选中托盘里的待办 → 点网格 15:00 → 生成计划块', (tester) async {
    final h = await _pump(tester);
    expect(h.last, isNull);

    await tester.tap(find.byKey(const ValueKey('pool-5')));
    await tester.pumpAndSettle();

    final col = find.byKey(const ValueKey('plan-day-2026-10-17'));
    final rect = tester.getRect(col);
    final axis = TimeAxis(defaultWindow);
    final y = rect.top + (15 * 60 - axis.startMin) * 1.0; // 15:00
    await tester.tapAt(Offset(rect.center.dx, y));
    await tester.pumpAndSettle();

    final b = h.last;
    expect(b, isNotNull, reason: '点网格应该新增一块');
    expect(b!.blocks.length, _demo().blocks.length + 1, reason: '只多一块');
    final added = b.blocks.last;
    expect(added.todoId, 5);
    expect(added.date, '2026-10-17');
    expect(added.startMin, 15 * 60, reason: '点哪儿落哪儿（吸附后）');
    expect(added.endMin - added.startMin, 45, reason: '时长用待办的预计耗时');
  });

  testWidgets('⚡找空档：落点不与课表/不可排时段重叠', (tester) async {
    final h = await _pump(tester);

    await tester.tap(find.byKey(const ValueKey('pool-5')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('find-slot')));
    await tester.pumpAndSettle();

    final b = h.last;
    expect(b, isNotNull, reason: '找空档应该生成一个块');
    expect(b!.blocks.length, _demo().blocks.length + 1);
    final added = b.blocks.last;

    // 不与当天的课重叠
    final sem = b.semester!;
    final day = DateTime(2026, 10, 17);
    final sessions = computeWeekSessions(
        sem, b.courses, b.rules, b.overrides, b.sectionTimes, weekOfDate(sem, day));
    for (final s in sessions.where((s) => s.date == formatDate(day))) {
      expect(overlaps(added.startMin, added.endMin, s.startMin, s.endMin), isFalse,
          reason: '压在 ${s.course.label} 上了');
    }
    // 不落在默认不可排时段里
    for (final w in defaultRestWindows()) {
      expect(overlaps(added.startMin, added.endMin, w.$1, w.$2), isFalse,
          reason: '落在不可排时段 ${w.$1}-${w.$2} 里了');
    }
    // 也不和**同一天**已有的块重叠（不同天的块当然可以同时间段）
    for (final other in b.blocks.where(
        (x) => x.id != added.id && x.date == added.date)) {
      expect(overlaps(added.startMin, added.endMin, other.startMin, other.endMin), isFalse,
          reason: '和 ${other.date} 的块撞了');
    }
  });
}
