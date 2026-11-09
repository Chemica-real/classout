import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:classout/data/backup.dart';
import 'package:classout/data/calendar_sync.dart';
import 'package:classout/model/types.dart';

BackupBundle _demo() =>
    BackupBundle.decode(File('assets/demo_backup.json').readAsStringSync());

void main() {
  test('可选日历：生成的课程事件带 ClassOUT 标记', () {
    final b = _demo();
    final now = DateTime(2026, 11, 9, 8);
    final events = buildCalendarEvents(b, now);
    expect(events, isNotEmpty);
    expect(events.every((e) => e.description.startsWith('ClassOUT')), isTrue);
    expect(events.any((e) => e.title.isNotEmpty), isTrue);
    expect(events.every((e) => e.endMs > e.startMs), isTrue);
  });

  test('待办不再写截止事件（鸿蒙 1.10 已移除）', () {
    final b = _demo();
    final now = DateTime(2026, 11, 9, 8);
    final done = Todo(
      id: 1,
      title: '已完成',
      status: TodoStatus.done,
      ddl: '2026-11-10 23:59',
      category: TodoCategory.homework,
    );
    final active = Todo(
      id: 2,
      title: '未完成',
      status: TodoStatus.active,
      ddl: '2026-11-10 23:59',
      category: TodoCategory.homework,
    );
    final events = buildCalendarEvents(
        b.copyWith(todos: [done, active]), now);
    expect(events.any((e) => e.title.contains('已完成')), isFalse);
    expect(events.any((e) => e.title == '截止：未完成'), isFalse);
    expect(events.every((e) => !e.title.startsWith('截止：')), isTrue);
  });

  test('没有学期时不生成任何日历事件', () {
    final b = _demo().copyWith(semesters: []);
    expect(buildCalendarEvents(b, DateTime(2026, 11, 9)), isEmpty);
  });
}
