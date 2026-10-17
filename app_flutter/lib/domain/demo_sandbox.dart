// 新手演练的沙箱数据 —— 鸿蒙端 `data/GuideRepo.ets → seedDemoData()` 的安卓版。
//
// ⚠️ 为什么不用 `assets/demo_backup.json`：那份是**固定日期**的演示数据（测试/截图用）；
// 鸿蒙的演练沙箱是**按"今天"现造**的 —— 学期从本周一开（第 1 周）、待办截止是
// 今天/明天/3 天后、计划块落在今天下午与明天早上。两边都用固定日期的话，
// 用户在任何一天点「开始演练」看到的课表位置就会和鸿蒙不一样。
//
// 内容与鸿蒙逐项一致：
//   · 学期「演练学期」，第一教学周周一 = 本周一，16 周；
//   · 北大 12 节作息 + 4 条默认不可排时段；
//   · 4 门演示课（高数/英语/计导/线代，含一节习题课）+ 每门一条生成模板；
//   · 4 条待办（有/无截止、有/无课程、有/无备注）；
//   · 2 个已排计划块（今天 14:00、明天 09:00）。

import '../data/backup.dart';
import '../model/types.dart';
import 'dates.dart';
import 'plan_math.dart';
import 'timetable.dart';

/// 造一份"演练用"的沙箱数据。[now] 可注入（测试用固定日期）。
BackupBundle buildDemoSandbox({DateTime? now}) {
  final today = now ?? DateTime.now();
  final day0 = DateTime(today.year, today.month, today.day);
  final monday = addDays(day0, 1 - weekdayOf(day0)); // 本周一
  final sem = Semester(
    id: 1,
    name: '演练学期',
    startDate: formatDate(monday),
    totalWeeks: 16,
    firstDayOfWeek: 1,
    showWeekend: true,
  );

  final courses = <Course>[
    Course(
        id: 1,
        semesterId: 1,
        name: '高等数学',
        shortName: '高数',
        teacher: '王老师',
        location: '明理101',
        colorIndex: 2),
    Course(
        id: 2,
        semesterId: 1,
        name: '大学英语',
        shortName: '英语',
        teacher: '李老师',
        location: '外语楼203',
        colorIndex: 1),
    Course(
        id: 3,
        semesterId: 1,
        name: '计算机导论',
        shortName: '计导',
        teacher: '张老师',
        location: '理科楼305',
        colorIndex: 3),
    Course(
        id: 4,
        semesterId: 1,
        name: '线性代数',
        shortName: '线代',
        teacher: '刘老师',
        location: '明理408',
        colorIndex: 0),
  ];

  final fullMask = '1' * sem.totalWeeks;
  // [id, courseId, weekday, startSection, endSection, isQuiz]
  final ruleSpecs = <List<int>>[
    [1, 1, 1, 1, 2, 0],
    [2, 1, 3, 3, 4, 0],
    [3, 1, 3, 10, 11, 1],
    [4, 2, 2, 5, 6, 0],
    [5, 3, 4, 7, 8, 0],
    [6, 4, 5, 3, 4, 0],
  ];
  final rules = <SessionRule>[
    for (final r in ruleSpecs)
      SessionRule(
        id: r[0],
        courseId: r[1],
        weekday: r[2],
        startSection: r[3],
        endSection: r[4],
        weeksMask: fullMask,
        isQuiz: r[5] == 1,
      ),
  ];

  final templates = <TodoTemplate>[
    for (final c in courses)
      TodoTemplate(
        id: c.id,
        courseId: c.id,
        sortOrder: 0,
        enabled: true,
        titleTemplate: '%D作业',
        ddlRule: 'next_session',
        estimateMin: 60,
        category: TodoCategory.homework,
      ),
  ];

  final ddlToday = '${formatDate(day0)} 23:59';
  final ddlTomorrow = '${formatDate(addDays(day0, 1))} 23:59';
  final ddl3 = '${formatDate(addDays(day0, 3))} 23:59';
  final todos = <Todo>[
    Todo(
        id: 1,
        title: '数学作业 P12 第 3-5 题',
        courseId: 1,
        ddl: ddlToday,
        estimateMin: 60,
        note: '记得写过程'),
    Todo(
        id: 2,
        title: '背 20 个单词',
        courseId: 2,
        ddl: ddlTomorrow,
        estimateMin: 30,
        category: TodoCategory.self),
    Todo(
        id: 3,
        title: '预习第 2 章',
        courseId: 3,
        estimateMin: 45),
    Todo(
        id: 4,
        title: '买笔记本',
        ddl: ddl3,
        estimateMin: 15,
        category: TodoCategory.none,
        note: '顺手买支笔'),
  ];

  final blocks = <PlanBlock>[
    PlanBlock(
        id: 1,
        todoId: 1,
        date: formatDate(day0),
        startMin: 14 * 60,
        endMin: 15 * 60),
    PlanBlock(
        id: 2,
        todoId: 2,
        date: formatDate(addDays(day0, 1)),
        startMin: 9 * 60,
        endMin: 9 * 60 + 30),
  ];

  final rests = <RestWindow>[
    for (var i = 0; i < defaultRestWindows().length; i++)
      RestWindow(
        id: i,
        weekday: 0,
        startMin: defaultRestWindows()[i].$1,
        endMin: defaultRestWindows()[i].$2,
        label: const ['午休', '晚饭', '睡觉', '睡觉'][i],
      ),
  ];

  return BackupBundle(
    app: 'ClassOUT',
    version: 1,
    exportedAt: formatDate(day0),
    semesters: [sem],
    sectionTimes: pkuSectionTimes(1),
    courses: courses,
    rules: rules,
    overrides: const [],
    todos: todos,
    blocks: blocks,
    restWindows: rests,
    templates: templates,
  );
}
