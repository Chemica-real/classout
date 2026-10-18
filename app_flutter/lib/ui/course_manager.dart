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
import 'dart:convert' show utf8;
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import '../data/backup.dart';
import '../data/backup_export.dart';
import '../domain/dates.dart';
import '../domain/todo_generator.dart' show renderTitle;
import '../domain/validate.dart';
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
  Future<BackupBundle?> Function()? onImport,
  /// 启动报告（鸿蒙 kv `last_run_report`）与黑名单条数 —— 备份页诊断块用
  String report = '',
  int? blacklistCount,
}) {
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: '关闭课程管理',
    // 薄纱自己画（鸿蒙 `showManager` 是**全屏 backdropBlur + SCRIM_COLOR**，
    // 不是纯色遮罩）：这样底下的课表会变成"磨砂玻璃后面的柔和色块"。
    barrierColor: Colors.transparent,
    transitionDuration: dur(durDrawer),
    pageBuilder: (ctx, _, __) => BackdropFilter(
      filter: ImageFilter.blur(sigmaX: glassBlur, sigmaY: glassBlur),
      child: ColoredBox(
        color: const Color(0x6B080A14), // rgba(8,10,20,0.42) = 鸿蒙 SCRIM_COLOR
        child: _Manager(
            bundle: bundle,
            onChanged: onChanged,
            onImport: onImport,
            report: report,
            blacklistCount: blacklistCount),
      ),
    ),
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
  final Future<BackupBundle?> Function()? onImport;

  /// 启动报告 + 黑名单条数（备份页诊断块）
  final String report;
  final int? blacklistCount;
  const _Manager(
      {required this.bundle,
      required this.onChanged,
      this.onImport,
      this.report = '',
      this.blacklistCount});

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


  /// 「课程与学期」这一页现在和鸿蒙 `CourseManager` 一样是**整页换内容**：
  /// 列表 / 学期设置 / 上课节次时间 / 备份与恢复 都画在同一个全屏页里，
  /// 顶部是一条独立的玻璃 TopBar（左边「关闭」或「‹ 返回」），下面整块是内容 ——
  /// 以前是"外层一张大玻璃卡 + 子页再叠一个弹窗"，真机截图一比就不一样。
  String _mode = 'list';

  /// 正在编辑的课程（null = 新增）
  Course? _editing;

  static const Map<String, String> _modeTitles = {
    'semester': '学期设置',
    'sections': '上课节次时间',
    'backup': '备份与恢复',
  };

  @override
  Widget build(BuildContext context) {
    return Material(
      type: MaterialType.transparency,
      child: SafeArea(
        child: Column(
          children: [
            _topBar(),
            Expanded(child: _body()),
          ],
        ),
      ),
    );
  }

  /// 顶栏（鸿蒙 `TopBar`）：全宽玻璃条（模糊 + 面板底色 + 1px 强描边，**没有圆角**），
  /// 左「关闭」/「‹ 返回」15 号蓝字，中间标题 16 Medium，右侧留同样宽度占位。
  Widget _topBar() {
    final isList = _mode == 'list';
    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: glassBlur, sigmaY: glassBlur),
        child: Container(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          decoration: BoxDecoration(
            color: glassTintPanel,
            border: Border.all(color: glassEdgeStrong),
          ),
          child: Row(
            children: [
              GestureDetector(
                onTap: isList
                    ? () => Navigator.of(context).pop()
                    : () => setState(() => _mode = 'list'),
                behavior: HitTestBehavior.opaque,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Text(isList ? '关闭' : '‹ 返回',
                      style:
                          const TextStyle(fontSize: 15, color: accentBlue)),
                ),
              ),
              const Spacer(),
              Text(isList
                      ? '课程与学期'
                      : (_mode == 'course'
                          ? (_editing == null ? '新增课程' : '编辑课程')
                          : (_modeTitles[_mode] ?? '课程与学期')),
                  style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w500,
                      color: inkPrimary)),
              const Spacer(),
              // 鸿蒙 TopBar 右侧塞的是四个空格（占位，保证标题居中）
              const Text('    ', style: TextStyle(fontSize: 15)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _body() {
    switch (_mode) {
      case 'course':
        return _CourseEditor(
          key: ValueKey('course-edit-${_editing?.id ?? 0}'),
          b: _b,
          existing: _editing,
          onClose: () => setState(() {
            _mode = 'list';
            _editing = null;
          }),
          onDone: (res) {
            _apply(res.bundle);
            _showToast(res.deleted ? '课程已删除' : '已保存');
            setState(() {
              _mode = 'list';
              _editing = null;
            });
          },
        );
      case 'sections':
        final sem = _b.semester;
        if (sem == null) return _listBody();
        return SectionsEditorBody(
          semesterId: sem.id,
          sections:
              _b.sectionTimes.where((s) => s.semesterId == sem.id).toList(),
          onClose: () => setState(() => _mode = 'list'),
          onDone: (next) {
            final semId = sem.id;
            _apply(_with(_b, sectionTimes: [
              ..._b.sectionTimes.where((s) => s.semesterId != semId),
              ...next,
            ]));
            _showToast('节次时间已保存');
            setState(() => _mode = 'list');
          },
        );
      case 'semester':
        return _SemesterSheet(b: _b, onChanged: _apply);
      case 'backup':
        return _BackupSheet(
          b: _b,
          onChanged: _apply,
          onImport: widget.onImport,
          report: widget.report,
          blacklistCount: widget.blacklistCount,
        );
      default:
        return _listBody();
    }
  }

  Widget _listBody() {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_toast.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(_toast,
                  style: const TextStyle(fontSize: 12, color: accentBlue)),
            ),
          // 鸿蒙列表首屏是**三张入口卡**：学期 / 上课节次时间 / 备份与恢复
          _entryRow(
            '学期',
            _b.semester == null
                ? ''
                : '${_b.semester!.name} · ${_b.semester!.startDate} 起 · '
                    '${_b.semester!.totalWeeks} 周',
            key: const ValueKey('entry-semester'),
            onTap: () => setState(() => _mode = 'semester'),
          ),
          _entryRow(
            key: const ValueKey('entry-sections'),
            '上课节次时间',
            '${_b.sectionTimes.length} 节 · 可随意改',
            onTap: _openSections,
          ),
          _entryRow('备份与恢复', '导出 JSON / 整份恢复 / 诊断',
              key: const ValueKey('entry-backup'),
              onTap: () => setState(() => _mode = 'backup')),
          const SizedBox(height: 8),
          Row(
            children: [
              Text('课程（${_b.courses.length}）',
                  style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w500,
                      color: inkPrimary)),
              const Spacer(),
              // 鸿蒙就是一行 13 号蓝字（没有胶囊底）
              _LinkAction(text: '+ 新增课程', onTap: () => _openCourse(null)),
            ],
          ),
          const SizedBox(height: 8),
          if (_b.courses.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Text('还没有课程。点右上角「新增课程」开始建立自己的课表；'
                  '也可以用「备份与恢复」导入之前导出的备份。',
                  style: TextStyle(fontSize: 12, color: Color(0xFF8B97AC))),
            ),
          // 鸿蒙 `listCourses ... ORDER BY id`
          for (final c in ([..._b.courses]..sort((a, b) => a.id - b.id)))
            _courseCard(c),
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
                            fontSize: 11, color: Color(0xFFFF8A8A))),
                  ),
                  GestureDetector(
                    onTap: () => setState(() => _confirmClear = false),
                    behavior: HitTestBehavior.opaque,
                    child: const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 8),
                      child: Text('取消',
                          style: TextStyle(
                              fontSize: 12, color: Color(0xFFA9B5C9))),
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
                          style:
                              TextStyle(fontSize: 12, color: Colors.white)),
                    ),
                  ),
                ],
              )
            else
              GestureDetector(
                onTap: () => setState(() => _confirmClear = true),
                behavior: HitTestBehavior.opaque,
                child: const Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: Text('清空本学期课程',
                      style: TextStyle(
                          fontSize: 12, color: Color(0xFF8B97AC))),
                ),
              ),
          ],
        ],
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
          boxShadow: glassShadowRow, // 鸿蒙入口卡是 .glassCard()（带阴影）
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

  void _openSections() {
    if (_b.semester == null) return;
    setState(() => _mode = 'sections');
  }

  /// 课程卡（鸿蒙 `lc-` 那张）：彩色简称胶囊 + 全名，下面逐条列时段与模板
  Widget _courseCard(Course c) {
    final rules = _b.rules.where((r) => r.courseId == c.id).toList()
      ..sort((a, b) => a.weekday == b.weekday
          ? a.startSection - b.startSection
          : a.weekday - b.weekday);
    // 鸿蒙 `listTemplatesByCourse`：ORDER BY sort_order, id
    final templates = _b.templates.where((t) => t.courseId == c.id).toList()
      ..sort((a, b) => a.sortOrder == b.sortOrder
          ? a.id - b.id
          : a.sortOrder - b.sortOrder);
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
            boxShadow: glassShadowRow, // 鸿蒙课程卡也是 .glassCard()
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



  void _openCourse(Course? existing) {
    setState(() {
      _editing = existing;
      _mode = 'course';
    });
  }
}

/// 鸿蒙里那些"就是一行蓝字"的动作（`+ 新增课程` 13 号、`刷新` 12 号）：
/// 没有底色、没有胶囊 —— 以前安卓套了一层蓝底胶囊，双机对比一眼能看出多了一块。
class _LinkAction extends StatelessWidget {
  final String text;
  final VoidCallback onTap;
  final double fontSize;
  const _LinkAction(
      {required this.text, required this.onTap, this.fontSize = 13});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
        child: Text(text,
            style: TextStyle(fontSize: fontSize, color: const Color(0xFF7FA8FF))),
      ),
    );
  }
}

/// 「选择日期…」：鸿蒙是 `Button` + 白 0.14 底 + 13 号蓝字（40 高、胶囊）
class _GhostButton extends StatelessWidget {
  final String text;
  final VoidCallback onTap;
  const _GhostButton({required this.text, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        height: 40,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(text,
            style: const TextStyle(fontSize: 13, color: Color(0xFF7FA8FF))),
      ),
    );
  }
}

// ---------------- 课程编辑（右侧抽屉）----------------

class _CourseEditor extends StatefulWidget {
  final BackupBundle b;
  final Course? existing;

  /// 「‹ 返回」= 放弃这一页的改动（鸿蒙 tops back 也是直接回列表）
  final VoidCallback onClose;

  /// 保存 / 删除完成（外壳负责写回 + 提示 + 回列表）
  final void Function(_CourseEditResult res) onDone;
  const _CourseEditor(
      {super.key,
      required this.b,
      this.existing,
      required this.onClose,
      required this.onDone});

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
      _b.templates.where((t) => t.courseId == _id).toList()
        ..sort((a, b) => a.sortOrder == b.sortOrder
            ? a.id - b.id
            : a.sortOrder - b.sortOrder);
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
    widget.onDone(_CourseEditResult(
        _with(_b, courses: courses, lessons: lessons, blocks: blocks)));
  }

  void _delete() {
    final rules = _b.rules.where((r) => r.courseId != _id).toList();
    final templates = _b.templates.where((t) => t.courseId != _id).toList();
    final lessons = _b.lessons.where((l) => l.courseId != _id).toList();
    final courses = _b.courses.where((c) => c.id != _id).toList();
    widget.onDone(_CourseEditResult(
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

  /// 鸿蒙 `CourseView` 是整页子页（顶栏由外壳画，标题「新增课程 / 编辑课程」）
  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
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
                            // 鸿蒙：30×30、选中 3px #F2F5FA 环 / 未选中 1px 白 0.12
                            child: Container(
                              width: 30,
                              height: 30,
                              decoration: BoxDecoration(
                                color: courseColors[i],
                                shape: BoxShape.circle,
                                border: Border.all(
                                    width: _color == i ? 3 : 1,
                                    color: _color == i
                                        ? const Color(0xFFF2F5FA)
                                        : Colors.white
                                            .withValues(alpha: 0.12)),
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
            const SizedBox(height: 8),
            const SizedBox(height: 20),
            // 鸿蒙课程编辑页底部：保存课程（等宽蓝）+ 删除课程（红、按内容宽）
            Row(
              children: [
                Expanded(
                  child: _sheetButton('保存课程', _save,
                      key: const ValueKey('course-save')),
                ),
                if (_id > 0) ...[
                  const SizedBox(width: 10),
                  _sheetButton('删除课程',
                      () => setState(() => _confirmDelete = true),
                      dangerTint: true,
                      fill: false),
                ],
              ],
            ),
            // 鸿蒙 `DeleteConfirmRow`：说明 + 取消 + 删除（红底小胶囊），不是"再点一次同一个按钮"
            if (_confirmDelete && _id > 0)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                          '确定删除「${_short.text.isNotEmpty ? _short.text : _name.text}」'
                          '及其所有时段、模板？',
                          style: const TextStyle(
                              fontSize: 11, color: Color(0xFFFF8A8A))),
                    ),
                    GestureDetector(
                      onTap: () => setState(() => _confirmDelete = false),
                      behavior: HitTestBehavior.opaque,
                      child: const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 10),
                        child: Text('取消',
                            style: TextStyle(
                                fontSize: 12, color: Color(0xFFA9B5C9))),
                      ),
                    ),
                    GestureDetector(
                      key: const ValueKey('course-delete-confirm'),
                      onTap: _delete,
                      behavior: HitTestBehavior.opaque,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                          color: const Color(0xFFD64545),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: const Text('删除',
                            style: TextStyle(
                                fontSize: 12, color: Colors.white)),
                      ),
                    ),
                  ],
                ),
              ),
        ],
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
      // 鸿蒙：`.padding(10).glassCard().borderRadius(8)` + 整行 margin bottom 6
      padding: const EdgeInsets.only(bottom: 6),
      child: Container(
        padding: const EdgeInsets.fromLTRB(10, 6, 6, 6),
        decoration: BoxDecoration(
          color: glassTintRow,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: glassEdgeSoft),
          boxShadow: glassShadowRow,
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

  /// 输入不合法时的红字（鸿蒙是把 verdict.message 放到页面 toast；弹窗里就地显示更直观）
  String _error = '';

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
    // 鸿蒙 `doSaveRule`：先过 validateSessionRule（节次存在 / 起止 / 周次非空 / 时间落在一天内）
    final verdict = validateSessionRule(rule, b.sectionTimes);
    if (!verdict.ok) {
      setState(() => _error = verdict.message);
      return;
    }
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
      // 鸿蒙 RuleDialog / TemplateDialog：整屏 `.padding(16)` 居中
      insetPadding: const EdgeInsets.all(16),
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
              // 鸿蒙：这一行 `margin({ top: 14 })`，文案「这是习题课」14 号
              const SizedBox(height: 14),
              Row(
                children: [
                  const Expanded(
                    child: Text('这是习题课',
                        style: TextStyle(fontSize: 14, color: inkPrimary)),
                  ),
                  Switch(
                      value: _quiz,
                      activeThumbColor: const Color(0xFF2E6BE6),
                      onChanged: (v) => setState(() => _quiz = v)),
                ],
              ),
              if (_error.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(_error,
                      style: const TextStyle(
                          fontSize: 11, color: Color(0xFFFF8080))),
                ),
              const SizedBox(height: 10),
              // 鸿蒙规则弹窗：取消 / 保存 都是**默认 Button**（40 高、16 号、等宽）
              Row(
                children: [
                  Expanded(
                    child: _sheetButton('取消',
                        () => Navigator.of(context).pop(),
                        secondary: true),
                  ),
                  const SizedBox(width: 10),
                  Expanded(child: _sheetButton('保存', _save)),
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
    // 鸿蒙 `doSaveTemplate`：validateTemplateTitle（空 / 超长 / 未知 %变量）+ validateTemplateDdl
    final titleCheck = validateTemplateTitle(_title.text);
    if (!titleCheck.ok) {
      setState(() => _error = titleCheck.message);
      return;
    }
    final ddlCheck = validateTemplateDdl(_rule, _param.text.trim());
    if (!ddlCheck.ok) {
      setState(() => _error = ddlCheck.message);
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
      // 鸿蒙 RuleDialog / TemplateDialog：整屏 `.padding(16)` 居中
      insetPadding: const EdgeInsets.all(16),
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
              // 鸿蒙模板弹窗：同样是两颗默认 Button（保存带 key 供测试用）
              Row(
                children: [
                  Expanded(
                    child: _sheetButton('取消',
                        () => Navigator.of(context).pop(),
                        secondary: true),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _sheetButton('保存', _save,
                        key: const ValueKey('template-save')),
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

  /// 鸿蒙 `SemesterView` 是**整页场景**（顶栏由外壳画，这里只有内容）；
  /// 不是弹窗，所以这里不再自带标题与玻璃卡。
  @override
  Widget build(BuildContext context) {
    final sem = _b.semester;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
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
                          _GhostButton(text: '选择日期…', onTap: _pickStart),
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
                      // 所有学期：一行一张小卡（当前 = 第一个）。
                      // ⚠️ 鸿蒙这张卡**不能点**：切换当前学期只发生在"新建并切换"时；
                      //    非当前学期的动作是「复制到当前学期」。安卓原来整卡可点=静默换学期，
                      //    用户点一下想看详情，结果整个列表（和课表）都换了。
                      for (var i = 0; i < _b.semesters.length; i++)
                        Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(10),
                            margin: const EdgeInsets.only(bottom: 6),
                            // 鸿蒙：`.padding(10).glassCard().borderRadius(8)` ——
                            // 底色是 GLASS_TINT_ROW(白 0.10)、带阴影，圆角 8
                            decoration: BoxDecoration(
                              color: glassTintRow,
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: glassEdgeSoft),
                              boxShadow: glassShadowRow,
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
              showToast('已新建「${next.semester?.name ?? ''}」并切换');
            },
          ),
        ],
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
            _GhostButton(text: '选择日期…', onTap: _pickStart),
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
//
// 与鸿蒙 `CourseManager.BackupView` 逐块对齐：
//   说明文字 → 导出按钮 → 备份文件路径（常显）→ 拉到电脑的命令 →
//   「从备份恢复」（点一下变「取消 | 确认恢复」两栏）→ 诊断信息（按表计数）。
// 备份文件是**固定一个** `classout-backup.json`（鸿蒙 `BACKUP_FILE` 同名），
// 所以路径可以一直显示，恢复也直接读它、不弹选文件框。
// 安卓额外保留「长按从备份恢复」= 粘贴/选文件导入（跨端搬数据用，鸿蒙没有），
// 这样既不破坏 1:1，又不丢安卓原本的能力。

class _BackupSheet extends StatefulWidget {
  final BackupBundle b;
  final void Function(BackupBundle next) onChanged;
  final Future<BackupBundle?> Function()? onImport;
  final String report;
  final int? blacklistCount;
  const _BackupSheet(
      {required this.b,
      required this.onChanged,
      this.onImport,
      this.report = '',
      this.blacklistCount});

  @override
  State<_BackupSheet> createState() => _BackupSheetState();
}

class _BackupSheetState extends State<_BackupSheet> {
  /// 鸿蒙 `backupPath`：**一直**显示在页上（不是导出后才出现）
  String _path = '';

  /// 鸿蒙 `backupNote`：页内蓝框（导出成功 / 恢复成功 / 失败都写这里）
  String _note = '';

  /// 鸿蒙 `confirmRestore`：点「从备份恢复」先变成「取消 | 确认恢复」
  bool _confirmRestore = false;

  /// 刚从文件恢复进来的那份：诊断信息要显示**恢复后**的条数
  BackupBundle? _restored;

  BackupBundle get _shown => _restored ?? widget.b;

  /// 安卓专属：长按 = 粘贴 / 选文件导入（鸿蒙没有这条路，保持默认界面对齐）
  Future<void> _importFromAnywhere() async {
    final got = await widget.onImport?.call();
    if (!mounted || got == null) return;
    setState(() {
      _restored = got;
      _note = '已从备份恢复：\n${backupSummary(got)}';
    });
  }

  @override
  void initState() {
    super.initState();
    backupFilePath().then((p) {
      if (mounted) setState(() => _path = p);
    }).catchError((Object _) {});
  }

  /// 鸿蒙 `runExport`：写固定文件 → 蓝框显示「已写入 N 字节」+ 摘要
  Future<void> _export() async {
    try {
      final json = backupToJson(_shown);
      final path = await writeBackupFile(json);
      if (!mounted) return;
      setState(() {
        _path = path;
        _note = '已写入 ${utf8.encode(json).length} 字节\n${backupSummary(_shown)}';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _note = '导出失败：$e');
    }
  }

  /// 鸿蒙 `runRestore`：读固定文件 → 解析 → 整份覆盖；失败原因写进蓝框
  Future<void> _restore() async {
    final text = await readBackupText();
    if (!mounted) return;
    if (text.isEmpty) {
      setState(() {
        _note = '还没有备份文件，先点上面的「导出备份」';
        _confirmRestore = false;
      });
      return;
    }
    final BackupBundle bundle;
    try {
      bundle = BackupBundle.decode(text);
    } catch (_) {
      setState(() {
        _note = '备份文件读不懂（不是本 App 的备份，或格式太新）。已放弃恢复，数据没动。';
        _confirmRestore = false;
      });
      return;
    }
    setState(() {
      _confirmRestore = false;
      _restored = bundle;
      _note = '已从备份恢复：\n${backupSummary(bundle)}';
    });
    widget.onChanged(bundle);
  }

  /// 鸿蒙 `BackupView` 同样是整页场景（顶栏由外壳画）
  @override
  Widget build(BuildContext context) {
    final path = _path.isEmpty ? '（读取中…）' : _path;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 30),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
              '数据只在这台手机里。导出会把全部内容写成一个 JSON 文件放在应用沙箱，'
              '恢复则用它整份覆盖当前数据。',
              style: TextStyle(fontSize: 11, color: Color(0xFF94A0B5))),
          if (_note.isNotEmpty) ...[
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: const Color(0x382E6BE6),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(_note,
                  style: const TextStyle(
                      fontSize: 12, height: 1.5, color: Color(0xFF7FA8FF))),
            ),
          ],
          const SizedBox(height: 12),
          _sheetButton('导出备份到文件', _export),
          const SizedBox(height: 14),
          const Text('备份文件路径',
              style: TextStyle(fontSize: 12, color: Color(0xFF94A0B5))),
          const SizedBox(height: 4),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(6),
            ),
            child: SelectableText(path,
                style: const TextStyle(
                    fontSize: 11, color: Color(0xFFC3CDDE))),
          ),
          const Padding(
            padding: EdgeInsets.only(top: 10, bottom: 4),
            child: Text('想把它存到电脑上（或发给我排查问题），在这个项目目录里跑：',
                style: TextStyle(fontSize: 11, color: Color(0xFF94A0B5))),
          ),
          // 鸿蒙那行是 `./hdc.sh file recv …`；安卓的等价命令是 adb pull
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(6),
            ),
            child: SelectableText("adb pull '$path' ./",
                style:
                    const TextStyle(fontSize: 10, color: Color(0xFFCBD6E8))),
          ),
          const SizedBox(height: 16),
          if (_confirmRestore) ...[
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: const Color(0x2ED64545), // rgba(214,69,69,0.18)
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Text('确定用备份覆盖当前数据？当前内容会被整份替换，且不可撤销。',
                  style: TextStyle(
                      fontSize: 12, height: 1.5, color: Color(0xFFFF8A8A))),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: _sheetButton('取消',
                      () => setState(() => _confirmRestore = false),
                      secondary: true),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child:
                      _sheetButton('确认恢复', _restore, danger: true),
                ),
              ],
            ),
          ] else
            _sheetButton(
              '从备份恢复',
              () => setState(() => _confirmRestore = true),
              amber: true,
              onLongPress: _importFromAnywhere,
              key: const ValueKey('manager-import'),
            ),
          const SizedBox(height: 22),
          Row(
            children: [
              const Text('诊断信息',
                  style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                      color: inkPrimary)),
              const Spacer(),
              _LinkAction(text: '刷新', fontSize: 12, onTap: () => setState(() {})),
            ],
          ),
          const SizedBox(height: 6),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: glassTintRow,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: glassEdgeSoft),
              boxShadow: glassShadowRow,
            ),
            child: Text(
                diagnosticsText(_shown,
                    blacklistCount: widget.blacklistCount,
                    report: widget.report),
                style: const TextStyle(
                    fontSize: 11, height: 1.5, color: Color(0xFFC3CDDE))),
          ),
        ],
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

/// 子页里的整宽蓝按钮（鸿蒙默认 Button：40 高、胶囊圆角、fontSize 16）
Widget _sheetButton(String text, VoidCallback onTap,
    {bool secondary = false,
    bool amber = false,
    bool danger = false,
    bool dangerTint = false,
    VoidCallback? onLongPress,
    bool fill = true,
    Key? key}) {
  final Color bg = danger
      ? const Color(0xFFD64545) // 鸿蒙「确认恢复」
      : (dangerTint
          ? const Color(0x2ED64545) // rgba(214,69,69,0.18)，鸿蒙「删除课程」
          : (amber
              ? const Color(0x33B26B00) // rgba(178,107,0,0.20)，鸿蒙「从备份恢复」
              : (secondary
                  ? Colors.white.withValues(alpha: 0.14)
                  : const Color(0xFF2E6BE6))));
  final Color fg = dangerTint
      ? const Color(0xFFFF8A8A)
      : (amber
          ? const Color(0xFFE8B25C)
          : (secondary ? const Color(0xFFC3CDDE) : Colors.white));
  return GestureDetector(
    key: key,
    onTap: onTap,
    onLongPress: onLongPress,
    behavior: HitTestBehavior.opaque,
    child: Container(
      height: 40,
      // 整宽按钮默认撑满；放在 Row 里按内容宽时传 fill: false
      width: fill ? double.infinity : null,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(text,
          // 鸿蒙这些都是**默认 Button**（没写 fontSize = 16）
          style: TextStyle(
              fontSize: 16, fontWeight: FontWeight.w500, color: fg)),
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
