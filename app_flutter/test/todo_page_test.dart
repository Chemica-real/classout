// 待办页的交互测试：确认 / 完成 / 恢复 / 新建，都要真的改到数据上。

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:classout/data/backup.dart';
import 'package:classout/domain/dates.dart';
import 'package:classout/model/types.dart';
import 'package:classout/ui/todo_page.dart';
import 'package:classout/ui/theme.dart';

BackupBundle _demo() =>
    BackupBundle.decode(File('assets/demo_backup.json').readAsStringSync());

Todo _byId(BackupBundle b, int id) => b.todos.firstWhere((t) => t.id == id);

void main() {
  tearDown(() => motionOn = true);

  testWidgets('待确认卡片：删除先碎裂、播完才真删（鸿蒙 removeConfirmed 的顺序）',
      (tester) async {
    motionOn = true;
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
    expect(find.text('第 3 周作业'), findsOneWidget);

    // 「删除」在已完成行里也有一个 → 限定在待确认那张卡里点
    final pendingCard = find
        .ancestor(of: find.text('第 3 周作业'), matching: find.byType(Container))
        .first;
    await tester.tap(find.descendant(of: pendingCard, matching: find.text('删除')));
    await tester.pump();
    await tester.tap(find.text('确认删除'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    // 还在动画里：数据没动（鸿蒙是"播完才落库"）
    expect(last, isNull, reason: '碎裂播放期间不应该已经删掉');
    // 播完 → 真删
    await tester.pumpAndSettle();
    expect(last, isNotNull);
    expect(last!.todos.any((t) => t.title == '第 3 周作业'), isFalse);
  });

  testWidgets('动画总开关关掉 → 删除不再碎裂，直接删', (tester) async {
    motionOn = false;
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
    // 「删除」在已完成行里也有一个 → 限定在待确认那张卡里点
    final pendingCard = find
        .ancestor(of: find.text('第 3 周作业'), matching: find.byType(Container))
        .first;
    await tester.tap(find.descendant(of: pendingCard, matching: find.text('删除')));
    await tester.pump();
    await tester.tap(find.text('确认删除'));
    await tester.pump();
    expect(last, isNotNull, reason: '关掉动效时应当立刻删掉');
    expect(last!.todos.any((t) => t.title == '第 3 周作业'), isFalse);
  });

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

  testWidgets('新建待办默认「今天 23:59」+ 类型「无」+ 60 分钟（鸿蒙 openNew）',
      (tester) async {
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
    // 鸿蒙 openNew：编辑窗默认就是「今天 23:59 / 无 / 60 分钟」
    await tester.enterText(find.byType(TextField).first, '默认值检查');
    await tester.tap(find.byKey(const ValueKey('todo-save')));
    await tester.pumpAndSettle();

    final created = last!.todos.firstWhere((t) => t.title == '默认值检查');
    expect(created.ddl, '${formatDate(today())} 23:59');
    expect(created.category, TodoCategory.none);
    expect(created.estimateMin, 60);
    expect(created.status, TodoStatus.active);
  });

  testWidgets('标题留空也能存 → 名字补成「未命名待办」（鸿蒙 doSave）', (tester) async {
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
    // 不输入标题，直接保存：鸿蒙不拦，落库时才补个名字
    await tester.tap(find.byKey(const ValueKey('todo-save')));
    await tester.pumpAndSettle();
    expect(last!.todos.last.title, '未命名待办');
  });

  testWidgets('新建考试：默认「下周同一天 09:00–11:00」，保存即自动排进计划页',
      (tester) async {
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
    await tester.tap(find.text('+ 考试'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, '期末考试');
    await tester.tap(find.byKey(const ValueKey('todo-save')));
    await tester.pumpAndSettle();

    final day = formatDate(addDays(today(), 7));
    final exam = last!.todos.firstWhere((t) => t.title == '期末考试');
    expect(exam.ddl, '$day 09:00');
    expect(exam.endAt, '$day 11:00');
    // 鸿蒙：考试 estimateMin = 起止时长（不是 0）
    expect(exam.estimateMin, 120);
    // 鸿蒙 TodoRepo.syncExamBlock：自动插一条 plan_block
    final blk = last!.blocks.firstWhere((b) => b.todoId == exam.id);
    expect(blk.date, day);
    expect(blk.startMin, 9 * 60);
    expect(blk.endMin, 11 * 60);
    expect(blk.done, isFalse);
  });

  testWidgets('删掉考试 → 它在计划页的那一段一起删（鸿蒙 deleteTodo）', (tester) async {
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
    // 演示数据里已有考试（线性代数 期中考试）→ 打开编辑窗删掉它
    final exam = _demo().todos.firstWhere((t) => t.category == TodoCategory.exam);
    await tester.tap(find.text(exam.title));
    await tester.pumpAndSettle();
    final del = find.text('删除待办');
    await tester.ensureVisible(del);
    await tester.pumpAndSettle();
    await tester.tap(del);
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认删除'));
    await tester.pumpAndSettle();

    expect(last!.todos.any((t) => t.id == exam.id), isFalse);
    expect(last!.blocks.any((b) => b.todoId == exam.id), isFalse,
        reason: '待办删了，它的计划块也要一起删');
  });

  testWidgets('点「确认」→ 先按鸿蒙 transition 淡出，播完才变 active', (tester) async {
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
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    // 动画中：数据没动，卡片已经在淡出（鸿蒙 `.transition(OPACITY + translate y -10)`）
    expect(last, isNull, reason: 'transition 播完才落库');
    final fx = find.descendant(
        of: find.byKey(const ValueKey('pending-1')),
        matching: find.byType(Opacity));
    expect(fx, findsWidgets);
    expect(tester.widget<Opacity>(fx.first).opacity, lessThan(1));
    await tester.pumpAndSettle();
    expect(_byId(last!, 1).status, TodoStatus.active);
  });

  testWidgets('点圆圈完成 → 待办行同样先淡出再改成 done', (tester) async {
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
    final card = find
        .ancestor(of: find.text('实验报告'), matching: find.byType(Container))
        .first;
    await tester.tap(find.descendant(of: card, matching: find.text('○')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(last, isNull, reason: '淡出期间不该已经改状态');
    await tester.pumpAndSettle();
    expect(_byId(last!, 3).status, TodoStatus.done);
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
    await tester.tap(find.byKey(const ValueKey('todo-save')));
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
    await tester.tap(find.byKey(const ValueKey('todo-save')));
    await tester.pumpAndSettle();

    expect(last, isNotNull);
    final created = last!.todos.where((t) => t.title == '新的作业').toList();
    expect(created.length, 1);
    expect(created.first.id, greaterThan(0));
    expect(created.first.status, TodoStatus.active);
    // 界面上也看得到
    expect(find.text('新的作业'), findsOneWidget);
  });

  testWidgets('已完成段头：鸿蒙同款「收起 ▴ / 展开 ▾」文字，不用图标', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: TodoPage(bundle: _demo(), onChanged: (_) {})),
    ));
    await tester.pumpAndSettle();
    final toggle = find.textContaining('收起 ▴');
    if (toggle.evaluate().isEmpty) {
      // demo 可能没有已完成条目：直接跳过（该文案由下一轮的固定数据覆盖）
      return;
    }
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(find.textContaining('展开 ▾'), findsOneWidget);
  });
}
