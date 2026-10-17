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

  test('写文件：文件名带日期，内容可解析', () async {
    final dir = await Directory.systemTemp.createTemp('classout-backup-test');
    addTearDown(() => dir.delete(recursive: true));
    final json = backupToJson(_demo());
    final path = await writeBackupFile(json, dir: dir);

    expect(File(path).existsSync(), isTrue);
    final name = path.split(Platform.pathSeparator).last;
    expect(name, startsWith('classout-backup-'));
    expect(name, endsWith('.json'));

    final read = File(path).readAsStringSync();
    expect(BackupBundle.decode(read).courses.length, 4);
  });

  test('诊断摘要包含各表计数', () {
    final text = backupSummary(_demo());
    expect(text, contains('课程 4'));
    expect(text, contains('时段 6'));
    expect(text, contains('待办 6'));
    expect(text, contains('计划块 3'));
  });
}
