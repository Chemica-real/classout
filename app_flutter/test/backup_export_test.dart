// 备份导出的往返测试：encode → decode → 逐字段比，确保「安卓导出 → 任意端恢复」不丢东西。

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:classout/data/backup.dart';
import 'package:classout/data/backup_export.dart';
import 'package:classout/model/types.dart';

BackupBundle _demo() =>
    BackupBundle.decode(File('assets/demo_backup.json').readAsStringSync());

void main() {
  test('导出 JSON 能被自己的解析器读回来（字段不丢）', () {
    final before = _demo();
    final json = backupToJson(before);
    final after = BackupBundle.decode(json);

    expect(after.app, 'ClassOUT');
    expect(after.version, 1);
    expect(after.exportedAt, isNotEmpty);

    expect(after.semesters.length, before.semesters.length);
    expect(after.semesters.first.name, before.semesters.first.name);
    expect(after.semesters.first.startDate, before.semesters.first.startDate);
    expect(after.semesters.first.totalWeeks, before.semesters.first.totalWeeks);
    expect(after.semesters.first.showWeekend, before.semesters.first.showWeekend);

    expect(after.sectionTimes.length, before.sectionTimes.length);
    expect(after.sectionTimes.first.startMin, before.sectionTimes.first.startMin);

    expect(after.courses.length, before.courses.length);
    final c0 = before.courses.first;
    final c1 = after.courses.first;
    expect(c1.name, c0.name);
    expect(c1.shortName, c0.shortName);
    expect(c1.teacher, c0.teacher);
    expect(c1.location, c0.location);
    expect(c1.colorIndex, c0.colorIndex);
    expect(c1.autoTodoEnabled, c0.autoTodoEnabled);

    expect(after.rules.length, before.rules.length);
    expect(after.rules.first.weeksMask, before.rules.first.weeksMask);

    expect(after.todos.length, before.todos.length);
    expect(after.todos.first.title, before.todos.first.title);
    expect(after.todos.first.ddl, before.todos.first.ddl);
    expect(after.todos.first.status, before.todos.first.status);
    // 布尔字段要按 1/0 往返（曾经写 true/false 被解析成 0）
    expect(after.rules[2].isQuiz, isTrue);
    expect(after.courses.first.autoTodoEnabled, isTrue);

    expect(after.blocks.length, before.blocks.length);
    expect(after.blocks.first.startMin, before.blocks.first.startMin);
  });

  test('导入 → 导出 → 再导入，两次 JSON 结构一致', () {
    final b = _demo();
    final once = jsonDecode(backupToJson(b)) as Map<String, dynamic>;
    final twice = jsonDecode(backupToJson(BackupBundle.decode(backupToJson(b))))
        as Map<String, dynamic>;
    // exportedAt 每次都会变，比其余字段
    once.remove('exportedAt');
    twice.remove('exportedAt');
    expect(twice.toString(), once.toString(), reason: '往返必须稳定，不能越导越少');
  });

  test('模板通过导出不会丢', () {
    final b = BackupBundle(
      app: 'ClassOUT',
      version: 1,
      exportedAt: '',
      semesters: const [],
      sectionTimes: const [],
      courses: const [],
      rules: const [],
      overrides: const [],
      todos: const [],
      blocks: const [],
      restWindows: [
        RestWindow(id: 0, weekday: 0, startMin: 720, endMin: 780, label: '午休'),
      ],
      templates: [
        TodoTemplate(
          id: 3,
          courseId: 1,
          titleTemplate: '%c 作业',
          ddlRule: 'week_end',
          estimateMin: 45,
          category: 'homework',
        ),
      ],
    );
    final after = BackupBundle.decode(backupToJson(b));
    expect(after.templates.length, 1);
    expect(after.templates.first.titleTemplate, '%c 作业');
    expect(after.templates.first.ddlRule, 'week_end');
    expect(after.templates.first.estimateMin, 45);
    expect(after.restWindows.length, 1);
    expect(after.restWindows.first.label, '午休');
  });

  test('虚拟课程课时（lessons）往返不丢', () {
    final b = BackupBundle(
      app: 'ClassOUT',
      version: 1,
      exportedAt: '',
      semesters: const [],
      sectionTimes: const [],
      courses: const [],
      rules: const [],
      overrides: const [],
      todos: const [],
      blocks: const [],
      lessons: [
        VirtualLesson(
            id: 2, courseId: 7, seq: 3, title: '第三章', done: true, doneAt: 123),
      ],
    );
    final after = BackupBundle.decode(backupToJson(b));
    expect(after.lessons.length, 1);
    final l = after.lessons.first;
    expect(l.id, 2);
    expect(l.courseId, 7);
    expect(l.seq, 3);
    expect(l.title, '第三章');
    expect(l.done, isTrue);
    expect(l.doneAt, 123);
  });

  test('写文件：固定文件名 classout-backup.json（鸿蒙 BACKUP_FILE 同名），内容可解析',
      () async {
    final dir = await Directory.systemTemp.createTemp('classout-backup-test');
    addTearDown(() => dir.delete(recursive: true));
    final json = backupToJson(_demo());
    final path = await writeBackupFile(json, dir: dir);

    expect(File(path).existsSync(), isTrue);
    final name = path.split(Platform.pathSeparator).last;
    expect(name, 'classout-backup.json');
    expect(backupFileName, 'classout-backup.json');

    // 再导出一次会覆盖同一份（鸿蒙也是固定一个文件）
    final again = await writeBackupFile(json.replaceAll('演示学期', '覆盖学期'),
        dir: dir);
    expect(again, path);
    expect(File(path).readAsStringSync(), contains('覆盖学期'));

    final read = await readBackupText(dir: dir);
    expect(BackupBundle.decode(read).courses.length, 4);
    // 路径可提前算出来（页上常显）
    expect(await backupFilePath(dir: dir), path);
  });

  test('没有备份文件时 readBackupText 返回空串（不抛异常）', () async {
    final dir = await Directory.systemTemp.createTemp('classout-backup-none');
    addTearDown(() => dir.delete(recursive: true));
    expect(await readBackupText(dir: dir), '');
  });

  test('摘要文案与鸿蒙 backupSummary 逐字一致', () {
    final text = backupSummary(_demo());
    expect(
        text,
        '学期 1 · 课程 4 · 时段 6 · 节次 12 · '
        '生成模板 0 · 待办 6 · 计划块 3 · 课时 0 · '
        '单周覆盖 0 · 休息时段 1');
  });

  test('诊断信息按表一行一行列（鸿蒙 diagnostics 同款）', () {
    final lines = diagnosticsText(_demo()).split('\n');
    expect(lines, contains('semester: 1'));
    expect(lines, contains('section_time: 12'));
    expect(lines, contains('course: 4'));
    expect(lines, contains('session_rule: 6'));
    expect(lines, contains('todo: 6'));
    expect(lines, contains('virtual_lesson: 0'));
    expect(lines, contains('plan_block: 3'));
  });
}
