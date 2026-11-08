import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:classout/data/backup.dart';
import 'package:classout/model/types.dart';
import 'package:classout/ui/virtual_course_page.dart';

BackupBundle _demo() =>
    BackupBundle.decode(File('assets/demo_backup.json').readAsStringSync());

BackupBundle _withLesson() {
  final b = _demo();
  final course = Course(
    id: 99,
    semesterId: b.semester!.id,
    name: '虚拟测试课',
    shortName: '虚测',
    isVirtual: true,
    lessonDurationMin: 90,
  );
  return b.copyWith(
    courses: [...b.courses, course],
    lessons: [
      VirtualLesson(
        id: 901,
        courseId: 99,
        seq: 1,
        title: '第一讲',
        durationMin: 0,
      ),
    ],
    blocks: [
      PlanBlock(
        id: 902,
        todoId: 0,
        lessonId: 901,
        date: '2026-11-09',
        startMin: 480,
        endMin: 570,
      ),
    ],
  );
}

void main() {
  testWidgets('改名保存：没动滑条时保留跟随课程默认，计划块时长不被动',
      (tester) async {
    BackupBundle? last;
    await tester.pumpWidget(MaterialApp(
      home: VirtualCoursePage(
        bundle: _withLesson(),
        course: _withLesson().courses.last,
        onChanged: (b) => last = b,
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('第一讲'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '改名后');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(last, isNotNull);
    final l = last!.lessons.firstWhere((x) => x.id == 901);
    expect(l.title, '改名后');
    expect(l.durationMin, 0, reason: '没动滑条应继续跟随课程默认');
    final b = last!.blocks.firstWhere((x) => x.lessonId == 901);
    expect(b.endMin, 570, reason: '时长没改，计划块结束时间也不该变');
  });

  testWidgets('删除这一讲：课时和计划块一起删，不改其它讲', (tester) async {
    BackupBundle? last;
    final bundle = _withLesson();
    await tester.pumpWidget(MaterialApp(
      home: VirtualCoursePage(
        bundle: bundle,
        course: bundle.courses.last,
        onChanged: (b) => last = b,
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('第一讲'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除这一讲'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除').last);
    await tester.pumpAndSettle();
    expect(last, isNotNull);
    expect(last!.lessons.any((x) => x.id == 901), isFalse);
    expect(last!.blocks.any((x) => x.lessonId == 901), isFalse);
  });
}
