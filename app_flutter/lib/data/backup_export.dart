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

/// 备份文件名 —— 与鸿蒙端 `data/BackupRepo.ets` 的 `BACKUP_FILE` 完全一致。
///
/// 鸿蒙那边是**固定一个文件**：路径可以一直显示在「备份与恢复」页上、恢复时
/// 直接读它（不弹选文件框）。安卓原来用「每次导出新文件名」，路径只能先显示
/// 目录、恢复要走文件选择器 —— 和鸿蒙差了两处。改成固定名后两端一模一样。
const String backupFileName = 'classout-backup.json';

/// 测试可注入的目录（null = 真机走 path_provider；测试环境里没有原生实现）
Directory? backupDirOverride;

Future<Directory> _backupDir([Directory? dir]) async =>
    dir ?? backupDirOverride ?? await getApplicationDocumentsDirectory();

/// 备份文件路径（只拼路径、不写文件）：鸿蒙 `BackupRepo.backupFilePath`。
/// 「备份与恢复」页**一直**显示它（不是导出后才出现）。
Future<String> backupFilePath({Directory? dir}) async {
  final target = await _backupDir(dir);
  return '${target.path}${Platform.pathSeparator}$backupFileName';
}

/// 写一份备份到应用文档目录（固定文件名，会覆盖上一份 —— 鸿蒙同行为），
/// 返回文件路径。[dir] 可注入（测试写临时目录，不碰真机沙箱）。
Future<String> writeBackupFile(String json, {Directory? dir}) async {
  final target = await _backupDir(dir);
  if (!await target.exists()) await target.create(recursive: true);
  final file = File('${target.path}${Platform.pathSeparator}$backupFileName');
  await file.writeAsString(json, flush: true);
  return file.path;
}

/// 读回那份固定备份的文本；没有文件返回空串（鸿蒙 `readBackupText` 同语义）。
Future<String> readBackupText({Directory? dir}) async {
  final path = await backupFilePath(dir: dir);
  final file = File(path);
  if (!await file.exists()) return '';
  return file.readAsString();
}

/// 导出/恢复后显示在页内蓝框里的摘要 —— 文案与鸿蒙 `backupSummary()` 逐字一致
/// （单行、`·` 分隔、同一组标签），截图对比时这一行必须能对上。
String backupSummary(BackupBundle b) =>
    '学期 ${b.semesters.length} · 课程 ${b.courses.length} · '
    '时段 ${b.rules.length} · 节次 ${b.sectionTimes.length} · '
    '生成模板 ${b.templates.length} · 待办 ${b.todos.length} · '
    '计划块 ${b.blocks.length} · 课时 ${b.lessons.length} · '
    '单周覆盖 ${b.overrides.length} · 休息时段 ${b.restWindows.length}';

/// 「诊断信息」块 —— 鸿蒙 `BackupRepo.diagnostics()` 是按表 COUNT(*) 一行一行
/// 列出来的（`semester: 1` …）。安卓这边数据全在 bundle 里，直接按同名表数出来，
/// 顺序与鸿蒙一致（`todo_blacklist` 在安卓是 kv，不进备份，故不出现在这一块）。
String diagnosticsText(BackupBundle b,
    {int? blacklistCount, String? report}) {
  final lines = <String>[
    'semester: ${b.semesters.length}',
    'section_time: ${b.sectionTimes.length}',
    'course: ${b.courses.length}',
    'session_rule: ${b.rules.length}',
    'session_override: ${b.overrides.length}',
    'todo_template: ${b.templates.length}',
    'todo: ${b.todos.length}',
    // 鸿蒙这一行查的是 `todo_blacklist` 表；安卓把它存在 kv 里（`todo_blacklist`），
    // 由外壳数好传进来（传 null = 不显示这一行）
    if (blacklistCount != null) 'todo_blacklist: $blacklistCount',
    'virtual_lesson: ${b.lessons.length}',
    'plan_block: ${b.blocks.length}',
    'rest_window: ${b.restWindows.length}',
  ];
  if (report != null && report.isNotEmpty) {
    lines.add('');
    lines.add('--- 上次启动报告 ---');
    lines.add(report);
  }
  return lines.join('\n');
}
