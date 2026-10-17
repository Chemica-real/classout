// 课程管理（鸿蒙端 CourseManager.ets）的交互测试：
// 改课程、加时段、加模板、删课程，都要真的写回仓库。

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:classout/data/backup.dart';
import 'package:classout/data/repo.dart';
import 'package:classout/model/types.dart';
import 'package:classout/ui/home_shell.dart';

BackupBundle _demo() =>
    BackupBundle.decode(File('assets/demo_backup.json').readAsStringSync());

Future<MemoryRepo> _pump(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.reset);
  final repo = MemoryRepo(_demo());
  await tester.pumpWidget(MaterialApp(home: HomeShell(repo: repo, fallback: _demo())));
  await tester.pumpAndSettle();
  await tester.tap(find.text('管理课程'));
  await tester.pumpAndSettle();
  return repo;
}

Future<void> _tapVisible(WidgetTester tester, Finder f) async {
  await tester.ensureVisible(f);
  await tester.pumpAndSettle();
  await tester.tap(f);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('打开课程管理：列出 4 门课与学期摘要', (tester) async {
    await _pump(tester);
    expect(find.text('管理课程'), findsWidgets);
    expect(find.text('课程 4 门'), findsOneWidget);
    expect(find.textContaining('线代'), findsWidgets);
  });

  testWidgets('改简称 → 写回仓库', (tester) async {
    final repo = await _pump(tester);
    await _tapVisible(tester, find.byKey(const ValueKey('course-4')));
    expect(find.text('编辑课程'), findsOneWidget);

    final short = find.widgetWithText(TextField, '线代');
    await tester.enterText(short, '线代A');
    await tester.pumpAndSettle();
    await _tapVisible(tester, find.widgetWithText(FilledButton, '保存').last);

    final saved = (await repo.load())!;
    final course = saved.courses.firstWhere((c) => c.id == 4);
    expect(course.shortName, '线代A');
    expect(course.name, '线性代数', reason: '没改的字段不能被顺手清空');
  });

  testWidgets('加一个时段 → 写回仓库', (tester) async {
    final repo = await _pump(tester);
    final before = (await repo.load())!.rules.length;
    await _tapVisible(tester, find.byKey(const ValueKey('course-4')));
    await _tapVisible(tester, find.text('+ 添加时段'));
    expect(find.text('添加上课时段'), findsOneWidget);
    await _tapVisible(tester, find.widgetWithText(FilledButton, '保存').last);
    await _tapVisible(tester, find.widgetWithText(FilledButton, '保存').last);

    final saved = (await repo.load())!;
    expect(saved.rules.length, before + 1);
    expect(saved.rules.last.courseId, 4);
  });

  testWidgets('加一个模板 → 写回仓库，模板能被生成器用', (tester) async {
    final repo = await _pump(tester);
    await _tapVisible(tester, find.byKey(const ValueKey('course-4')));
    await _tapVisible(tester, find.text('+ 添加模板'));
    expect(find.text('添加待办模板'), findsOneWidget);

    final title = find.descendant(
        of: find.byType(Dialog).last, matching: find.byType(TextField)).first;
    await tester.enterText(title, '线代作业 %N');
    await tester.pumpAndSettle();
    await _tapVisible(tester, find.widgetWithText(FilledButton, '保存').last);
    await _tapVisible(tester, find.widgetWithText(FilledButton, '保存').last);

    final saved = (await repo.load())!;
    expect(saved.templates.length, 1);
    final t = saved.templates.first;
    expect(t.courseId, 4);
    expect(t.titleTemplate, '线代作业 %N');
    expect(t.enabled, isTrue);
  });

  testWidgets('删课程 → 课程、它的时段与模板一起消失', (tester) async {
    final repo = await _pump(tester);
    final before = (await repo.load())!;
    await _tapVisible(tester, find.byKey(const ValueKey('course-4')));
    await _tapVisible(tester, find.text('删除课程'));
    expect(find.text('确认删除课程'), findsOneWidget);
    await _tapVisible(tester, find.text('确认删除课程'));

    final saved = (await repo.load())!;
    expect(saved.courses.any((c) => c.id == 4), isFalse);
    expect(saved.rules.any((r) => r.courseId == 4), isFalse);
    expect(before.courses.length - 1, saved.courses.length);
  });

  testWidgets('清空本学期课程需要二次确认，且只删课程/时段/模板', (tester) async {
    final repo = await _pump(tester);
    // 先给一门课加个模板，验证模板会一起被清
    await _tapVisible(tester, find.byKey(const ValueKey('course-4')));
    await _tapVisible(tester, find.text('+ 添加模板'));
    await _tapVisible(tester, find.widgetWithText(FilledButton, '保存').last);
    await _tapVisible(tester, find.widgetWithText(FilledButton, '保存').last);

    final withTemplate = (await repo.load())!;
    expect(withTemplate.templates.length, 1);

    // 第一次点只是"进入确认态"
    await _tapVisible(tester, find.text('清空本学期课程'));
    expect((await repo.load())!.courses.length, 4, reason: '第一次点不能真删');

    await _tapVisible(tester, find.text('确认清空本学期课程'));
    final saved = (await repo.load())!;
    expect(saved.courses, isEmpty);
    expect(saved.rules, isEmpty);
    expect(saved.templates, isEmpty);
    // 待办与计划块不动
    expect(saved.todos.length, withTemplate.todos.length);
    expect(saved.blocks.length, withTemplate.blocks.length);
  });

  testWidgets('诊断信息显示各表条数', (tester) async {
    await _pump(tester);
    expect(find.text('诊断信息'), findsOneWidget);
    expect(find.textContaining('课程 4'), findsWidgets);
    expect(find.textContaining('待办 6'), findsWidgets);
  });

  testWidgets('新建学期（不复制）→ 学期 +1，当前学期不变', (tester) async {
    final repo = await _pump(tester);
    await _tapVisible(tester, find.text('+ 新建学期'));
    // 关掉「复制课表」再创建
    await _tapVisible(tester, find.byType(Switch).last);
    await _tapVisible(tester, find.widgetWithText(FilledButton, '创建'));

    final saved = (await repo.load())!;
    expect(saved.semesters.length, 2);
    expect(saved.semesters.first.name, '演示学期', reason: '当前学期仍是第一个');
    expect(saved.semesters.last.totalWeeks, 16);
    expect(saved.courses.length, 4, reason: '没勾复制就不该多出课程');
  });

  testWidgets('新建学期 + 复制课表 → 课程/时段/节次都各多一份（换新 id）',
      (tester) async {
    final repo = await _pump(tester);
    await _tapVisible(tester, find.text('+ 新建学期'));
    await _tapVisible(tester, find.widgetWithText(FilledButton, '创建'));

    final saved = (await repo.load())!;
    final oldSem = saved.semesters.first;
    final newSem = saved.semesters.last;
    expect(saved.semesters.length, 2);

    final newCourses =
        saved.courses.where((c) => c.semesterId == newSem.id).toList();
    expect(newCourses.length, 4, reason: '四门课都复制过去');
    // id 必须换新（否则两学期共用同一批课程，改一个动两个）
    final oldIds = saved.courses
        .where((c) => c.semesterId == oldSem.id)
        .map((c) => c.id)
        .toSet();
    for (final c in newCourses) {
      expect(oldIds.contains(c.id), isFalse);
    }
    // 新学期的时段规则指向新课程 id，且周掩码按新周数
    final newRules =
        saved.rules.where((r) => newCourses.any((c) => c.id == r.courseId));
    expect(newRules.length, 6);
    for (final r in newRules) {
      expect(r.weeksMask.length, newSem.totalWeeks);
    }
    // 节次时间也复制了一份
    expect(
        saved.sectionTimes.where((t) => t.semesterId == newSem.id).length,
        saved.sectionTimes.where((t) => t.semesterId == oldSem.id).length);
  });

  testWidgets('把第二个学期设为当前 → 顺序换了、课表切过去', (tester) async {
    final repo = await _pump(tester);
    await _tapVisible(tester, find.text('+ 新建学期'));
    await _tapVisible(tester, find.widgetWithText(FilledButton, '创建'));
    await _tapVisible(tester, find.text('设为当前'));

    final saved = (await repo.load())!;
    expect(saved.semesters.first.name, isNot('演示学期'));
    expect(saved.semester!.name, saved.semesters.first.name);
  });
}

void _semesterTests(WidgetTester tester) {}
