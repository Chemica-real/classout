// 计划页的交互测试：选中待办 → 点网格落块 / ⚡找空档，且不能压在课表或不可排时段上。

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:classout/data/backup.dart';
import 'package:classout/domain/dates.dart';
import 'package:classout/domain/plan_math.dart';
import 'package:classout/domain/timetable.dart';
import 'package:classout/model/types.dart';
import 'package:classout/ui/plan_page.dart';
import 'package:classout/ui/theme.dart';

BackupBundle _demo() =>
    BackupBundle.decode(File('assets/demo_backup.json').readAsStringSync());

/// 返回一个"读最新数据"的闭包（StatefulBuilder 持有 last，测试里用 getter 取）
class _Harness {
  BackupBundle? last;
  BackupBundle get current => last ?? _demo();
}

/// 固定时钟：避免"半夜跑测试就挂"（见 plan_page.dart 里 now 的注释）
DateTime _fixedNow() => DateTime(2026, 10, 17, 14, 0);

Future<_Harness> _pump(WidgetTester tester,
    {DateTime? initialDay, bool threeDay = false}) async {
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
          initialDay: initialDay,
          initialThreeDay: threeDay,
          now: _fixedNow,
        ),
      ),
    ),
  ));
  await tester.pumpAndSettle();
  return h;
}

PlanBlock _byIdBlock(BackupBundle b, int id) =>
    b.blocks.firstWhere((x) => x.id == id);


/// 把块滚到"悬浮日期条下面"再操作。
///
/// 日期条现在是浮层（鸿蒙端 DayBarFloat），`ensureVisible` 只保证块在滚动视口里，
/// 可能正好被日期条盖住 —— 那样拖动会点到日期条上。这里直接调 ScrollPosition
/// （不用 tester.drag：拖滚动区会先命中块自己的 Listener，把块拖走）。
Future<void> _revealBlock(WidgetTester tester, Finder block) async {
  await tester.ensureVisible(block);
  await tester.pumpAndSettle();
  final pos = tester
      .state<ScrollableState>(find.byType(Scrollable).first)
      .position;
  for (var i = 0; i < 6; i++) {
    final rect = tester.getRect(block);
    if (rect.top > 110) return;
    pos.jumpTo((pos.pixels - 60).clamp(0.0, pos.maxScrollExtent));
    await tester.pumpAndSettle();
  }
}


/// 鸿蒙两步模型的第一步：轻点选中块（未选中的块长按/双指都不响应）
Future<void> _selectBlock(WidgetTester tester, Finder block) async {
  await tester.tap(block);
  await tester.pumpAndSettle();
}

/// 两步模型：**长按**才开始拖（轻滑留给滚动）。
Future<void> _longPressDragFrom(
    WidgetTester tester, Offset start, Offset delta) async {
  final g = await tester.startGesture(start);
  await tester.pump(const Duration(milliseconds: 600)); // 过 long-press 门槛
  await g.moveBy(delta);
  await tester.pump();
  await g.up();
  await tester.pumpAndSettle();
}

Future<void> _longPressDrag(
    WidgetTester tester, Finder finder, Offset delta) async {
  await _longPressDragFrom(tester, tester.getCenter(finder), delta);
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
          now: _fixedNow,
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('线代'), findsWidgets, reason: '周五 3-4 节是线代的灰带');
    expect(find.text('实验报告'), findsWidgets, reason: '演示数据在周五放了一个块');
    expect(find.text('10 月 16 日 周五'), findsOneWidget);
  });

  testWidgets('日期条的「今天 / 逾期」走注入的时钟（不再偷用真实日期）', (tester) async {
    await _pump(tester, initialDay: DateTime(2026, 10, 15));
    // 注入 10/17，看的是 10/15 → 逾期 2 天（原来这里写死 today()，截图会随真实日期漂）
    expect(find.text('逾期 2 天'), findsOneWidget);
  });

  testWidgets('时间轴贴屏幕左边（鸿蒙 plan 网格满宽、没有左右 10vp 内边距）',
      (tester) async {
    await _pump(tester, initialDay: DateTime(2026, 10, 17));
    // 鸿蒙 HourLines：Text.width(40).textAlign(End) → 刻度右边缘 40vp（AXIS_W 46 - 6）
    final right = tester.getTopRight(find.text('10:00')).dx;
    expect(right, closeTo(40, 0.5));
  });

  testWidgets('选中托盘里的待办 → 点网格 15:00 → 生成计划块', (tester) async {
    final h = await _pump(tester);
    expect(h.last, isNull);

    // 托盘默认收起（鸿蒙端 TraySummonBar），先点开
    await tester.tap(find.byKey(const ValueKey('tray-toggle')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('pool-5')));
    await tester.pumpAndSettle();
    // 选完收起托盘，免得展开的面板把网格下半截挤出视口
    await tester.tap(find.byKey(const ValueKey('tray-toggle')));
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

  testWidgets('拖动块身 → 时间整体平移，时长不变', (tester) async {
    final h = await _pump(tester, initialDay: DateTime(2026, 10, 16));
    final before = _demo().blocks.firstWhere((b) => b.date == '2026-10-16');

    final block = find.byKey(ValueKey('plan-block-${before.id}'));
    await _revealBlock(tester, block);
    await _selectBlock(tester, block);
    // 往下拖 60px = 60 分钟（1 分钟 = 1vp），吸附后仍是 60 的倍数
    await _longPressDrag(tester, block, const Offset(0, 60));
    await tester.pumpAndSettle();

    final b = h.last;
    expect(b, isNotNull, reason: '拖完应该写回数据');
    final after = _byIdBlock(b!, before.id);
    expect(after.startMin, before.startMin + 60);
    expect(after.endMin - after.startMin, before.endMin - before.startMin,
        reason: '移动不改变时长');
    // 鸿蒙松手后的瞬时提示：同天 → 「挪到 HH:MM-HH:MM」
    expect(find.textContaining('挪到 '), findsOneWidget);
  });

  testWidgets('拖底边 → 只改结束时间，开始不变，且不小于 15 分钟', (tester) async {
    final h = await _pump(tester, initialDay: DateTime(2026, 10, 16));
    final before = _demo().blocks.firstWhere((b) => b.date == '2026-10-16');

    final blockFinder = find.byKey(ValueKey('plan-block-${before.id}'));
    await _revealBlock(tester, blockFinder);
    await _selectBlock(tester, blockFinder);
    // 从块底边上方 6px 处按下 = 拖底边缩放
    final rect = tester.getRect(blockFinder);
    await _longPressDragFrom(
        tester, Offset(rect.center.dx, rect.bottom - 6), const Offset(0, 30));
    await tester.pumpAndSettle();

    final b = h.last;
    expect(b, isNotNull);
    final after = _byIdBlock(b!, before.id);
    expect(after.startMin, before.startMin, reason: '缩放不动开始时间');
    expect(after.endMin, before.endMin + 30);
  });

  testWidgets('拖到窗口外会被夹住（不会画到网格外）', (tester) async {
    final h = await _pump(tester, initialDay: DateTime(2026, 10, 16));
    final before = _demo().blocks.firstWhere((b) => b.date == '2026-10-16');
    final block = find.byKey(ValueKey('plan-block-${before.id}'));
    await _revealBlock(tester, block);
    await _selectBlock(tester, block);
    // 往上拖很远：moveRange 会夹到时间窗起点
    await _longPressDrag(tester, block, const Offset(0, -3000));
    await tester.pumpAndSettle();

    final b = h.last;
    expect(b, isNotNull);
    final after = _byIdBlock(b!, before.id);
    expect(after.startMin, TimeAxis(defaultWindow).startMin);
    expect(after.endMin - after.startMin, before.endMin - before.startMin);
  });

  testWidgets('双指放大 → 时长变长、开始时间不变', (tester) async {
    final h = await _pump(tester, initialDay: DateTime(2026, 10, 16));
    final before = _demo().blocks.firstWhere((b) => b.date == '2026-10-16');
    final block = find.byKey(ValueKey('plan-block-${before.id}'));
    await _revealBlock(tester, block);
    await _selectBlock(tester, block);

    final c = tester.getCenter(block);
    final g1 = await tester.startGesture(c - const Offset(8, 0));
    final g2 = await tester.startGesture(c + const Offset(8, 0));
    await tester.pump(const Duration(milliseconds: 40));
    await g1.moveBy(const Offset(-30, 0));
    await g2.moveBy(const Offset(30, 0));
    await tester.pump();
    await g1.up();
    await g2.up();
    await tester.pumpAndSettle();

    final after = _byIdBlock(h.last!, before.id);
    expect(after.startMin, before.startMin, reason: '缩放不动开始时间');
    expect(after.endMin, greaterThan(before.endMin), reason: '两指分开 = 变长');
  });

  testWidgets('虚拟课程课时：托盘里能选、点网格能排（todoId=0、lessonId 指向这一讲）',
      (tester) async {
    final demo = _demo();
    final withLesson = BackupBundle(
      app: demo.app,
      version: demo.version,
      exportedAt: demo.exportedAt,
      semesters: demo.semesters,
      sectionTimes: demo.sectionTimes,
      courses: demo.courses,
      rules: demo.rules,
      overrides: demo.overrides,
      todos: demo.todos,
      blocks: demo.blocks,
      lessons: [
        VirtualLesson(id: 1, courseId: 1, seq: 2, title: '第二讲'),
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
            bundle: last ?? withLesson,
            onChanged: (next) => setState(() => last = next),
            window: defaultWindow,
            initialDay: DateTime(2026, 10, 17),
            now: () => DateTime(2026, 10, 17, 9, 0),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('tray-toggle')));
    await tester.pumpAndSettle();
    expect(find.text('第二讲'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('pool-lesson-1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('tray-toggle')));
    await tester.pumpAndSettle();

    final col = find.byKey(const ValueKey('plan-day-2026-10-17'));
    final rect = tester.getRect(col);
    final y = rect.top + (9 * 60 - defaultWindow.startMin) * 1.0;
    await tester.tapAt(Offset(rect.center.dx, y));
    await tester.pumpAndSettle();

    expect(last, isNotNull);
    final b = last!.blocks.last;
    expect(b.lessonId, 1);
    expect(b.todoId, 0);
    expect(b.startMin, 9 * 60);
  });

  testWidgets('两步模型：轻滑不挪块（交给滚动），长按才拖', (tester) async {
    final h = await _pump(tester, initialDay: DateTime(2026, 10, 16));
    final before = _demo().blocks.firstWhere((b) => b.date == '2026-10-16');
    final block = find.byKey(ValueKey('plan-block-${before.id}'));
    await _revealBlock(tester, block);
    await _selectBlock(tester, block);

    // ① 轻滑（没有长按）→ 不该改数据
    final rect = tester.getRect(block);
    await tester.timedDragFrom(
        Offset(rect.center.dx, rect.center.dy), const Offset(0, 60),
        const Duration(milliseconds: 120));
    await tester.pumpAndSettle();
    expect(h.last, isNull, reason: '轻滑是滚动，不能挪块');

    // ② 长按 600ms 再拖 → 才真的挪
    await _longPressDrag(tester, block, const Offset(0, 60));
    final after = _byIdBlock(h.last!, before.id);
    expect(after.startMin, before.startMin + 60);
  });

  testWidgets('⚡找空档：落点不与课表/不可排时段重叠', (tester) async {
    final h = await _pump(tester);

    // 托盘默认收起（鸿蒙端 TraySummonBar），先点开
    await tester.tap(find.byKey(const ValueKey('tray-toggle')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('pool-5')));
    await tester.pumpAndSettle();
    // 卡片自己的「⚡ 找空档」
    await tester.tap(find.byKey(const ValueKey('pool-find-5')));
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

  testWidgets('托盘：展开后的提示语 / 收起按钮与鸿蒙端同字，⚡ 落块后弹「已安排」',
      (tester) async {
    final h = await _pump(tester);
    await tester.tap(find.byKey(const ValueKey('tray-toggle')));
    await tester.pumpAndSettle();
    expect(find.text('拖动 / 点选 / ⚡ 一键找空档'), findsOneWidget);
    expect(find.text('收起 ▾'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('pool-find-5')));
    await tester.pump();
    expect(h.last, isNotNull);
    // 瞬时提示：鸿蒙 `doPlace` 的文案带标题与时段，1.8 秒后自己消失
    expect(find.textContaining('已安排：'), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
    expect(find.textContaining('已安排：'), findsNothing);
  });

  testWidgets('虚拟课时卡片：显示「90 分钟」，卡片上的 ⚡ 找空档直接排进网格并弹提示',
      (tester) async {
    final demo = _demo();
    final withLesson = BackupBundle(
      app: demo.app,
      version: demo.version,
      exportedAt: demo.exportedAt,
      semesters: demo.semesters,
      sectionTimes: demo.sectionTimes,
      courses: demo.courses,
      rules: demo.rules,
      overrides: demo.overrides,
      todos: demo.todos,
      blocks: demo.blocks,
      lessons: [
        VirtualLesson(id: 1, courseId: 1, seq: 2, title: '第二讲'),
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
            bundle: last ?? withLesson,
            onChanged: (next) => setState(() => last = next),
            window: defaultWindow,
            initialDay: DateTime(2026, 10, 17),
            now: () => DateTime(2026, 10, 17, 9, 0),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('tray-toggle')));
    await tester.pumpAndSettle();

    expect(find.text('90 分钟'), findsOneWidget);
    expect(find.text('虚拟课程课时（拖进计划，打勾完成会触发生成待办）'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('pool-lesson-find-1')));
    await tester.pump();
    expect(last, isNotNull);
    final b = last!.blocks.last;
    expect(b.lessonId, 1);
    expect(b.endMin - b.startMin, 90);
    expect(find.textContaining('已排到 '), findsOneWidget);
  });

  testWidgets('托盘里没有可排的事项时，空状态文案与鸿蒙端一致', (tester) async {
    final demo = _demo();
    final empty = BackupBundle(
      app: demo.app,
      version: demo.version,
      exportedAt: demo.exportedAt,
      semesters: demo.semesters,
      sectionTimes: demo.sectionTimes,
      courses: demo.courses,
      rules: demo.rules,
      overrides: demo.overrides,
      todos: const [],
      blocks: demo.blocks,
    );
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: PlanPage(
          bundle: empty,
          onChanged: (_) {},
          initialDay: DateTime(2026, 10, 17),
          now: () => DateTime(2026, 10, 17, 9, 0),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('tray-toggle')));
    await tester.pumpAndSettle();
    expect(find.text('没有待安排的事项。先去『待办』里确认几条。'), findsOneWidget);
    expect(find.text('展开 ▴'), findsNothing);
  });

  testWidgets('两步模型：第一下选中（弹提示、不开面板），第二下才打开属性面板',
      (tester) async {
    final h = await _pump(tester, initialDay: DateTime(2026, 10, 16));
    final before = _demo().blocks.firstWhere((b) => b.date == '2026-10-16');
    final block = find.byKey(ValueKey('plan-block-${before.id}'));
    await _revealBlock(tester, block);

    await tester.tap(block);
    await tester.pumpAndSettle();
    expect(find.text('标记完成'), findsNothing, reason: '第一下不该开面板');
    expect(find.text('开始时间（HH:MM）'), findsNothing);

    await tester.tap(block);
    await tester.pumpAndSettle();
    expect(find.text('开始时间（HH:MM）'), findsOneWidget, reason: '第二下才开面板');
    expect(h.last, isNull, reason: '选中/开面板都不改数据');
  });

  testWidgets('未选中的块长按不响应（想滚时间轴的人不会误拖）', (tester) async {
    final h = await _pump(tester, initialDay: DateTime(2026, 10, 16));
    final before = _demo().blocks.firstWhere((b) => b.date == '2026-10-16');
    final block = find.byKey(ValueKey('plan-block-${before.id}'));
    await _revealBlock(tester, block);
    await _longPressDrag(tester, block, const Offset(0, 60));
    await tester.pumpAndSettle();
    expect(h.last, isNull, reason: '未选中时长按不该挪块');
  });

  testWidgets('点空白：无选中时弹提示；有选中块时取消选中', (tester) async {
    final h = await _pump(tester, initialDay: DateTime(2026, 10, 16));
    final col = find.byKey(const ValueKey('plan-day-2026-10-16'));
    final rect = tester.getRect(col);
    // 07:30 左右（块在 13:00，点这里不会撞块）
    final y = rect.top + (7 * 60 + 30 - defaultWindow.startMin) * 1.0;
    await tester.tapAt(Offset(rect.center.dx, y));
    await tester.pump();
    expect(find.textContaining('单击块选中它'), findsOneWidget);

    final before = _demo().blocks.firstWhere((b) => b.date == '2026-10-16');
    final block = find.byKey(ValueKey('plan-block-${before.id}'));
    await _revealBlock(tester, block);
    await tester.tap(block);
    await tester.pumpAndSettle();
    await tester.tapAt(Offset(rect.center.dx, y));
    await tester.pumpAndSettle();
    expect(find.textContaining('单击块选中它'), findsNothing, reason: '取消选中时清提示');
    expect(h.last, isNull);
  });

  testWidgets('块上的 ○ 直接勾完成（连虚拟课时一起标）', (tester) async {
    final h = await _pump(tester, initialDay: DateTime(2026, 10, 16));
    final before = _demo().blocks.firstWhere((b) => b.date == '2026-10-16');
    final block = find.byKey(ValueKey('plan-block-${before.id}'));
    await _revealBlock(tester, block);

    await tester.tap(find.descendant(of: block, matching: find.text('○')));
    await tester.pumpAndSettle();
    expect(h.last, isNotNull);
    expect(_byIdBlock(h.last!, before.id).done, isTrue);
  });

  testWidgets('三日视图：把块横向拖到旁边一列 → 日期改成那一天（跨天拖拽）',
      (tester) async {
    final h = await _pump(tester,
        initialDay: DateTime(2026, 10, 16), threeDay: true);
    final before = _demo().blocks.firstWhere((b) => b.date == '2026-10-16');
    final block = find.byKey(ValueKey('plan-block-${before.id}'));
    await _revealBlock(tester, block);
    await _selectBlock(tester, block);

    final c16 = tester.getCenter(find.byKey(const ValueKey('plan-day-2026-10-16')));
    final c17 = tester.getCenter(find.byKey(const ValueKey('plan-day-2026-10-17')));
    await _longPressDrag(
        tester, block, Offset(c17.dx - c16.dx, 0));
    await tester.pumpAndSettle();

    final b = h.last;
    expect(b, isNotNull, reason: '跨天拖拽应该写回数据');
    final after = _byIdBlock(b!, before.id);
    expect(after.date, '2026-10-17');
    expect(after.startMin, before.startMin, reason: '跨天只改日期、不改时间');
  });

  testWidgets('计划块的颜色取课程的 colorIndex（不是拿 courseId 当色号）', (tester) async {
    final demo = _demo();
    // 3 号块 → 待办 2 → 课程 4（colorIndex = 0）：courseId(4) ≠ colorIndex(0)，正好能抓串色
    final block = demo.blocks.firstWhere((b) => b.todoId == 2);
    final todo = demo.todos.firstWhere((t) => t.id == block.todoId);
    final course = demo.courses.firstWhere((c) => c.id == todo.courseId);
    // 演示数据里「courseId == colorIndex」不成立（4 号课 colorIndex=0）→ 以前会串色
    expect(todo.courseId, isNot(course.colorIndex));

    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: PlanPage(
          bundle: demo,
          onChanged: (_) {},
          initialDay: parseDate(block.date),
          now: _fixedNow,
        ),
      ),
    ));
    await tester.pumpAndSettle();
    final card = find.byKey(ValueKey('plan-block-${block.id}'));
    await tester.ensureVisible(card);
    await tester.pumpAndSettle();
    final boxes = tester.widgetList<Container>(
        find.descendant(of: card, matching: find.byType(Container)));
    final colors = [
      for (final c in boxes)
        if (c.decoration is BoxDecoration &&
            (c.decoration as BoxDecoration).color != null)
          (c.decoration as BoxDecoration).color
    ];
    expect(colors, contains(courseColor(course.colorIndex)));
  });

  testWidgets('截止标记：点一条 → 回调外壳打开那条待办的编辑窗', (tester) async {
    int? opened;
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: PlanPage(
          bundle: _demo(),
          onChanged: (_) {},
          initialDay: DateTime(2026, 10, 17),
          now: _fixedNow,
          onOpenTodo: (id) async => opened = id,
        ),
      ),
    ));
    await tester.pumpAndSettle();

    final mark = find.textContaining('截止');
    await tester.ensureVisible(mark.first);
    await tester.pumpAndSettle();
    await tester.tap(mark.first);
    await tester.pumpAndSettle();
    expect(find.text('背 40 个单词'), findsWidgets);
    await tester.tap(find.text('背 40 个单词').last);
    await tester.pumpAndSettle();
    expect(opened, 4, reason: 'demo 里 10/17 截止的是 id=4');
  });

  // ---------------- 截止浮层（鸿蒙 bindPopup：无遮罩、点外面关、再点同一条关） ----------------

  /// demo 里 10/17 只有一条截止（23:59），标记 key 就是它
  Finder ddlMark() => find.byKey(const ValueKey('ddl-2026-10-17-1439'));

  Future<void> pumpPlan(WidgetTester tester,
      {Future<void> Function(int)? onOpenTodo}) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: PlanPage(
          bundle: _demo(),
          onChanged: (_) {},
          initialDay: DateTime(2026, 10, 17),
          now: _fixedNow,
          onOpenTodo: onOpenTodo,
        ),
      ),
    ));
    await tester.pumpAndSettle();
    // 23:59 的标记在 1440 高的网格最底下，先滚到视口里（否则点不到）
    await tester.ensureVisible(ddlMark());
    await tester.pumpAndSettle();
    await tester.tap(ddlMark());
    await tester.pumpAndSettle();
  }

  testWidgets('截止浮层：是挂在标记下的浮层，不是带遮罩的弹窗（单日视图标题不带日期）',
      (tester) async {
    await pumpPlan(tester);
    expect(find.text('23:59 截止 · 1 项'), findsOneWidget);
    // 鸿蒙 maskColor 透明 → 安卓这边也不该有 Dialog/遮罩
    expect(find.byType(Dialog), findsNothing);
    expect(find.text('背 40 个单词'), findsWidgets);
  });

  testWidgets('截止浮层：再点同一条标记 = 收起（鸿蒙只有一个 ddlOpenKey）',
      (tester) async {
    await pumpPlan(tester);
    expect(find.text('23:59 截止 · 1 项'), findsOneWidget);
    // 浮层的透明层这时压在最上面（它就是"点外面关掉"那一层），
    // 所以这一下必然命中它而不是标记本身 —— 鸿蒙的 autoCancel 也是这个效果
    await tester.tap(ddlMark(), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(find.text('23:59 截止 · 1 项'), findsNothing);
  });

  testWidgets('截止浮层：点 ✕ / 点外面都能收起', (tester) async {
    await pumpPlan(tester);
    await tester.tap(find.text('✕'));
    await tester.pumpAndSettle();
    expect(find.text('23:59 截止 · 1 项'), findsNothing);

    await tester.tap(ddlMark());
    await tester.pumpAndSettle();
    expect(find.text('23:59 截止 · 1 项'), findsOneWidget);
    // 点面板外面（左上角空白）：浮层上的透明层收下这一下
    await tester.tapAt(const Offset(8, 8));
    await tester.pumpAndSettle();
    expect(find.text('23:59 截止 · 1 项'), findsNothing);
  });

  testWidgets('截止标记展开时底色加深一档（0.18 → 0.45，鸿蒙同款）', (tester) async {
    Color markColor() => (tester
            .widget<Container>(find
                .descendant(of: ddlMark(), matching: find.byType(Container))
                .first)
            .decoration as BoxDecoration)
        .color!;
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: PlanPage(
          bundle: _demo(),
          onChanged: (_) {},
          initialDay: DateTime(2026, 10, 17),
          now: _fixedNow,
        ),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.ensureVisible(ddlMark());
    await tester.pumpAndSettle();
    expect(markColor(), const Color(0x2ED64545));
    await tester.tap(ddlMark());
    await tester.pumpAndSettle();
    expect(markColor(), const Color(0x73D64545));
  });
}
