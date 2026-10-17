// 课程管理 —— 鸿蒙端 `view/CourseManager.ets` 的安卓版（第一版）：
//
//   课表页头「管理课程」→ 全屏浮层：
//     学期（只读摘要）/ 上课节次时间（摘要）/ 课程列表（+ 新增课程）
//     点课程 → 右侧抽屉：名称/简称/教师/地点/颜色/自动生成待办/虚拟课程
//                          + 时段规则（周一…周日 × 起止节次）增删改
//                          + 待办模板（标题模板 / 截止规则 / 预计耗时 / 类型）增删改
//                          + 删除课程（二次确认）
//
// 数据整份写回仓库（`onChanged(bundle)`），与其它页面一致。

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/backup.dart';
import '../data/backup_export.dart';
import '../domain/dates.dart';
import '../domain/todo_generator.dart' show renderTitle;
import '../domain/week_mask.dart';
import '../model/types.dart';
import 'app_frame.dart';
import 'inline_toast.dart';
import 'section_times_editor.dart';
import 'theme.dart';

/// 复制一份 bundle，只换 courses / rules / templates
/// 时段一行（鸿蒙 `ruleText`）：周X 3-4 节 · 1-16 · 习题课
String ruleText(SessionRule r) {
  final sec = r.startSection == r.endSection
      ? '${r.startSection}'
      : '${r.startSection}-${r.endSection}';
  final quiz = r.isQuiz ? ' 习题课' : '';
  return '周${weekdayCn[r.weekday - 1]} $sec 节 · ${maskToText(r.weeksMask)}$quiz';
}

/// 模板变量（与 ArkTS `Validate.TEMPLATE_VARS` 同序）与按钮上的中文标签
const List<String> kTemplateVars = ['C', 'c', 'D', 'd', 'W', 'T', 'N', 'R'];
const List<String> kTemplateVarLabels = [
  '课程全名',
  '课程简称',
  '布置日期',
  '完整日期',
  '周次',
  '起始节次',
  '第几次',
  '教室',
];

/// 截止规则的键与中文标签（与 ArkTS `DD_RULES` / `DD_LABELS` 同序）
const List<String> kDdRules = [
  'next_session',
  'weekday',
  'week_end',
  'same_day',
  'days',
  'none',
];
const List<String> kDdLabels = [
  '下一次同门课当天 23:59',
  '指定星期几 23:59',
  '本周日 23:59',
  '布置当天 23:59',
  'N 天后 23:59',
  '不设截止',
];

BackupBundle _with(
  BackupBundle b, {
  List<Semester>? semesters,
  List<SectionTime>? sectionTimes,
  List<Course>? courses,
  List<SessionRule>? rules,
  List<TodoTemplate>? templates,
  List<VirtualLesson>? lessons,
  List<PlanBlock>? blocks,
}) =>
    BackupBundle(
      app: b.app,
      version: b.version,
      exportedAt: b.exportedAt,
      semesters: semesters ?? b.semesters,
      sectionTimes: sectionTimes ?? b.sectionTimes,
      courses: courses ?? b.courses,
      rules: rules ?? b.rules,
      overrides: b.overrides,
      todos: b.todos,
      blocks: blocks ?? b.blocks,
      restWindows: b.restWindows,
      templates: templates ?? b.templates,
      lessons: lessons ?? b.lessons,
    );

int _nextId<T>(List<T> list, int Function(T) id) =>
    list.fold<int>(0, (m, x) => id(x) > m ? id(x) : m) + 1;

Future<void> showCourseManager(
  BuildContext context, {
  required BackupBundle bundle,
  required void Function(BackupBundle next) onChanged,
  Future<void> Function()? onImport,
}) {
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: '关闭课程管理',
    barrierColor: const Color(0x990C1220),
    transitionDuration: dur(durDrawer),
    pageBuilder: (ctx, _, __) =>
        _Manager(bundle: bundle, onChanged: onChanged, onImport: onImport),
    transitionBuilder: (ctx, anim, _, child) {
      final curved = CurvedAnimation(parent: anim, curve: drawerCurve);
      return FadeTransition(
        opacity: curved,
        child: ScaleTransition(
            scale: Tween<double>(begin: 0.96, end: 1).animate(curved),
            child: child),
      );
    },
  );
}

class _Manager extends StatefulWidget {
  final BackupBundle bundle;
  final void Function(BackupBundle next) onChanged;

  /// 「导入备份」入口（鸿蒙端：管理课程 → 备份与恢复 → 从备份恢复）
  final Future<void> Function()? onImport;
  const _Manager(
      {required this.bundle, required this.onChanged, this.onImport});

  @override
  State<_Manager> createState() => _ManagerState();
}

/// 课程编辑子页的结果：改好后的整份数据 + 是不是"删除"（列表要用它决定提示语）
class _CourseEditResult {
  final BackupBundle bundle;
  final bool deleted;
  const _CourseEditResult(this.bundle, {this.deleted = false});
}

class _ManagerState extends State<_Manager> {
  late BackupBundle _b = widget.bundle;

  /// 「清空本学期课程」的二次确认状态
  bool _confirmClear = false;

  /// 列表顶部的提示条（鸿蒙 CourseManager 的 `toast`：一行蓝字，2.2 秒消失）
  String _toast = '';
  Timer? _toastTimer;

  void _showToast(String text) {
    _toastTimer?.cancel();
    setState(() => _toast = text);
    _toastTimer = Timer(const Duration(milliseconds: 2200), () {
      if (mounted) setState(() => _toast = '');
    });
  }

  @override
  void dispose() {
    _toastTimer?.cancel();
    super.dispose();
  }

  void _apply(BackupBundle next) {
    setState(() => _b = next);
    widget.onChanged(next);
  }


  @override
  Widget build(BuildContext context) {
    return Material(
      type: MaterialType.transparency,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(floatSide),
          child: Glass(
            sheet: true,
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // ---- 顶栏 ----
                Row(
                  children: [
                    GestureDetector(
                      onTap: () => Navigator.of(context).pop(),
                      behavior: HitTestBehavior.opaque,
                      // 鸿蒙 TopBar：左边「关闭」蓝字、中间标题 16 Medium
                      child: const Padding(
                        padding: EdgeInsets.only(right: 12, top: 6, bottom: 6),
                        child: Text('关闭',
                            style: TextStyle(fontSize: 15, color: accentBlue)),
                      ),
                    ),
                    const Spacer(),
                    const Text('课程与学期',
                        style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w500,
                            color: inkPrimary)),
                    const Spacer(),
                    const SizedBox(width: 60),
                  ],
                ),
                const SizedBox(height: 6),
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (_toast.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 4),
                            child: Text(_toast,
                                style: const TextStyle(
                                    fontSize: 12, color: accentBlue)),
                          ),
                        // 鸿蒙列表首屏是**三张入口卡**：学期 / 上课节次时间 / 备份与恢复
                        _entryRow(
                          key: const ValueKey('entry-semester'),
                          '学期',
                          _b.semester == null
                              ? ''
                              : '${_b.semester!.name} · ${_b.semester!.startDate} 起 · '
                                  '${_b.semester!.totalWeeks} 周',
                          onTap: _openSemesterSheet,
                        ),
                        _entryRow(
                          key: const ValueKey('entry-sections'),
                          '上课节次时间',
                          '${_b.sectionTimes.length} 节 · 可随意改',
                          onTap: _openSections,
                        ),
                        _entryRow('备份与恢复', '导出 JSON / 整份恢复 / 诊断',
                            key: const ValueKey('entry-backup'),
                            onTap: _openBackupSheet),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            Text('课程（${_b.courses.length}）',
                                style: const TextStyle(
                                    fontSize: 15,
                                    fontWeight: FontWeight.w500,
                                    color: inkPrimary)),
                            const Spacer(),
                            _PillAction(
                              text: '+ 新增课程',
                              onTap: () => _openCourse(null),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        if (_b.courses.isEmpty)
                          const Padding(
                            padding: EdgeInsets.symmetric(vertical: 12),
                            child: Text(
                              '还没有课程。点右上角「新增课程」开始建立自己的课表；'
                              '也可以用「备份与恢复」导入之前导出的备份。',
                                style: TextStyle(
                                    fontSize: 12, color: Color(0xFF8B97AC))),
                          ),
                        for (final c in _b.courses) _courseCard(c),
                        // 清空本学期课程放在列表末尾（鸿蒙同位置），两次确认
                        if (_b.courses.isNotEmpty) ...[
                          const SizedBox(height: 4),
                          if (_confirmClear)
                            Row(
                              children: [
                                const Expanded(
                                  child: Text(
                                      '确定清空本学期的全部课程？课程、上课时段与生成模板都会删掉，手改的内容会丢。',
                                      style: TextStyle(
                                          fontSize: 11,
                                          color: Color(0xFFFF8A8A))),
                                ),
                                GestureDetector(
                                  onTap: () =>
                                      setState(() => _confirmClear = false),
                                  behavior: HitTestBehavior.opaque,
                                  child: const Padding(
                                    padding:
                                        EdgeInsets.symmetric(horizontal: 8),
                                    child: Text('取消',
                                        style: TextStyle(
                                            fontSize: 12,
                                            color: Color(0xFFA9B5C9))),
                                  ),
                                ),
                                GestureDetector(
                                  onTap: _clearSemesterCourses,
                                  behavior: HitTestBehavior.opaque,
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 10, vertical: 4),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFFD64545),
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    child: const Text('确定重载',
                                        style: TextStyle(
                                            fontSize: 12,
                                            color: Colors.white)),
                                  ),
                                ),
                              ],
                            )
                          else
                            GestureDetector(
                              onTap: () =>
                                  setState(() => _confirmClear = true),
                              behavior: HitTestBehavior.opaque,
                              child: const Padding(
                                padding: EdgeInsets.only(top: 8),
                                child: Text('清空本学期课程',
                                    style: TextStyle(
                                        fontSize: 12,
                                        color: Color(0xFF8B97AC))),
                              ),
                            ),
                        ],
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 入口卡（鸿蒙列表里那三张）：左标题 15 Medium，右侧摘要 12 灰字
  Widget _entryRow(String title, String summary,
      {VoidCallback? onTap, Key? key}) {
    return GestureDetector(
      key: key,
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        margin: const EdgeInsets.only(bottom: 8),
        decoration: BoxDecoration(
          color: glassTintRow,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: glassEdgeSoft),
        ),
        child: Row(
          children: [
            Text(title,
                style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                    color: inkPrimary)),
            const SizedBox(width: 10),
            Flexible(
              child: Text(summary,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.right,
                  style:
                      const TextStyle(fontSize: 12, color: Color(0xFF94A0B5))),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _openSemesterSheet() async {
    await showDialog<void>(
      context: context,
      barrierColor: const Color(0x990C1220),
      builder: (ctx) => _SemesterSheet(
        b: _b,
        onChanged: (next) => _apply(next),
      ),
    );
  }

  Future<void> _openBackupSheet() async {
    await showDialog<void>(
      context: context,
      barrierColor: const Color(0x990C1220),
      builder: (ctx) => _BackupSheet(
        b: _b,
        onChanged: (next) => _apply(next),
        onImport: widget.onImport,
      ),
    );
  }


  /// 「上课节次时间」子页（鸿蒙端 SectionsView）：改完立刻影响课表格子排布
  Future<void> _openSections() async {
    final sem = _b.semester;
    if (sem == null) return;
    final rows = _b.sectionTimes.where((s) => s.semesterId == sem.id).toList();
    final next = await showSectionTimesEditor(context,
        semesterId: sem.id, sections: rows);
    if (next == null || !mounted) return;
    _apply(_with(_b, sectionTimes: [
      ..._b.sectionTimes.where((s) => s.semesterId != sem.id),
      ...next,
    ]));
    _showToast('节次时间已保存');
  }

  /// 课程卡（鸿蒙 `lc-` 那张）：彩色简称胶囊 + 全名，下面逐条列时段与模板
  Widget _courseCard(Course c) {
    final rules = _b.rules.where((r) => r.courseId == c.id).toList()
      ..sort((a, b) => a.weekday == b.weekday
          ? a.startSection - b.startSection
          : a.weekday - b.weekday);
    final templates = _b.templates.where((t) => t.courseId == c.id).toList();
    final lessons = _b.lessons.where((l) => l.courseId == c.id).toList();
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: GestureDetector(
        key: ValueKey('course-${c.id}'),
        onTap: () => _openCourse(c),
        behavior: HitTestBehavior.opaque,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: glassTintRow,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: glassEdgeSoft),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: courseColor(c.colorIndex),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                        c.shortName.isNotEmpty ? c.shortName : c.name,
                        style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                            color: Color(0xFFF2F5FA))),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(c.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 13, color: Color(0xFFC3CDDE))),
                  ),
                  if (!c.autoTodoEnabled)
                    const Text('不自动生成',
                        style: TextStyle(
                            fontSize: 10, color: Color(0xFF8B97AC))),
                ],
              ),
              for (final r in rules)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(_ruleText(r),
                      style: const TextStyle(
                          fontSize: 11, color: Color(0xFF9BA7BD))),
                ),
              for (final t in templates)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text('⚙ ${_tplText(t)}',
                      style: const TextStyle(
                          fontSize: 11, color: Color(0xFF7BD69A))),
                ),
              if (c.isVirtual)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                      '虚拟课程 · ${lessons.length} 讲，'
                      '已完成 ${lessons.where((l) => l.done).length}',
                      style: const TextStyle(
                          fontSize: 11, color: Color(0xFFE0A94E))),
                ),
            ],
          ),
        ),
      ),
    );
  }

  String _ruleText(SessionRule r) => ruleText(r);

  /// 模板一行（鸿蒙 `tplText`）：标题 · 截止：<规则>（参数） · 预计 N 分钟
  String _tplText(TodoTemplate t) {
    final idx = kDdRules.indexOf(t.ddlRule);
    final label = idx >= 0 ? kDdLabels[idx] : t.ddlRule;
    var param = '';
    if (t.ddlRule == 'weekday' && t.ddlParam.isNotEmpty) {
      final w = int.tryParse(t.ddlParam) ?? 0;
      if (w >= 1 && w <= 7) param = '（周${weekdayCn[w - 1]}）';
    } else if (t.ddlRule == 'days' && t.ddlParam.isNotEmpty) {
      param = '（${t.ddlParam} 天）';
    }
    return '${t.titleTemplate} · 截止：$label$param · 预计 ${t.estimateMin} 分钟';
  }

  /// 「备份与恢复」：导出 JSON 到应用文档目录（鸿蒙端是同名子页）

  /// 诊断信息（鸿蒙端「备份与恢复」子页里那块）：一眼看清各表条数

  /// 清空本学期课程（二次确认；对应鸿蒙端「清空本学期课程」）
  void _clearSemesterCourses() {
    if (!_confirmClear) {
      setState(() => _confirmClear = true);
      return;
    }
    final semId = _b.semester?.id ?? 0;
    final doomed =
        _b.courses.where((c) => c.semesterId == semId).map((c) => c.id).toSet();
    setState(() => _confirmClear = false);
    _apply(_with(
      _b,
      courses: _b.courses.where((c) => !doomed.contains(c.id)).toList(),
      rules: _b.rules.where((r) => !doomed.contains(r.courseId)).toList(),
      templates:
          _b.templates.where((t) => !doomed.contains(t.courseId)).toList(),
      lessons: _b.lessons.where((l) => !doomed.contains(l.courseId)).toList(),
    ));
    _showToast('已清空本学期的课程');
  }


  /// 「学期」区块：列出全部学期（第一个 = 当前）、可切换、可新建（可顺便复制课表）



  Future<void> _openCourse(Course? existing) async {
    final res = await showDialog<_CourseEditResult>(
      context: context,
      barrierColor: const Color(0x8C0C1220),
      builder: (_) => _CourseEditor(b: _b, existing: existing),
    );
    if (res == null) return;
    _apply(res.bundle);
    _showToast(res.deleted ? '课程已删除' : '已保存');
  }
}

class _PillAction extends StatelessWidget {
  final String text;
  final VoidCallback onTap;


  const _PillAction({required this.text, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: const Color(0x382E6BE6),
          borderRadius: BorderRadius.circular(12),
        ),
        child:
            Text(text, style: const TextStyle(fontSize: 12, color: accentBlue)),
      ),
    );
  }
}

// ---------------- 课程编辑（右侧抽屉）----------------

class _CourseEditor extends StatefulWidget {
  final BackupBundle b;
  final Course? existing;
  const _CourseEditor({required this.b, this.existing});

  @override
  State<_CourseEditor> createState() => _CourseEditorState();
}

class _CourseEditorState extends State<_CourseEditor> {
  late BackupBundle _b = widget.b;
  late final TextEditingController _name =
      TextEditingController(text: widget.existing?.name ?? '');
  late final TextEditingController _short =
      TextEditingController(text: widget.existing?.shortName ?? '');
  late final TextEditingController _teacher =
      TextEditingController(text: widget.existing?.teacher ?? '');
  late final TextEditingController _location =
      TextEditingController(text: widget.existing?.location ?? '');
  late int _color = widget.existing?.colorIndex ?? 0;
  late bool _auto = widget.existing?.autoTodoEnabled ?? true;
  late bool _virtual = widget.existing?.isVirtual ?? false;

  /// 虚拟课程的课时数（鸿蒙 1–50 的滑条；保存时按这个数增删 lesson）
  late int _lessonCount = widget.b.lessons
      .where((l) => l.courseId == (widget.existing?.id ?? 0))
      .length
      .clamp(1, 50);

  bool _confirmDelete = false;
  String? _error;

  Course? get existing => widget.existing;
  int get _id => existing?.id ?? 0;

  @override
  void dispose() {
    _name.dispose();
    _short.dispose();
    _teacher.dispose();
    _location.dispose();
    super.dispose();
  }

  List<SessionRule> get _rules =>
      _b.rules.where((r) => r.courseId == _id).toList()
        ..sort((a, b) => a.weekday == b.weekday
            ? a.startSection - b.startSection
            : a.weekday - b.weekday);

  List<TodoTemplate> get _templates =>
      _b.templates.where((t) => t.courseId == _id).toList();
  /// 给虚拟课程加一讲（第 N 讲，N = 现有最大讲次 + 1）

  void _save() {
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _error = '课程名不能为空');
      return;
    }
    final course = Course(
      id: _id > 0 ? _id : _nextId<Course>(_b.courses, (c) => c.id),
      semesterId: existing?.semesterId ?? (_b.semester?.id ?? 0),
      name: name,
      shortName: _short.text.trim(),
      teacher: _teacher.text.trim(),
      location: _location.text.trim(),
      colorIndex: _color,
      autoTodoEnabled: _auto,
      isVirtual: _virtual,
      note: existing?.note ?? '',
    );
    final courses = _id > 0
        ? _b.courses.map((c) => c.id == _id ? course : c).toList()
        : [..._b.courses, course];

    // 虚拟课程：按滑条讲数整批同步（鸿蒙 `syncLessonCount`）：
    //   - 少的补上「第 N 讲」
    //   - 多的删掉**未完成**的那些（已完成的保留，记录不能悄悄消失）
    var lessons = _b.lessons;
    var blocks = _b.blocks;
    if (_virtual) {
      final cid = course.id;
      final mine = lessons.where((l) => l.courseId == cid).toList()
        ..sort((a, b) => a.seq - b.seq);
      final removed = mine
          .where((l) => l.seq > _lessonCount && !l.done)
          .map((l) => l.id)
          .toSet();
      if (removed.isNotEmpty) {
        lessons = lessons.where((l) => !removed.contains(l.id)).toList();
        blocks = blocks.where((b) => !removed.contains(b.lessonId)).toList();
      }
      final seqs = {
        for (final l in lessons.where((l) => l.courseId == cid)) l.seq
      };
      for (var seq = 1; seq <= _lessonCount; seq++) {
        if (seqs.contains(seq)) continue;
        lessons = [
          ...lessons,
          VirtualLesson(
            id: _nextId<VirtualLesson>(lessons, (l) => l.id),
            courseId: cid,
            seq: seq,
            title: '第 $seq 讲',
          ),
        ];
      }
    }
    Navigator.of(context).pop(_CourseEditResult(
        _with(_b, courses: courses, lessons: lessons, blocks: blocks)));
  }

  void _delete() {
    final rules = _b.rules.where((r) => r.courseId != _id).toList();
    final templates = _b.templates.where((t) => t.courseId != _id).toList();
    final lessons = _b.lessons.where((l) => l.courseId != _id).toList();
    final courses = _b.courses.where((c) => c.id != _id).toList();
    Navigator.of(context).pop(_CourseEditResult(
        _with(_b,
            courses: courses,
            rules: rules,
            templates: templates,
            lessons: lessons),
        deleted: true));
  }

  Future<void> _editRule(SessionRule? r) async {
    final next = await showDialog<BackupBundle>(
      context: context,
      builder: (_) => _RuleDialog(b: _b, courseId: _id, existing: r),
    );
    if (next != null) setState(() => _b = next);
  }

  Future<void> _editTemplate(TodoTemplate? t) async {
    final next = await showDialog<BackupBundle>(
      context: context,
      builder: (_) => _TemplateDialog(b: _b, courseId: _id, existing: t),
    );
    if (next != null) setState(() => _b = next);
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      child: Glass(
        sheet: true,
        padding: const EdgeInsets.fromLTRB(18, 14, 18, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 鸿蒙 CourseView 是子页：左「‹ 返回」、中「新增/编辑课程」
            Row(
              children: [
                GestureDetector(
                  onTap: () => Navigator.of(context).pop(),
                  behavior: HitTestBehavior.opaque,
                  child: const Text('‹ 返回',
                      style: TextStyle(fontSize: 15, color: accentBlue)),
                ),
                const Spacer(),
                Text(_id == 0 ? '新增课程' : '编辑课程',
                    style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w500,
                        color: inkPrimary)),
                const Spacer(),
                const SizedBox(width: 44),
              ],
            ),
            const SizedBox(height: 8),
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _field(_name, '课程名（全称）', '高等数学'),
                    if (_error != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(_error!,
                            style: const TextStyle(
                                fontSize: 11, color: Color(0xFFFF8080))),
                      ),
                    _field(_short, '简称（显示在课表格子里）', '高数'),
                    _field(_teacher, '教师', '王老师'),
                    _field(_location, '默认地点', '教学楼 101'),
                    const _Label('颜色'),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (var i = 0; i < courseColors.length; i++)
                          GestureDetector(
                            onTap: () => setState(() => _color = i),
                            child: Container(
                              width: 26,
                              height: 26,
                              decoration: BoxDecoration(
                                color: courseColors[i],
                                shape: BoxShape.circle,
                                border: Border.all(
                                    width: _color == i ? 2 : 0,
                                    color: Colors.white),
                              ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    _switchRow(
                      '下课后自动生成待办',
                      _auto,
                      (v) => setState(() => _auto = v),
                      sub: '关掉它就只保留手填的事项（比如你不去上的课）',
                    ),
                    _switchRow(
                      '虚拟课程（不定时上课）',
                      _virtual,
                      (v) => setState(() => _virtual = v),
                      sub: '比如 CS106L：没有固定上课时间，是一串等着被排进计划的课时',
                    ),
                    if (_virtual) ...[
                      // 鸿蒙：讲数只用 1–50 的滑条（用户明确说"不要设计那么多按钮"）
                      Text('共多少讲（当前 $_lessonCount）',
                          style: const TextStyle(
                              fontSize: 12, color: Color(0xFF94A0B5))),
                      const SizedBox(height: 6),
                      SliderTheme(
                        data: SliderTheme.of(context).copyWith(
                          trackHeight: 4,
                          thumbShape:
                              const RoundSliderThumbShape(enabledThumbRadius: 9),
                          overlayShape:
                              const RoundSliderOverlayShape(overlayRadius: 16),
                        ),
                        child: Slider(
                          value: _lessonCount.toDouble(),
                          min: 1,
                          max: 50,
                          divisions: 49,
                          activeColor: const Color(0xFF2E6BE6),
                          inactiveColor:
                              Colors.white.withValues(alpha: 0.16),
                          onChanged: (v) =>
                              setState(() => _lessonCount = v.round()),
                        ),
                      ),
                      Row(
                        children: [
                          const Text('1',
                              style: TextStyle(
                                  fontSize: 10, color: Color(0xFF8B97AC))),
                          const Spacer(),
                          Text('$_lessonCount 讲',
                              style: const TextStyle(
                                  fontSize: 12, color: Color(0xFF7FA8FF))),
                          const Spacer(),
                          const Text('50',
                              style: TextStyle(
                                  fontSize: 10, color: Color(0xFF8B97AC))),
                        ],
                      ),
                      const Text(
                          '课时排进计划、打勾完成之后，会像真课下课一样按下面的模板生成待办。',
                          style: TextStyle(
                              fontSize: 11, color: Color(0xFF7BD69A))),
                    ],
                    if (_id > 0) ...[
                      _sectionTitle(
                          _virtual ? '上课时段（虚拟课程可留空）' : '上课时段（${_rules.length}）',
                          url: '+ 添加时段',
                          onAdd: () => _editRule(null)),
                      if (_rules.isEmpty)
                        const Text('还没有时段。一周上两次就加两条。',
                            style: TextStyle(
                                fontSize: 12, color: Color(0xFF8B97AC))),
                      for (final r in _rules)
                        _row(
                          ruleText(r),
                          onEdit: () => _editRule(r),
                          onDelete: () {
                            setState(() => _b = _with(_b,
                                rules: _b.rules
                                    .where((x) => x.id != r.id)
                                    .toList()));
                          },
                        ),
                      _sectionTitle('待办生成模板（${_templates.length}）',
                          url: '+ 添加模板',
                          onAdd: () => _editTemplate(null)),
                      const SizedBox(height: 4),
                      if (_templates.isEmpty)
                        const Text('没有模板 → 这门课下课不会自动生成待办。',
                            style: TextStyle(
                                fontSize: 12, color: Color(0xFF8B97AC))),
                      for (final t in _templates)
                        _row(
                          '「${t.titleTemplate}」 · ${_ddlRuleText(t)} · ${t.estimateMin} 分钟'
                          '${t.enabled ? '' : ' · 已停用'}',
                          onEdit: () => _editTemplate(t),
                          onDelete: () {
                            setState(() => _b = _with(_b,
                                templates: _b.templates
                                    .where((x) => x.id != t.id)
                                    .toList()));
                          },
                        ),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: GestureDetector(
                    key: const ValueKey('course-save'),
                    onTap: _save,
                    behavior: HitTestBehavior.opaque,
                    child: Container(
                      height: 40,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: const Color(0xFF2E6BE6),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: const Text('保存课程',
                          style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w500,
                              color: Colors.white)),
                    ),
                  ),
                ),
                if (_id > 0) ...[
                  const SizedBox(width: 10),
                  GestureDetector(
                    onTap: () {
                      if (_confirmDelete) {
                        _delete();
                      } else {
                        setState(() => _confirmDelete = true);
                      }
                    },
                    behavior: HitTestBehavior.opaque,
                    child: Container(
                      height: 40,
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: const Color(0x2ED64545),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(_confirmDelete ? '确认删除课程' : '删除课程',
                          style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w500,
                              color: Color(0xFFFF8A8A))),
                    ),
                  ),
                ],
              ],
            ),
            if (_confirmDelete && _id > 0)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                    '确定删除「${_short.text.isNotEmpty ? _short.text : _name.text}」'
                    '及其所有时段、模板？',
                    style: const TextStyle(
                        fontSize: 11, color: Color(0xFFFF8A8A))),
              ),
          ],
        ),
      ),
    );
  }

  Widget _field(TextEditingController c, String label, String hint) {
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: const TextStyle(fontSize: 12, color: Color(0xFF94A0B5))),
          const SizedBox(height: 4),
          Container(
            height: 40,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            alignment: Alignment.centerLeft,
            // 鸿蒙裸 TextInput：无可见底色
            decoration: const BoxDecoration(),
            child: TextField(
              controller: c,
              style: const TextStyle(fontSize: 14, color: inkPrimary),
              cursorColor: accentBlue,
              decoration: InputDecoration(
                isDense: true,
                border: InputBorder.none,
                hintText: hint,
                hintStyle:
                    const TextStyle(fontSize: 14, color: Color(0xFF8B97AC)),
              ),
              onChanged: (_) {
                if (_error != null) setState(() => _error = null);
              },
            ),
          ),
        ],
      ),
    );
  }

  /// 区段标题（鸿蒙：左标题 14 Medium、右「+ 添加…」13 蓝字）
  Widget _sectionTitle(String title, {required String url, required VoidCallback onAdd}) {
    return Padding(
      padding: const EdgeInsets.only(top: 18, bottom: 8),
      child: Row(
        children: [
          Expanded(
            child: Text(title,
                style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: inkPrimary)),
          ),
          GestureDetector(
            onTap: onAdd,
            behavior: HitTestBehavior.opaque,
            child: Text(url,
                style: const TextStyle(fontSize: 13, color: accentBlue)),
          ),
        ],
      ),
    );
  }

  Widget _switchRow(String text, bool value, ValueChanged<bool> onChanged,
      {String? sub}) {
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(text,
                  style: const TextStyle(fontSize: 14, color: inkPrimary)),
              if (sub != null)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(sub,
                      style: const TextStyle(
                          fontSize: 11, color: Color(0xFF94A0B5))),
                ),
            ],
          ),
        ),
        Switch(
            value: value,
            activeThumbColor: const Color(0xFF2E6BE6),
            onChanged: onChanged),
      ],
    );
  }

  Widget _row(String text,
      {required VoidCallback onEdit,
      required VoidCallback onDelete,
      String editLabel = '改'}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Container(
        padding: const EdgeInsets.fromLTRB(10, 6, 6, 6),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(text,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style:
                      const TextStyle(fontSize: 12, color: Color(0xFFC3CDDE))),
            ),
            _MiniAction(text: editLabel, color: accentBlue, onTap: onEdit),
            _MiniAction(text: '删', color: dangerRed, onTap: onDelete),
          ],
        ),
      ),
    );
  }
}

String _ddlRuleText(TodoTemplate t) {
  switch (t.ddlRule) {
    case 'none':
      return '不设截止';
    case 'same_day':
      return '当天 23:59';
    case 'days':
      return '${t.ddlParam.isEmpty ? 1 : t.ddlParam} 天后';
    case 'weekday':
      return '周${t.ddlParam.isEmpty ? '日' : t.ddlParam} 23:59';
    case 'week_end':
      return '本周日 23:59';
    default:
      return '下次课当天 23:59';
  }
}

class _Label extends StatelessWidget {
  final String text;
  const _Label(this.text);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 14, bottom: 6),
        child: Text(text,
            style: const TextStyle(fontSize: 12, color: Color(0xFF94A0B5))),
      );
}

class _MiniAction extends StatelessWidget {
  final String text;
  final Color color;
  final VoidCallback onTap;
  const _MiniAction(
      {required this.text, required this.color, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        child: Text(text, style: TextStyle(fontSize: 12, color: color)),
      ),
    );
  }
}

// ---------------- 时段规则弹窗 ----------------

class _RuleDialog extends StatefulWidget {
  final BackupBundle b;
  final int courseId;
  final SessionRule? existing;
  const _RuleDialog({required this.b, required this.courseId, this.existing});

  @override
  State<_RuleDialog> createState() => _RuleDialogState();
}

class _RuleDialogState extends State<_RuleDialog> {
  late int _weekday = widget.existing?.weekday ?? 1;
  late int _start = widget.existing?.startSection ?? 1;
  late int _end = widget.existing?.endSection ?? 2;
  late final TextEditingController _location =
      TextEditingController(text: widget.existing?.location ?? '');
  late final TextEditingController _weeks = TextEditingController(
      text: maskToText(widget.existing?.weeksMask ??
          maskAll(widget.b.semester?.totalWeeks ?? 16)));
  late bool _quiz = widget.existing?.isQuiz ?? false;

  @override
  void dispose() {
    _location.dispose();
    _weeks.dispose();
    super.dispose();
  }

  void _save() {
    final b = widget.b;
    final id =
        widget.existing?.id ?? _nextId<SessionRule>(b.rules, (r) => r.id);
    final rule = SessionRule(
      id: id,
      courseId: widget.courseId,
      weekday: _weekday,
      startSection: _start,
      endSection: _end < _start ? _start : _end,
      // 周次按用户填的文本解析（支持 1-16 / 1-16单 / 2-16双 / 1-8,10-16…）
      weeksMask: maskFromText(_weeks.text, b.semester?.totalWeeks ?? 16),
      location: _location.text.trim(),
      isQuiz: _quiz,
    );
    final rules = widget.existing == null
        ? [...b.rules, rule]
        : b.rules.map((r) => r.id == id ? rule : r).toList();
    Navigator.of(context).pop(_with(b, rules: rules));
  }

  @override
  Widget build(BuildContext context) {
    const names = ['一', '二', '三', '四', '五', '六', '日'];
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 40),
      child: Glass(
        sheet: true,
        padding: const EdgeInsets.all(18),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(widget.existing == null ? '添加上课时段' : '修改上课时段',
                  style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w500,
                      color: inkPrimary)),
              const _Label('星期'),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (var d = 1; d <= 7; d++)
                    _Chip(
                      text: '周${names[d - 1]}',
                      selected: _weekday == d,
                      onTap: () => setState(() => _weekday = d),
                    ),
                ],
              ),
              const _Label('开始节次'),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (var i = 1; i <= 12; i++)
                    _Chip(
                      text: '$i',
                      selected: _start == i,
                      onTap: () => setState(() {
                        _start = i;
                        if (_end < i) _end = i;
                      }),
                    ),
                ],
              ),
              const _Label('结束节次'),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (var i = 1; i <= 12; i++)
                    _Chip(
                      text: '$i',
                      selected: _end == i,
                      onTap: () =>
                          setState(() => _end = i < _start ? _start : i),
                    ),
                ],
              ),
              const _Label('周次（支持 1-16 / 1-8,10-16 / 1-16单 / 2-16双）'),
              _dialogInput(_weeks, '1-16'),
              const SizedBox(height: 8),
              Row(
                children: [
                  const Expanded(
                    child: Text('习题课（课表上虚线框）',
                        style: TextStyle(fontSize: 13, color: inkPrimary)),
                  ),
                  Switch(
                      value: _quiz,
                      activeThumbColor: const Color(0xFF2E6BE6),
                      onChanged: (v) => setState(() => _quiz = v)),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  const Spacer(),
                  _PillAction(
                      text: '取消', onTap: () => Navigator.of(context).pop()),
                  const SizedBox(width: 10),
                  FilledButton(
                    onPressed: _save,
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF2E6BE6),
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(20)),
                    ),
                    child: const Text('保存', style: TextStyle(fontSize: 13)),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------- 模板弹窗 ----------------

class _TemplateDialog extends StatefulWidget {
  final BackupBundle b;
  final int courseId;
  final TodoTemplate? existing;
  const _TemplateDialog(
      {required this.b, required this.courseId, this.existing});

  @override
  State<_TemplateDialog> createState() => _TemplateDialogState();
}

class _TemplateDialogState extends State<_TemplateDialog> {
  late final TextEditingController _title =
      TextEditingController(text: widget.existing?.titleTemplate ?? '%D作业');
  late String _rule = widget.existing?.ddlRule ?? 'next_session';
  late final TextEditingController _param =
      TextEditingController(text: widget.existing?.ddlParam ?? '');
  late int _estimate = widget.existing?.estimateMin ?? 60;
  late final String _category = widget.existing?.category ?? 'homework';
  late final bool _enabled = widget.existing?.enabled ?? true;
  String? _error;
  int _caret = 0;

  void _insertVar(String v) {
    final text = _title.text;
    final at = _caret.clamp(0, text.length);
    final next = '${text.substring(0, at)}%$v${text.substring(at)}';
    setState(() {
      _title.value = TextEditingValue(
        text: next,
        selection: TextSelection.collapsed(offset: at + 1 + v.length),
      );
      _caret = at + 1 + v.length;
    });
  }

  /// 实时预览（鸿蒙 `templatePreviewText`）：渲染一遍样例
  String _previewText() {
    final b = widget.b;
    Course? course;
    for (final c in b.courses) {
      if (c.id == widget.courseId) course = c;
    }
    final sem = b.semester;
    final sample = CourseSession(
      course: course ?? Course(name: '示例课程', shortName: '示例'),
      rule: SessionRule(courseId: widget.courseId),
      date: sem?.startDate ?? '2026-09-07',
      originDate: sem?.startDate ?? '2026-09-07',
      weekday: 1,
      startSection: 1,
      endSection: 2,
      startMin: 8 * 60,
      endMin: 9 * 60,
      location: course?.location ?? '',
      isQuiz: false,
      fromOverride: false,
      isExtra: false,
    );
    final ok = _previewOk;
    final rendered = renderTitle(_title.text, sample, 1, 1);
    return ok
        ? '预览：$rendered'
        : '预览：$rendered（标题里要有可选文字，不能只有变量）';
  }

  bool get _previewOk {
    final t = _title.text.trim();
    return t.isNotEmpty && t.replaceAll(RegExp(r'%[CcdWwTNnR]'), '').trim().isNotEmpty;
  }

  @override
  void dispose() {
    _title.dispose();
    _param.dispose();
    super.dispose();
  }

  void _save() {
    if (_title.text.trim().isEmpty) {
      setState(() => _error = '标题模板不能为空');
      return;
    }
    final b = widget.b;
    final id =
        widget.existing?.id ?? _nextId<TodoTemplate>(b.templates, (t) => t.id);
    final t = TodoTemplate(
      id: id,
      courseId: widget.courseId,
      sortOrder: widget.existing?.sortOrder ?? b.templates.length,
      enabled: _enabled,
      titleTemplate: _title.text.trim(),
      ddlRule: _rule,
      ddlParam: _param.text.trim(),
      estimateMin: _estimate,
      category: _category,
      submitChannel: widget.existing?.submitChannel ?? '',
      note: widget.existing?.note ?? '',
    );
    final templates = widget.existing == null
        ? [...b.templates, t]
        : b.templates.map((x) => x.id == id ? t : x).toList();
    Navigator.of(context).pop(_with(b, templates: templates));
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 40),
      child: Glass(
        sheet: true,
        padding: const EdgeInsets.all(18),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(widget.existing == null ? '添加生成模板' : '编辑生成模板',
                  style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w500,
                      color: inkPrimary)),
              const SizedBox(height: 4),
              const Text(
                  '变量：%C 课程全名 / %c 简称 / %D 布置日期 / %d 完整日期 / %W 周 / %T 节次 / %N 第几次 / %R 教室',
                  style: TextStyle(fontSize: 10, color: Color(0xFF8B97AC))),
              const SizedBox(height: 8),
              const Text('标题模板',
                  style: TextStyle(fontSize: 12, color: Color(0xFF94A0B5))),
              const SizedBox(height: 4),
              _dialogInput(_title, '例如：%c 第 %N 次作业',
                  onChanged: (_) {
                if (_error != null) setState(() => _error = null);
              }),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(_error!,
                      style: const TextStyle(
                          fontSize: 11, color: Color(0xFFFF8080))),
                ),
              // 快捷插入变量：点一下插到光标处（%C 这些记号没人记得住）
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final v in kTemplateVars)
                      _Chip(
                        text: kTemplateVarLabels[kTemplateVars.indexOf(v)],
                        selected: false,
                        onTap: () => _insertVar(v),
                      ),
                    _Chip(
                      text: '清空',
                      selected: false,
                      onTap: () => setState(() {
                        _title.text = '';
                        _caret = 0;
                      }),
                    ),
                  ],
                ),
              ),
              // 实时预览：拿这门课自己的名字 + 一个样例日期渲染一遍
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(_previewText(),
                    style: TextStyle(
                        fontSize: 11,
                        color: _previewOk
                            ? const Color(0xFF7BD69A)
                            : const Color(0xFFFF8A8A))),
              ),
              const _Label('截止时间规则'),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (var i = 0; i < kDdRules.length; i++)
                    _Chip(
                      text: kDdLabels[i],
                      selected: _rule == kDdRules[i],
                      onTap: () => setState(() => _rule = kDdRules[i]),
                    ),
                ],
              ),
              if (_rule == 'weekday') ...[
                const _Label('星期几'),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (var wd = 1; wd <= 7; wd++)
                      _Chip(
                        text: '周${weekdayCn[wd - 1]}',
                        selected: _param.text == '$wd',
                        onTap: () => setState(() => _param.text = '$wd'),
                      ),
                  ],
                ),
              ],
              if (_rule == 'days') ...[
                const _Label('几天后'),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final n in const [1, 2, 3, 5, 7, 14])
                      _Chip(
                        text: '$n 天',
                        selected: _param.text == '$n',
                        onTap: () => setState(() => _param.text = '$n'),
                      ),
                  ],
                ),
              ],
              const _Label('预计耗时（排计划时用来算块长）'),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final m in const [30, 45, 60, 90, 120, 180])
                    _Chip(
                      text: '$m 分钟',
                      selected: _estimate == m,
                      onTap: () => setState(() => _estimate = m),
                    ),
                ],
              ),
              const SizedBox(height: 18),
              Row(
                children: [
                  Expanded(
                    child: _PillAction(
                        text: '取消', onTap: () => Navigator.of(context).pop()),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: GestureDetector(
                      key: const ValueKey('template-save'),
                      onTap: _save,
                      behavior: HitTestBehavior.opaque,
                      child: Container(
                        height: 40,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: const Color(0xFF2E6BE6),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: const Text('保存',
                            style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w500,
                                color: Colors.white)),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 弹窗里的胶囊输入框（鸿蒙裸 `TextInput`：高 40、圆角 20）
Widget _dialogInput(TextEditingController c, String hint,
    {ValueChanged<String>? onChanged}) {
  return Container(
    height: 40,
    padding: const EdgeInsets.symmetric(horizontal: 12),
    alignment: Alignment.centerLeft,
    decoration: const BoxDecoration(),
    child: TextField(
      controller: c,
      style: const TextStyle(fontSize: 14, color: inkPrimary),
      cursorColor: accentBlue,
      onChanged: onChanged,
      decoration: InputDecoration(
        isDense: true,
        border: InputBorder.none,
        hintText: hint,
        hintStyle: const TextStyle(fontSize: 14, color: Color(0xFF8B97AC)),
      ),
    ),
  );
}

class _Chip extends StatelessWidget {
  final String text;
  final bool selected;
  final VoidCallback onTap;
  const _Chip(
      {required this.text, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: selected
              ? const Color(0xFF2E6BE6)
              : Colors.white.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(text,
            style: TextStyle(
                fontSize: 12,
                color: selected ? Colors.white : const Color(0xFFC3CDDE))),
      ),
    );
  }
}


/// 新建学期的整套数据（鸿蒙 `doCreateSemester` + `Seeder.cloneCourses`）：
/// 新学期的课程/时段/模板/节次时间可以整份从当前学期复制，id 全部换新。
BackupBundle _newSemesterBundle(
  BackupBundle b, {
  required String name,
  required DateTime start,
  required int weeks,
  required bool weekend,
  required bool copyFromCurrent,
}) {
  final id = b.semesters.fold<int>(0, (m, s) => s.id > m ? s.id : m) + 1;
  final sem = Semester(
    id: id,
    name: name,
    startDate: formatDate(start),
    totalWeeks: weeks,
    firstDayOfWeek: 1,
    showWeekend: weekend,
  );
  var sectionTimes = b.sectionTimes;
  var courses = b.courses;
  var rules = b.rules;
  var templates = b.templates;
  if (copyFromCurrent && b.semester != null) {
    final oldSem = b.semester!;
    final courseIdMap = <int, int>{};
    var nextCourseId =
        b.courses.fold<int>(0, (m, c) => c.id > m ? c.id : m) + 1;
    final newCourses = <Course>[];
    for (final c in b.courses.where((c) => c.semesterId == oldSem.id)) {
      final nid = nextCourseId++;
      courseIdMap[c.id] = nid;
      newCourses.add(Course(
        id: nid,
        semesterId: id,
        name: c.name,
        shortName: c.shortName,
        teacher: c.teacher,
        location: c.location,
        colorIndex: c.colorIndex,
        autoTodoEnabled: c.autoTodoEnabled,
        isVirtual: c.isVirtual,
        note: c.note,
      ));
    }
    courses = [...b.courses, ...newCourses];

    var nextRuleId = b.rules.fold<int>(0, (m, r) => r.id > m ? r.id : m) + 1;
    final newRules = <SessionRule>[];
    for (final r in b.rules) {
      final mapped = courseIdMap[r.courseId];
      if (mapped == null) continue;
      newRules.add(SessionRule(
        id: nextRuleId++,
        courseId: mapped,
        weekday: r.weekday,
        startSection: r.startSection,
        endSection: r.endSection,
        weeksMask: '1' * weeks,
        location: r.location,
        isQuiz: r.isQuiz,
      ));
    }
    rules = [...b.rules, ...newRules];

    var nextTemplateId =
        b.templates.fold<int>(0, (m, t) => t.id > m ? t.id : m) + 1;
    final newTemplates = <TodoTemplate>[];
    for (final t in b.templates) {
      final mapped = courseIdMap[t.courseId];
      if (mapped == null) continue;
      newTemplates.add(TodoTemplate(
        id: nextTemplateId++,
        courseId: mapped,
        sortOrder: t.sortOrder,
        enabled: t.enabled,
        titleTemplate: t.titleTemplate,
        ddlRule: t.ddlRule,
        ddlParam: t.ddlParam,
        estimateMin: t.estimateMin,
        category: t.category,
        submitChannel: t.submitChannel,
        note: t.note,
      ));
    }
    templates = [...b.templates, ...newTemplates];

    sectionTimes = [
      ...b.sectionTimes,
      for (final t in b.sectionTimes.where((t) => t.semesterId == oldSem.id))
        SectionTime(
          semesterId: id,
          section: t.section,
          startMin: t.startMin,
          endMin: t.endMin,
          flexible: t.flexible,
        ),
    ];
  }
  return _with(
    b,
    semesters: [...b.semesters, sem],
    sectionTimes: sectionTimes,
    courses: courses,
    rules: rules,
    templates: templates,
    lessons: b.lessons,
  );
}

// ---------------- 子页：学期设置（鸿蒙 SemesterView）----------------

class _SemesterSheet extends StatefulWidget {
  final BackupBundle b;
  final void Function(BackupBundle next) onChanged;
  const _SemesterSheet({required this.b, required this.onChanged});

  @override
  State<_SemesterSheet> createState() => _SemesterSheetState();
}

class _SemesterSheetState extends State<_SemesterSheet>
    with InlineToastMixin {
  late BackupBundle _b = widget.b;
  late final TextEditingController _name =
      TextEditingController(text: _b.semester?.name ?? '');
  late int _weeks = _b.semester?.totalWeeks ?? 16;

  void _apply(BackupBundle next) {
    setState(() => _b = next);
    widget.onChanged(next);
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _pickStart() async {
    final sem = _b.semester;
    if (sem == null) return;
    final d = await showDatePicker(
      context: context,
      initialDate: parseDate(sem.startDate),
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (d == null || !mounted) return;
    final list = _b.semesters
        .map((s) => s.id == sem.id
            ? Semester(
                id: s.id,
                name: s.name,
                startDate: formatDate(d),
                totalWeeks: s.totalWeeks,
                firstDayOfWeek: s.firstDayOfWeek,
                showWeekend: s.showWeekend)
            : s)
        .toList();
    _apply(_with(_b, semesters: list));
  }

  void _saveSemester() {
    final sem = _b.semester;
    if (sem == null) return;
    if (_name.text.trim().isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('学期名称不能为空')));
      return;
    }
    final list = _b.semesters
        .map((s) => s.id == sem.id
            ? Semester(
                id: s.id,
                name: _name.text.trim(),
                startDate: s.startDate,
                totalWeeks: _weeks,
                firstDayOfWeek: s.firstDayOfWeek,
                showWeekend: s.showWeekend)
            : s)
        .toList();
    _apply(_with(_b, semesters: list));
    showToast('学期设置已保存');
  }


  void _setCurrent(int index) {
    if (index <= 0 || index >= _b.semesters.length) return;
    final list = List.of(_b.semesters);
    final picked = list.removeAt(index);
    _apply(_with(_b, semesters: [picked, ...list]));
  }

  /// 「复制到当前学期」（鸿蒙 `Seeder.cloneCourses`）：只复制课程 / 时段 / 模板，
  /// 同名的跳过；课时（virtual_lesson）不复制（和鸿蒙一致）。
  void _copyFrom(int index) {
    final from = _b.semesters[index];
    final to = _b.semesters.first;
    if (from.id == to.id) return;
    final targetNames = {
      for (final c in _b.courses.where((c) => c.semesterId == to.id)) c.name
    };
    final courses = [..._b.courses];
    final rules = [..._b.rules];
    final templates = [..._b.templates];
    var added = 0;
    for (final c in _b.courses.where((c) => c.semesterId == from.id)) {
      if (targetNames.contains(c.name)) continue;
      final nid = _nextId<Course>(courses, (x) => x.id);
      courses.add(Course(
        id: nid,
        semesterId: to.id,
        name: c.name,
        shortName: c.shortName,
        teacher: c.teacher,
        location: c.location,
        colorIndex: c.colorIndex,
        autoTodoEnabled: c.autoTodoEnabled,
        isVirtual: c.isVirtual,
        note: c.note,
      ));
      for (final r in _b.rules.where((r) => r.courseId == c.id)) {
        rules.add(SessionRule(
          id: _nextId<SessionRule>(rules, (x) => x.id),
          courseId: nid,
          weekday: r.weekday,
          startSection: r.startSection,
          endSection: r.endSection,
          weeksMask: r.weeksMask,
          location: r.location,
          isQuiz: r.isQuiz,
        ));
      }
      var order = 0;
      for (final t in _b.templates.where((t) => t.courseId == c.id)) {
        templates.add(TodoTemplate(
          id: _nextId<TodoTemplate>(templates, (x) => x.id),
          courseId: nid,
          sortOrder: order++,
          enabled: t.enabled,
          titleTemplate: t.titleTemplate,
          ddlRule: t.ddlRule,
          ddlParam: t.ddlParam,
          estimateMin: t.estimateMin,
          category: t.category,
          submitChannel: t.submitChannel,
          note: t.note,
        ));
      }
      added++;
    }
    _apply(_with(_b,
        courses: courses, rules: rules, templates: templates));
    showToast(added == 0
        ? '没有可复制的课（可能已存在同名课程）'
        : '已复制 $added 门课到当前学期');
  }

  @override
  Widget build(BuildContext context) {
    final sem = _b.semester;
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.all(floatSide),
      child: Glass(
        sheet: true,
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: ConstrainedBox(
          constraints: BoxConstraints(
              maxHeight: MediaQuery.of(context).size.height * 0.82),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  GestureDetector(
                    onTap: () => Navigator.of(context).pop(),
                    behavior: HitTestBehavior.opaque,
                    child: const Text('‹ 返回',
                        style:
                            TextStyle(fontSize: 15, color: Color(0xFF7FA8FF))),
                  ),
                  const Spacer(),
                  const Text('学期设置',
                      style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w500,
                          color: inkPrimary)),
                  const Spacer(),
                  const SizedBox(width: 44),
                ],
              ),
              const SizedBox(height: 10),
              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      toastLine(),
                      const Text('学期名称',
                          style: TextStyle(
                              fontSize: 12, color: Color(0xFF94A0B5))),
                      const SizedBox(height: 4),
                      _sheetInput(_name, '2026 秋季学期'),
                      const SizedBox(height: 12),
                      const Text('第一教学周周一',
                          style: TextStyle(
                              fontSize: 12, color: Color(0xFF94A0B5))),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                                sem == null || sem.startDate.isEmpty
                                    ? '未选择'
                                    : sem.startDate,
                                style: const TextStyle(
                                    fontSize: 15, color: Color(0xFFF2F5FA))),
                          ),
                          _PillAction(text: '选择日期…', onTap: _pickStart),
                        ],
                      ),
                      const Padding(
                        padding: EdgeInsets.only(top: 4),
                        child: Text('北大 2026 秋季：9/7 开学，16 个教学周（到 12/27）',
                            style: TextStyle(
                                fontSize: 11, color: Color(0xFF8B97AC))),
                      ),
                      const SizedBox(height: 12),
                      const Text('教学周数',
                          style: TextStyle(
                              fontSize: 12, color: Color(0xFF94A0B5))),
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        children: [
                          for (final n in const [14, 15, 16, 17, 18, 20])
                            _MiniChip(
                              text: '$n 周',
                              selected: _weeks == n,
                              onTap: () => setState(() => _weeks = n),
                            ),
                        ],
                      ),
                      const SizedBox(height: 20),
                      _sheetButton('保存学期设置', _saveSemester),
                      const SizedBox(height: 10),
                      // 所有学期：当前 = 第一个
                      Row(
                        children: [
                          const Expanded(
                            child: Text('所有学期',
                                style: TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w500,
                                    color: inkPrimary)),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      // 所有学期：一行一张小卡（当前 = 第一个）
                      for (var i = 0; i < _b.semesters.length; i++)
                        GestureDetector(
                          onTap: i == 0 ? null : () => _setCurrent(i),
                          behavior: HitTestBehavior.opaque,
                          child: Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(10),
                            margin: const EdgeInsets.only(bottom: 6),
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.06),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: glassEdgeSoft),
                            ),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(_b.semesters[i].name,
                                          style: const TextStyle(
                                              fontSize: 14,
                                              color: Color(0xFFF2F5FA))),
                                      Padding(
                                        padding:
                                            const EdgeInsets.only(top: 2),
                                        child: Text(
                                            '${_b.semesters[i].startDate} 起 · '
                                            '${_b.semesters[i].totalWeeks} 周',
                                            style: const TextStyle(
                                                fontSize: 11,
                                                color: Color(0xFF94A0B5))),
                                      ),
                                    ],
                                  ),
                                ),
                                if (i == 0)
                                  const Text('当前',
                                      style: TextStyle(
                                          fontSize: 11, color: accentBlue))
                                else
                                  GestureDetector(
                                    onTap: () => _copyFrom(i),
                                    behavior: HitTestBehavior.opaque,
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 8, vertical: 4),
                                      decoration: BoxDecoration(
                                        color: const Color(0x382E6BE6),
                                        borderRadius: BorderRadius.circular(8),
                                      ),
                                      child: const Text('复制到当前学期',
                                          style: TextStyle(
                                              fontSize: 12,
                                              color: accentBlue)),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      // 新建学期（鸿蒙：同页底部的内联表单）
                      const Padding(
                        padding: EdgeInsets.only(top: 24),
                        child: Text('新建学期（下学期开学时用）',
                            style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w500,
                                color: inkPrimary)),
                      ),
                      _NewSemesterForm(
                        b: _b,
                        onCreated: (next) {
                          _apply(next);
                          showToast(
                              '已新建「${next.semester?.name ?? ''}」并切换');
                        },
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 新建学期表单（鸿蒙 SemesterView 底部那段内联表单）
class _NewSemesterForm extends StatefulWidget {
  final BackupBundle b;
  final void Function(BackupBundle next) onCreated;
  const _NewSemesterForm({required this.b, required this.onCreated});

  @override
  State<_NewSemesterForm> createState() => _NewSemesterFormState();
}

class _NewSemesterFormState extends State<_NewSemesterForm> {
  late final TextEditingController _name =
      TextEditingController(text: _defaultName());
  late DateTime _start = _defaultStart();
  int _weeks = 16;
  bool _copy = true;

  static String _defaultName() {
    final y = DateTime.now().year;
    final m = DateTime.now().month;
    return m >= 8 ? '$y 秋季学期' : '$y 春季学期';
  }

  static DateTime _defaultStart() {
    final d = DateTime.now().add(const Duration(days: 7));
    return DateTime(d.year, d.month, d.day);
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _pickStart() async {
    final d = await showDatePicker(
      context: context,
      initialDate: _start,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (d == null || !mounted) return;
    setState(() => _start = d);
  }

  void _create() {
    final name = _name.text.trim().isEmpty ? '新学期' : _name.text.trim();
    final next = _newSemesterBundle(
      widget.b,
      name: name,
      start: _start,
      weeks: _weeks,
      weekend: true,
      copyFromCurrent: _copy,
    );
    // 「新建并切换到这个学期」：把新学期的排到最前（= 当前学期）
    final created = next.semesters.last;
    widget.onCreated(_with(next,
        semesters: [created, ...next.semesters.where((s) => s.id != created.id)]));
    setState(() {
      _name.text = _defaultName();
      _start = _defaultStart();
      _weeks = 16;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('名称',
            style: TextStyle(fontSize: 12, color: Color(0xFF94A0B5))),
        const SizedBox(height: 4),
        _sheetInput(_name, '2027 春季学期'),
        const Padding(
          padding: EdgeInsets.only(top: 12),
          child: Text('第一教学周周一',
              style: TextStyle(fontSize: 12, color: Color(0xFF94A0B5))),
        ),
        const SizedBox(height: 4),
        Row(
          children: [
            Expanded(
              child: Text(formatDate(_start),
                  style: const TextStyle(
                      fontSize: 15, color: Color(0xFFF2F5FA))),
            ),
            _PillAction(text: '选择日期…', onTap: _pickStart),
          ],
        ),
        const Padding(
          padding: EdgeInsets.only(top: 12),
          child: Text('教学周数',
              style: TextStyle(fontSize: 12, color: Color(0xFF94A0B5))),
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            for (final n in const [14, 15, 16, 17, 18, 20])
              _MiniChip(
                text: '$n 周',
                selected: _weeks == n,
                onTap: () => setState(() => _weeks = n),
              ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.only(top: 10),
          child: Row(
            children: [
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('顺便复制当前学期的课表',
                        style: TextStyle(fontSize: 14, color: inkPrimary)),
                    Padding(
                      padding: EdgeInsets.only(top: 2),
                      child: Text('新学期的课大多和上学期一样，复制后改改就行',
                          style: TextStyle(
                              fontSize: 11, color: Color(0xFF94A0B5))),
                    ),
                  ],
                ),
              ),
              Switch(
                value: _copy,
                activeThumbColor: const Color(0xFF2E6BE6),
                onChanged: (v) => setState(() => _copy = v),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(top: 16),
          child: _sheetButton('新建并切换到这个学期', _create),
        ),
      ],
    );
  }
}

// ---------------- 子页：备份与恢复（鸿蒙 BackupView）----------------

class _BackupSheet extends StatefulWidget {
  final BackupBundle b;
  final void Function(BackupBundle next) onChanged;
  final Future<void> Function()? onImport;
  const _BackupSheet(
      {required this.b, required this.onChanged, this.onImport});

  @override
  State<_BackupSheet> createState() => _BackupSheetState();
}

class _BackupSheetState extends State<_BackupSheet>
    with InlineToastMixin {
  late final BackupBundle _b = widget.b;
  String? _exportPath;

  Future<void> _export() async {
    try {
      final path = await writeBackupFile(backupToJson(_b));
      if (!mounted) return;
      setState(() => _exportPath = path);
      showToast('已导出到 App 文档目录');
    } catch (e) {
      if (!mounted) return;
      showToast('导出失败：$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.all(floatSide),
      child: Glass(
        sheet: true,
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: ConstrainedBox(
          constraints: BoxConstraints(
              maxHeight: MediaQuery.of(context).size.height * 0.82),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  GestureDetector(
                    onTap: () => Navigator.of(context).pop(),
                    behavior: HitTestBehavior.opaque,
                    child: const Text('‹ 返回',
                        style:
                            TextStyle(fontSize: 15, color: Color(0xFF7FA8FF))),
                  ),
                  const Spacer(),
                  const Text('备份与恢复',
                      style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w500,
                          color: inkPrimary)),
                  const Spacer(),
                  const SizedBox(width: 44),
                ],
              ),
              const SizedBox(height: 10),
              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      toastLine(),
                      const Text(
                          '数据只在这台手机里。导出会把全部内容写成一个 JSON 文件放在应用文档目录，'
                          '恢复则用它整份覆盖当前数据。',
                          style: TextStyle(
                              fontSize: 11, color: Color(0xFF94A0B5))),
                      const SizedBox(height: 12),
                      _sheetButton('导出备份到文件', _export),
                      if (_exportPath != null) ...[
                        const SizedBox(height: 10),
                        const Text('备份文件路径',
                            style: TextStyle(
                                fontSize: 12, color: Color(0xFF94A0B5))),
                        const SizedBox(height: 4),
                        SelectableText(_exportPath!,
                            style: const TextStyle(
                                fontSize: 11, color: Color(0xFFC3CDDE))),
                        const SizedBox(height: 6),
                        _PillAction(
                          text: '复制路径',
                          onTap: () async {
                            await Clipboard.setData(
                                ClipboardData(text: _exportPath!));
                            if (mounted) showToast('路径已复制');
                          },
                        ),
                        // 鸿蒙那边给的是 `./hdc.sh file recv …`；安卓的等价命令是 adb pull
                        const Padding(
                          padding: EdgeInsets.only(top: 10, bottom: 4),
                          child: Text('想把它存到电脑上（或发给我排查问题），在这个项目目录里跑：',
                              style: TextStyle(
                                  fontSize: 11, color: Color(0xFF94A0B5))),
                        ),
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.10),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: SelectableText(
                              "adb pull '${_exportPath!}' ./",
                              style: const TextStyle(
                                  fontSize: 10, color: Color(0xFFCBD6E8))),
                        ),
                      ],
                      const SizedBox(height: 16),
                      if (widget.onImport != null)
                        _sheetButton('从备份文件导入…', () async {
                          final nav = Navigator.of(context);
                          await widget.onImport!();
                          if (mounted) nav.pop();
                        }, secondary: true, key: const ValueKey('manager-import')),
                      const SizedBox(height: 22),
                      Row(
                        children: [
                          const Text('诊断信息',
                              style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w500,
                                  color: inkPrimary)),
                          const Spacer(),
                          _PillAction(
                              text: '刷新', onTap: () => setState(() {})),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Text(backupSummary(_b),
                          style: const TextStyle(
                              fontSize: 11,
                              height: 1.5,
                              color: Color(0xFF8B97AC))),
                      const SizedBox(height: 12),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 胶囊输入框（鸿蒙裸 TextInput）
Widget _sheetInput(TextEditingController c, String hint) {
  return Container(
    height: 40,
    padding: const EdgeInsets.symmetric(horizontal: 12),
    alignment: Alignment.centerLeft,
    decoration: const BoxDecoration(),
    child: TextField(
      controller: c,
      style: const TextStyle(fontSize: 14, color: inkPrimary),
      cursorColor: accentBlue,
      decoration: InputDecoration(
        isDense: true,
        border: InputBorder.none,
        hintText: hint,
        hintStyle: const TextStyle(fontSize: 14, color: Color(0xFF8B97AC)),
      ),
    ),
  );
}

/// 子页里的整宽蓝按钮
Widget _sheetButton(String text, VoidCallback onTap,
    {bool secondary = false, Key? key}) {
  return GestureDetector(
    key: key,
    onTap: onTap,
    behavior: HitTestBehavior.opaque,
    child: Container(
      height: 40,
      width: double.infinity,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: secondary
            ? Colors.white.withValues(alpha: 0.14)
            : const Color(0xFF2E6BE6),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(text,
          style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w500,
              color: secondary ? const Color(0xFFC3CDDE) : Colors.white)),
    ),
  );
}

class _MiniChip extends StatelessWidget {
  final String text;
  final bool selected;
  final VoidCallback onTap;
  const _MiniChip(
      {required this.text, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: selected
              ? const Color(0xFF2E6BE6)
              : Colors.white.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(text,
            style: TextStyle(
                fontSize: 12,
                color: selected ? Colors.white : const Color(0xFFC3CDDE))),
      ),
    );
  }
}
