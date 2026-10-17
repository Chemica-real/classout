// 虚拟课时的显示名（鸿蒙 `lessonTitle`）：有标题用标题，没有才拼「课程简称 第 N 讲」。
//
// 这里钉住一个真机上看像 bug 的坑：以前拼成「第 N 讲 · 标题」，而演示数据的标题
// 本身就是「第 2 讲」，于是变成「第 2 讲 · 第 2 讲」。

import 'package:flutter_test/flutter_test.dart';

import 'package:classout/domain/timetable.dart';
import 'package:classout/model/types.dart';

Course _course({int id = 4, String name = '线性代数', String shortName = '线代'}) =>
    Course(id: id, semesterId: 1, name: name, shortName: shortName);

void main() {
  test('有标题 → 原样用标题（不再拼「第 N 讲」）', () {
    final l = VirtualLesson(id: 7, courseId: 4, seq: 2, title: '第 2 讲');
    expect(lessonTitleOf(l, [_course()]), '第 2 讲');
    final named = VirtualLesson(id: 8, courseId: 4, seq: 3, title: '指针与数组');
    expect(lessonTitleOf(named, [_course()]), '指针与数组');
  });

  test('没有标题 → 「课程简称 第 N 讲」', () {
    final l = VirtualLesson(id: 9, courseId: 4, seq: 5, title: '');
    expect(lessonTitleOf(l, [_course()]), '线代 第 5 讲');
  });

  test('简称空 → 用全名；找不到课 → 「虚拟课程」', () {
    final l = VirtualLesson(id: 10, courseId: 4, seq: 1, title: '');
    expect(lessonTitleOf(l, [_course(shortName: '')]), '线性代数 第 1 讲');
    expect(lessonTitleOf(l, const []), '虚拟课程 第 1 讲');
  });
}
