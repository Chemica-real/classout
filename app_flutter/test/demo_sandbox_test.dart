// 演练沙箱数据（鸿蒙 `GuideRepo.seedDemoData` 的安卓版）：相对日期 + 内容逐项。

import 'package:flutter_test/flutter_test.dart';

import 'package:classout/domain/dates.dart';
import 'package:classout/domain/demo_sandbox.dart';

void main() {
  final b = buildDemoSandbox(now: DateTime(2026, 10, 16, 9, 30));

  test('学期：演练学期、本周一开学、16 周', () {
    final sem = b.semester!;
    expect(sem.name, '演练学期');
    expect(sem.startDate, '2026-10-12', reason: '2026-10-16 是周五，本周一是 10-12');
    expect(sem.totalWeeks, 16);
  });

  test('4 门演示课 + 6 条时段（含一节习题课）+ 每门一条模板', () {
    expect(b.courses.map((c) => c.name).toList(),
        ['高等数学', '大学英语', '计算机导论', '线性代数']);
    expect(b.courses.map((c) => c.location).toList(),
        ['明理101', '外语楼203', '理科楼305', '明理408']);
    expect(b.rules.length, 6);
    expect(b.rules.where((r) => r.isQuiz).length, 1);
    expect(b.rules.first.weeksMask.length, 16);
    expect(b.templates.length, 4);
    expect(b.templates.every((t) => t.titleTemplate == '%D作业'), isTrue);
  });

  test('4 条待办：今天 / 明天 / 3 天后 / 无截止，覆盖有/无课程与备注', () {
    expect(b.todos.length, 4);
    expect(b.todos[0].ddl, '2026-10-16 23:59');
    expect(b.todos[1].ddl, '2026-10-17 23:59');
    expect(b.todos[2].ddl, '');
    expect(b.todos[3].ddl, '2026-10-19 23:59');
    expect(b.todos[3].courseId, 0);
    expect(b.todos[0].note, '记得写过程');
    expect(b.todos[3].note, '顺手买支笔');
    // 鸿蒙 seedDemoData 传的类型：作业 / 自学 / 作业 / 无
    expect(b.todos.map((t) => t.category).toList(),
        ['homework', 'self', 'homework', 'none']);
  });

  test('首次启动的空学期：我的学期 / 本周一 / 16 周 / 12 节 / 4 段不可排 / 没有课程', () {
    final f = buildFirstRunBundle(now: DateTime(2026, 10, 16, 9, 30));
    final sem = f.semester!;
    expect(sem.name, '我的学期');
    expect(sem.startDate, '2026-10-12');
    expect(sem.totalWeeks, 16);
    expect(f.sectionTimes.length, 12);
    expect(f.restWindows.length, 4);
    expect(f.restWindows.map((w) => w.label).toList(),
        ['午休', '晚饭', '睡觉', '睡觉']);
    expect(f.courses, isEmpty, reason: '鸿蒙不内置任何课表');
    expect(f.todos, isEmpty);
    expect(f.rules, isEmpty);
  });

  test('两个已排块：今天 14:00、明天 09:00；节次 12 节、不可排 4 段', () {
    expect(b.blocks.length, 2);
    expect(b.blocks[0].date, formatDate(DateTime(2026, 10, 16)));
    expect(b.blocks[0].startMin, 14 * 60);
    expect(b.blocks[1].date, formatDate(DateTime(2026, 10, 17)));
    expect(b.blocks[1].startMin, 9 * 60);
    expect(b.sectionTimes.length, 12);
    expect(b.restWindows.length, 4);
  });
}
