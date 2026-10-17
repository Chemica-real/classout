// 提醒排期（纯逻辑）的测试。
//
// ⚠️ 这一段**没有 fixtures**：鸿蒙端 `syncReminders()` 把"查库+算+调平台 API"写在一起，
//    不是纯函数。所以这里用手写断言钉住关键行为（数量、时刻、预算截断、考试的排除）。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:classout/data/backup.dart';
import 'package:classout/domain/dates.dart';
import 'package:classout/domain/reminders.dart';
import 'package:classout/domain/timetable.dart';
import 'package:classout/model/types.dart';

BackupBundle _demo() =>
    BackupBundle.decode(File('assets/demo_backup.json').readAsStringSync());

/// 固定"现在"：2026-10-14 20:00（周三），免得测试随真实时间漂
final DateTime _now = DateTime(2026, 10, 14, 20, 0);

ReminderPlanResult _plan(BackupBundle b,
    {ReminderSettings? settings,
    DateTime? now,
    int budget = reminderBudget,
    List<VirtualLesson> lessons = const <VirtualLesson>[]}) {
  return planReminders(
    sem: b.semester!,
    courses: b.courses,
    rules: b.rules,
    times: b.sectionTimes,
    overrides: b.overrides,
    todos: b.todos.where((t) => t.status == 'active').toList(),
    blocks: b.blocks,
    lessons: lessons,
    settings: settings ?? ReminderSettings(),
    now: now ?? _now,
    budget: budget,
  );
}

void main() {
  test('虚拟课时块：到点提醒说「该上「X 第 N 讲」了」（鸿蒙同款文案）', () {
    final b = _demo();
    final lessons = [
      VirtualLesson(id: 7, courseId: 4, seq: 2, title: '第 2 讲'),
    ];
    final block = PlanBlock(
        id: 99, todoId: 0, lessonId: 7, date: '2026-10-14', startMin: 21 * 60, endMin: 22 * 60);
    final r = planReminders(
      sem: b.semester!,
      courses: b.courses,
      rules: b.rules,
      times: b.sectionTimes,
      overrides: b.overrides,
      todos: const [],
      blocks: [block],
      lessons: lessons,
      settings: ReminderSettings(),
      now: _now,
    );
    final blk = r.published.firstWhere((x) => x.kind == 'block');
    expect(blk.title, '该上「线代 第 2 讲」了');
  });

  test('简报：今天那条如果已过就不排（现在 20:00，今天 07:30 已过）', () {
    final r = _plan(_demo());
    expect(r.briefs, 7, reason: 'offset 0..7 共 8 天，但今天的 07:30 已经过去');
    // 简报正文来自 buildBriefing（已与鸿蒙端 fixtures 对齐）
    final brief = r.published.firstWhere((x) => x.kind == 'brief');
    expect(brief.title, '今日简报');
    expect(brief.content, isNotEmpty);
  });

  test('上课提醒正好是某节课开始前 15 分钟', () {
    final b = _demo();
    final r = _plan(b);
    final cls = r.published.where((x) => x.kind == 'class').toList();
    expect(cls, isNotEmpty);
    final first = cls.first;
    expect(first.title.endsWith('分钟上课'), isTrue);
    final minutes = first.at.hour * 60 + first.at.minute;
    final sem = b.semester!;
    final sessions = computeWeekSessions(sem, b.courses, b.rules, b.overrides,
            b.sectionTimes, weekOfDate(sem, first.at))
        .where((s) => s.date == formatDate(first.at));
    expect(sessions.any((s) => s.startMin == minutes + 15), isTrue,
        reason: '提醒时刻应该是某节课开始前 15 分钟');
  });

  test('考试不进「即将截止」提醒（这是有意与鸿蒙端不同：那边漏了这条，见 HANDOFF §41）', () {
    final b = _demo();
    final exam = b.todos.firstWhere((t) => t.category == 'exam');
    expect(exam.ddl.isNotEmpty, isTrue);
    final r = _plan(b);
    final ddlTitles = r.published.where((x) => x.kind == 'ddl').map((x) => x.title).toList();
    expect(ddlTitles, isNotEmpty, reason: '普通的作业截止还是要提醒的');
    for (final t in ddlTitles) {
      expect(t.contains(exam.title), isFalse,
          reason: '考试的 ddl 是开始时刻，不该当成截止提醒');
    }
  });

  test('已经过去的时刻不会被排（now 之后才有）', () {
    final r = _plan(_demo());
    for (final x in r.published) {
      expect(x.at.isAfter(_now), isTrue, reason: '${x.kind} ${x.at} 应该在 now 之后');
    }
  });

  test('按时间升序', () {
    final r = _plan(_demo());
    for (var i = 1; i < r.published.length; i++) {
      expect(
        r.published[i].at.isBefore(r.published[i - 1].at),
        isFalse,
        reason: '第 $i 条比前一条更早',
      );
    }
  });

  test('预算截断：早的先保，超出的计入 skippedByBudget', () {
    final all = _plan(_demo(), budget: 1000);
    final capped = _plan(_demo(), budget: 3);
    expect(capped.published.length, 3);
    expect(capped.skippedByBudget, all.published.length - 3);
    // 截断保留的正是最早的三条
    for (var i = 0; i < 3; i++) {
      expect(capped.published[i].at, all.published[i].at);
      expect(capped.published[i].title, all.published[i].title);
    }
  });

  test('关掉简报就不排简报', () {
    final r = _plan(_demo(), settings: ReminderSettings(briefEnabled: false));
    expect(r.briefs, 0);
  });

  test('提前量可配：改成 30 分钟，提醒时刻整体前移', () {
    final a = _plan(_demo(), settings: ReminderSettings(classLeadMin: 15));
    final b = _plan(_demo(), settings: ReminderSettings(classLeadMin: 30));
    final ca = a.published.firstWhere((x) => x.kind == 'class');
    final cb = b.published.firstWhere((x) => x.kind == 'class');
    expect(ca.at.difference(cb.at).inMinutes, 15);
    expect(cb.title.contains('30 分钟上课'), isTrue);
  });

  test('计划块：只排未完成、且近 3 天的块', () {
    final r = _plan(_demo());
    final blocks = r.published.where((x) => x.kind == 'block').toList();
    // 演示数据里 10-16 / 10-17 各一块（10-22 的考试块超出 3 天窗口）
    expect(blocks.length, 2);
    for (final x in blocks) {
      expect(x.title.startsWith('该做「'), isTrue);
    }
  });

  test('ddlDateTime 解析', () {
    expect(ddlDateTime('2026-10-18 23:59'), DateTime(2026, 10, 18, 23, 59));
    expect(ddlDateTime('2026-10-18'), isNull);
    expect(ddlDateTime(''), isNull);
  });
}
