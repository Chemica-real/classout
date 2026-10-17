// 虚拟课时完成 → 按课程模板生成待办（鸿蒙端 generateForLesson 的 Dart 版）。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:classout/data/backup.dart';
import 'package:classout/domain/dates.dart';
import 'package:classout/domain/todo_generator.dart';
import 'package:classout/model/types.dart';

BackupBundle _demo() =>
    BackupBundle.decode(File('assets/demo_backup.json').readAsStringSync());

void main() {
  test('课时完成 → 生成一条 pending 待办（备注为空、去重键 course|date|template）', () {
    final b = _demo();
    final lesson = VirtualLesson(
        id: 3, courseId: 1, seq: 2, title: '第二讲');
    final tpl = TodoTemplate(
      id: 9,
      courseId: 1,
      titleTemplate: '%c 第 %N 讲作业',
      ddlRule: 'same_day',
      estimateMin: 45,
      category: 'homework',
    );
    final r = generateForLesson(
      courses: b.courses,
      rules: b.rules,
      times: b.sectionTimes,
      templates: [tpl],
      todos: const [],
      sem: b.semester!,
      lesson: lesson,
      date: '2026-10-16',
      startMin: 19 * 60,
      endMin: 20 * 60 + 30,
      nextId: 0,
    );
    expect(r.created.length, 1);
    final t = r.created.first;
    expect(t.title, '高数 第 1 讲作业');
    expect(t.ddl, '2026-10-16 23:59');
    expect(t.estimateMin, 45);
    expect(t.status, TodoStatus.pending);
    expect(t.note, '');
    expect(t.generationKey, '1|2026-10-16|9');
  });

  test('同一讲再触发一次 → 去重，不再生成', () {
    final b = _demo();
    final tpl = TodoTemplate(
        id: 9, courseId: 1, titleTemplate: '%c 作业', ddlRule: 'same_day');
    final first = generateForLesson(
      courses: b.courses,
      rules: b.rules,
      times: b.sectionTimes,
      templates: [tpl],
      todos: const [],
      sem: b.semester!,
      lesson: VirtualLesson(id: 3, courseId: 1, seq: 2, title: '第二讲'),
      date: '2026-10-16',
      startMin: 600,
      endMin: 660,
    );
    final again = generateForLesson(
      courses: b.courses,
      rules: b.rules,
      times: b.sectionTimes,
      templates: [tpl],
      todos: first.created,
      sem: b.semester!,
      lesson: VirtualLesson(id: 3, courseId: 1, seq: 2, title: '第二讲'),
      date: '2026-10-16',
      startMin: 600,
      endMin: 660,
    );
    expect(again.created, isEmpty);
  });

  test('课程的「自动生成待办」关掉 → 不生成', () {
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
              autoTodoEnabled: c.id != 1,
              isVirtual: c.isVirtual,
              note: c.note,
            ))
        .toList();
    final r = generateForLesson(
      courses: courses,
      rules: b.rules,
      times: b.sectionTimes,
      templates: [
        TodoTemplate(id: 9, courseId: 1, titleTemplate: '%c 作业', ddlRule: 'same_day')
      ],
      todos: const [],
      sem: b.semester!,
      lesson: VirtualLesson(id: 3, courseId: 1, seq: 2, title: '第二讲'),
      date: '2026-10-16',
      startMin: 600,
      endMin: 660,
    );
    expect(r.created, isEmpty);
  });

  test('周次算得对（%N 用已有该课程待办数 + 1）', () {
    final b = _demo();
    final existing = b.todos.where((t) => t.courseId == 1).length; // 演示数据里 2 条
    final r = generateForLesson(
      courses: b.courses,
      rules: b.rules,
      times: b.sectionTimes,
      templates: [
        TodoTemplate(id: 9, courseId: 1, titleTemplate: '%N', ddlRule: 'same_day')
      ],
      todos: b.todos,
      sem: b.semester!,
      lesson: VirtualLesson(id: 3, courseId: 1, seq: 2, title: '第二讲'),
      date: '2026-10-16',
      startMin: 600,
      endMin: 660,
    );
    expect(r.created.first.title, '${existing + 1}');
  });
}
