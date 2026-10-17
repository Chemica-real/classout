// 备份导出 —— 鸿蒙端 `BackupRepo` 导出的那一路（iOS/Android 版之前只有导入）。
//
// 格式必须与 `shared/backup-v1.md` 完全一致（字段名 camelCase，与 BackupBundle.fromJson 对称），
// 否则「安卓导出 → 鸿蒙恢复」会丢数据。所以这里手写序列化，字段表照着解析器反着列一遍，
// 并有 `test/backup_export_test.dart` 做 **encode → decode → 再 encode** 的往返比对。
//
// 写法上只用「有值的字段」：
//   · 布尔字段一律写 1/0（`shared/backup-v1.md` 与解析器 `_int(j['isQuiz'])` 都是这个约定；
//     写 true/false 会被解析器当成 0 —— 这个坑是往返测试抓出来的）
//   · restWindows 里 id=0 的那条不写 id（鸿蒙端也不存 id，让它自增）
//   · 空字符串字段照写（解析器宽容，但写出来更好排查）

import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../model/types.dart';
import 'backup.dart';

Map<String, dynamic> _semester(Semester s) => {
      'id': s.id,
      'name': s.name,
      'startDate': s.startDate,
      'totalWeeks': s.totalWeeks,
      'firstDayOfWeek': s.firstDayOfWeek,
      'showWeekend': s.showWeekend ? 1 : 0,
    };

Map<String, dynamic> _sectionTime(SectionTime t) => {
      'semesterId': t.semesterId,
      'section': t.section,
      'startMin': t.startMin,
      'endMin': t.endMin,
      'flexible': t.flexible,
    };

Map<String, dynamic> _course(Course c) => {
      'id': c.id,
      'semesterId': c.semesterId,
      'name': c.name,
      'shortName': c.shortName,
      'teacher': c.teacher,
      'location': c.location,
      'colorIndex': c.colorIndex,
      'autoTodoEnabled': c.autoTodoEnabled ? 1 : 0,
      'isVirtual': c.isVirtual ? 1 : 0,
      'note': c.note,
    };

Map<String, dynamic> _rule(SessionRule r) => {
      'id': r.id,
      'courseId': r.courseId,
      'weekday': r.weekday,
      'startSection': r.startSection,
      'endSection': r.endSection,
      'weeksMask': r.weeksMask,
      'location': r.location,
      'isQuiz': r.isQuiz ? 1 : 0,
    };

Map<String, dynamic> _override(SessionOverride o) => {
      'id': o.id,
      'courseId': o.courseId,
      'date': o.date,
      'kind': o.kind,
      'newDate': o.newDate,
      'newStartSection': o.newStartSection,
      'newEndSection': o.newEndSection,
      'newLocation': o.newLocation,
    };

Map<String, dynamic> _template(TodoTemplate t) => {
      'id': t.id,
      'courseId': t.courseId,
      'sortOrder': t.sortOrder,
      'enabled': t.enabled ? 1 : 0,
      'titleTemplate': t.titleTemplate,
      'ddlRule': t.ddlRule,
      'ddlParam': t.ddlParam,
      'estimateMin': t.estimateMin,
      'category': t.category,
      'submitChannel': t.submitChannel,
      'note': t.note,
    };

Map<String, dynamic> _lesson(VirtualLesson l) => {
      'id': l.id,
      'courseId': l.courseId,
      'seq': l.seq,
      'title': l.title,
      'done': l.done ? 1 : 0,
      'doneAt': l.doneAt,
    };

Map<String, dynamic> _todo(Todo t) => {
      'id': t.id,
      'title': t.title,
      'courseId': t.courseId,
      'category': t.category,
      'priority': t.priority,
      'ddl': t.ddl,
      'endAt': t.endAt,
      'estimateMin': t.estimateMin,
      'status': t.status,
      'source': t.source,
      'generationKey': t.generationKey,
      'note': t.note,
      'submitChannel': t.submitChannel,
      'repeatRule': t.repeatRule,
      'photos': t.photos,
      'createdAt': t.createdAt,
      'confirmedAt': t.confirmedAt,
      'doneAt': t.doneAt,
    };

Map<String, dynamic> _block(PlanBlock b) => {
      'id': b.id,
      'todoId': b.todoId,
      'lessonId': b.lessonId,
      'date': b.date,
      'startMin': b.startMin,
      'endMin': b.endMin,
      'done': b.done ? 1 : 0,
    };

Map<String, dynamic> _rest(RestWindow w) => {
      if (w.id > 0) 'id': w.id,
      'weekday': w.weekday,
      'startMin': w.startMin,
      'endMin': w.endMin,
      'label': w.label,
    };

/// 把 bundle 序列化成备份 JSON（缩进 2，方便人眼看/贴给别人排查）
String backupToJson(BackupBundle b) {
  final map = <String, dynamic>{
    'app': 'ClassOUT',
    'version': 1,
    'exportedAt': DateTime.now().toUtc().toIso8601String(),
    'semesters': b.semesters.map(_semester).toList(),
    'sectionTimes': b.sectionTimes.map(_sectionTime).toList(),
    'courses': b.courses.map(_course).toList(),
    'rules': b.rules.map(_rule).toList(),
    'overrides': b.overrides.map(_override).toList(),
    'templates': b.templates.map(_template).toList(),
    'todos': b.todos.map(_todo).toList(),
    'lessons': b.lessons.map(_lesson).toList(),
    'blocks': b.blocks.map(_block).toList(),
    'restWindows': b.restWindows.map(_rest).toList(),
  };
  return const JsonEncoder.withIndent('  ').convert(map);
}

/// 文件名：`classout-backup-20261017-2330.json`
String backupFileName([DateTime? now]) {
  final t = now ?? DateTime.now();
  String two(int n) => n < 10 ? '0$n' : '$n';
  return 'classout-backup-${t.year}${two(t.month)}${two(t.day)}'
      '-${two(t.hour)}${two(t.minute)}.json';
}

/// 测试可注入的目录（null = 真机走 path_provider；测试环境里没有原生实现）
Directory? backupDirOverride;

/// 备份目录（只查不写）。给「备份与恢复」页**还没导出时**显示路径用：
/// 鸿蒙那边是一个固定文件，路径随时可见；安卓是"每次导出新文件"，
/// 所以这里退一步显示目录，导出后再换成具体文件路径。
Future<String> backupDirPath({Directory? dir}) async {
  final target =
      dir ?? backupDirOverride ?? await getApplicationDocumentsDirectory();
  return target.path;
}

/// 写一份备份到应用文档目录，返回文件路径。
/// [dir] 可注入（测试写临时目录，不碰真机沙箱）。
Future<String> writeBackupFile(String json, {Directory? dir}) async {
  final target = dir ?? backupDirOverride ?? await getApplicationDocumentsDirectory();
  if (!await target.exists()) await target.create(recursive: true);
  final file = File('${target.path}${Platform.pathSeparator}${backupFileName()}');
  await file.writeAsString(json, flush: true);
  return file.path;
}

/// 诊断信息（鸿蒙端「备份与恢复」里也有一块，用来判断数据是不是齐的）
String backupSummary(BackupBundle b) {
  final done = b.todos.where((t) => t.status == 'done').length;
  final active = b.todos.where((t) => t.status == 'active').length;
  final pending = b.todos.where((t) => t.status == 'pending').length;
  return '学期 ${b.semesters.length} · 课程 ${b.courses.length} · '
      '时段 ${b.rules.length} · 模板 ${b.templates.length} · '
      '单周调整 ${b.overrides.length}\n'
      '待办 ${b.todos.length}（待确认 $pending / 进行中 $active / 已完成 $done）· '
      '计划块 ${b.blocks.length} · 课时 ${b.lessons.length} · '
      '不可排 ${b.restWindows.length}';
}
