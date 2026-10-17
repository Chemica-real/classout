// 下课自动生成待办（鸿蒙端 domain/TodoGenerator.ets）的规则测试。
//
// 这些用例是「鸿蒙端行为」的镜像：模板变量、6 种截止规则、去重、只看已下课、
// autoTodoEnabled 关掉就不生成、备注不带过来。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:classout/data/backup.dart';
import 'package:classout/domain/dates.dart';
import 'package:flutter/material.dart';

import 'package:classout/data/repo.dart';
import 'package:classout/domain/timetable.dart';
import 'package:classout/domain/todo_generator.dart';
import 'package:classout/model/types.dart';
import 'package:classout/ui/home_shell.dart';

BackupBundle _demo() =>
    BackupBundle.decode(File('assets/demo_backup.json').readAsStringSync());

/// 演示学期第 1 周：10/12（周一）– 10/18（周日）
final DateTime _week1Friday = DateTime(2026, 10, 16, 22, 0);

TodoTemplate _tpl({
  int courseId = 4, // 线代：周五 3-4 节 10:10–12:00
  String title = '%c 第 %N 次作业',
  String rule = 'same_day',
  String param = '',
  String category = 'homework',
  int estimateMin = 60,
  bool enabled = true,
}) =>
    TodoTemplate(
      id: 7,
      courseId: courseId,
      enabled: enabled,
      titleTemplate: title,
      ddlRule: rule,
      ddlParam: param,
      estimateMin: estimateMin,
      category: category,
    );

GenerationOutcome _run(
  BackupBundle b, {
  List<TodoTemplate>? templates,
  List<Todo> todos = const [],
  String last = '2026-10-16',
  DateTime? now,
}) =>
    generateMissedTodos(
      sem: b.semester!,
      courses: b.courses,
      rules: b.rules,
      overrides: b.overrides,
      times: b.sectionTimes,
      templates: templates ?? [_tpl()],
      todos: todos,
      lastGenDate: last,
      now: now ?? _week1Friday,
    );

void main() {
  test('模板变量：%c / %N / %D / %d / %W / %T / %R', () {
    final b = _demo();
    final s = computeWeekSessions(
            b.semester!, b.courses, b.rules, b.overrides, b.sectionTimes, 1)
        .firstWhere((x) => x.course.id == 4);
    final out = renderTitle('%C|%c|%D|%d|%W|%T|%N|%R', s, 1, 3);
    expect(out.split('|')[0], '线性代数');
    expect(out.split('|')[1], '线代');
    expect(out.split('|')[2], '10.16');
    expect(out.split('|')[3], '2026-10-16');
    expect(out.split('|')[4], '1');
    expect(out.split('|')[6], '3');
    expect(out.split('|')[7], s.location);
  });

  test('已经下课的课时 → 生成待确认待办（备注为空、source=template）', () {
    final b = _demo();
    final r = _run(b);
    expect(r.created.length, 1);
    final t = r.created.first;
    expect(t.status, TodoStatus.pending);
    expect(t.source, 'template');
    expect(t.note, '', reason: '自动生成的待办不能带备注');
    expect(t.title, '线代 第 1 次作业');
    expect(t.ddl, '2026-10-16 23:59');
    expect(t.generationKey, '4|2026-10-16|7');
    expect(r.lastGenDate, '2026-10-16');
  });

  test('还没下课 → 不生成', () {
    final b = _demo();
    // 线代 3-4 节 12:00 下课；11:00 时不该生成
    final r = _run(b, now: DateTime(2026, 10, 16, 11, 0));
    expect(r.created, isEmpty);
  });

  test('重复触发 → 去重键挡住，不再生成第二份', () {
    final b = _demo();
    final first = _run(b);
    expect(first.created.length, 1);
    final again = _run(b, todos: first.created, last: first.lastGenDate);
    expect(again.created, isEmpty);
  });

  test('autoTodoEnabled = false 的课不生成', () {
    final b = _demo();
    final courses = b.courses
        .map((c) => Course(
              id: c.id,
              semesterId: c.semesterId,
              name: c.name,
              shortName: c.shortName,
              teacher: c.teacher,
              location: c.location,
              colorIndex: c.colorIndex,
              autoTodoEnabled: c.id != 4,
              isVirtual: c.isVirtual,
              note: c.note,
            ))
        .toList();
    final r = generateMissedTodos(
      sem: b.semester!,
      courses: courses,
      rules: b.rules,
      overrides: b.overrides,
      times: b.sectionTimes,
      templates: [_tpl()],
      todos: const [],
      lastGenDate: '2026-10-16',
      now: _week1Friday,
    );
    expect(r.created, isEmpty);
  });

  test('六种截止规则', () {
    final b = _demo();
    final s = computeWeekSessions(
            b.semester!, b.courses, b.rules, b.overrides, b.sectionTimes, 1)
        .firstWhere((x) => x.course.id == 4);

    String ddl(String rule, [String param = '']) => computeDdl(
        b.semester!, b.courses, b.rules, b.overrides, b.sectionTimes, s, rule,
        param);

    expect(ddl('none'), '');
    expect(ddl('same_day'), '2026-10-16 23:59');
    expect(ddl('days', '3'), '2026-10-19 23:59');
    expect(ddl('days', 'x'), '2026-10-17 23:59', reason: '坏参数当 1 天');
    // 周五(5) → 下一个周三(3)：(3-5+7)%7 = 5 → 10/21
    expect(ddl('weekday', '3'), '2026-10-21 23:59');
    expect(ddl('weekday', 'bad'), '2026-10-18 23:59', reason: '坏参数当周日');
    expect(ddl('week_end'), '2026-10-18 23:59');
    // 线代下一次课是下周五 10/23
    expect(ddl('next_session'), '2026-10-23 23:59');
  });

  test('last_gen_date 为空 → 只扫今天（不补历史）', () {
    final b = _demo();
    final r = _run(b, last: '');
    expect(r.scannedDays, 1);
    expect(r.created.length, 1);
  });

  test('停课覆盖 → 那天不生成', () {
    final b = _demo();
    final overrides = [
      ...b.overrides,
      SessionOverride(
          id: 1, courseId: 4, date: '2026-10-16', kind: OverrideKind.cancel),
    ];
    final r = generateMissedTodos(
      sem: b.semester!,
      courses: b.courses,
      rules: b.rules,
      overrides: overrides,
      times: b.sectionTimes,
      templates: [_tpl()],
      todos: const [],
      lastGenDate: '2026-10-16',
      now: _week1Friday,
    );
    expect(r.created, isEmpty);
  });

  _shellTests();

  test('备份里的 templates 能读出来（导入不丢模板）', () {
    final b = BackupBundle.fromJson({
      'app': 'ClassOUT',
      'version': 1,
      'semesters': [],
      'templates': [
        {
          'id': 3,
          'courseId': 1,
          'sortOrder': 0,
          'enabled': 1,
          'titleTemplate': '%D作业',
          'ddlRule': 'week_end',
          'ddlParam': '',
          'estimateMin': 90,
          'category': 'homework',
        }
      ],
    });
    expect(b.templates.length, 1);
    expect(b.templates.first.id, 3);
    expect(b.templates.first.ddlRule, 'week_end');
    expect(b.templates.first.estimateMin, 90);
  });
}

// ---- 端到端：外壳读库后真的会补生成并写回 ----

void _shellTests() {
  testWidgets('打开 App 时按模板补生成，待办页出现「待确认」', (tester) async {
    // 一个完全过去的学期（2026 年春季），保证"已经下课"这个条件永远成立
    final sem = Semester(
      id: 1,
      name: '过去的学期',
      startDate: '2026-03-02',
      totalWeeks: 16,
      firstDayOfWeek: 1,
      showWeekend: true,
    );
    final course = Course(
      id: 1,
      semesterId: 1,
      name: '高等数学',
      shortName: '高数',
      teacher: '王老师',
      location: 'A101',
      colorIndex: 2,
    );
    final bundle = BackupBundle(
      app: 'ClassOUT',
      version: 1,
      exportedAt: '',
      semesters: [sem],
      sectionTimes: [
        SectionTime(section: 1, startMin: 8 * 60, endMin: 8 * 60 + 50),
        SectionTime(section: 2, startMin: 9 * 60, endMin: 9 * 60 + 50),
      ],
      courses: [course],
      rules: [
        SessionRule(
            id: 1,
            courseId: 1,
            weekday: 1,
            startSection: 1,
            endSection: 2,
            weeksMask: '1111111111111111',
            location: '',
            isQuiz: false),
      ],
      overrides: const [],
      todos: const [],
      blocks: const [],
      templates: [
        TodoTemplate(
            id: 5,
            courseId: 1,
            titleTemplate: '%c 作业',
            ddlRule: 'same_day',
            estimateMin: 45,
            category: 'homework'),
      ],
    );
    final repo = MemoryRepo(bundle);
    // 上次检查停在开学第一天 → 会把之后所有"已下课"的课时补出来
    await repo.setKv('last_gen_date', '2026-03-02');
    await tester.pumpWidget(MaterialApp(home: HomeShell(repo: repo)));
    await tester.pumpAndSettle();

    // kv 里记了 last_gen_date，库里多了 pending 待办
    expect(await repo.getKv('last_gen_date'), isNotEmpty);
    final saved = (await repo.load())!;
    expect(saved.todos.length, greaterThan(0));
    expect(saved.todos.first.status, TodoStatus.pending);
    expect(saved.todos.first.title, '高数 作业');
    expect(saved.todos.first.estimateMin, 45);

    // 切到待办页看得到「待确认」
    await tester.tap(find.text('待办').last);
    await tester.pumpAndSettle();
    expect(find.text('待确认'), findsOneWidget);
    expect(find.text('高数 作业'), findsWidgets);
  });
}
