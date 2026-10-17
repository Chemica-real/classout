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

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/backup.dart';
import '../data/backup_export.dart';
import '../domain/dates.dart';
import '../model/types.dart';
import 'app_frame.dart';
import 'theme.dart';

/// 复制一份 bundle，只换 courses / rules / templates
BackupBundle _with(
  BackupBundle b, {
  List<Course>? courses,
  List<SessionRule>? rules,
  List<TodoTemplate>? templates,
}) =>
    BackupBundle(
      app: b.app,
      version: b.version,
      exportedAt: b.exportedAt,
      semesters: b.semesters,
      sectionTimes: b.sectionTimes,
      courses: courses ?? b.courses,
      rules: rules ?? b.rules,
      overrides: b.overrides,
      todos: b.todos,
      blocks: b.blocks,
      restWindows: b.restWindows,
      templates: templates ?? b.templates,
    );

int _nextId<T>(List<T> list, int Function(T) id) =>
    list.fold<int>(0, (m, x) => id(x) > m ? id(x) : m) + 1;

Future<void> showCourseManager(
  BuildContext context, {
  required BackupBundle bundle,
  required void Function(BackupBundle next) onChanged,
}) {
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: '关闭课程管理',
    barrierColor: const Color(0x990C1220),
    transitionDuration: dur(durDrawer),
    pageBuilder: (ctx, _, __) => _Manager(bundle: bundle, onChanged: onChanged),
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
  const _Manager({required this.bundle, required this.onChanged});

  @override
  State<_Manager> createState() => _ManagerState();
}

class _ManagerState extends State<_Manager> {
  late BackupBundle _b = widget.bundle;

  /// 上次「导出备份」写出来的文件路径（同一次打开里一直显示，方便复制）
  String? _exportPath;

  void _apply(BackupBundle next) {
    setState(() => _b = next);
    widget.onChanged(next);
  }

  int _rulesOf(int courseId) =>
      _b.rules.where((r) => r.courseId == courseId).length;
  int _templatesOf(int courseId) =>
      _b.templates.where((t) => t.courseId == courseId).length;

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
                      child: const Padding(
                        padding: EdgeInsets.only(right: 12, top: 6, bottom: 6),
                        child: Row(children: [
                          Icon(Icons.chevron_left, size: 26, color: accentBlue),
                          Text('返回',
                              style:
                                  TextStyle(fontSize: 14, color: accentBlue)),
                        ]),
                      ),
                    ),
                    const Spacer(),
                    const Text('管理课程',
                        style: TextStyle(
                            fontSize: 18,
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
                        _summary(
                          '学期',
                          '${_b.semester?.name ?? '—'} · '
                              '${_b.semester?.totalWeeks ?? 0} 周 · '
                              '${_b.semester?.showWeekend == true ? '含周末' : '只到周五'}',
                        ),
                        _summary(
                          '上课节次时间',
                          '${_b.sectionTimes.length} 节：'
                              '${_b.sectionTimes.isEmpty ? '—' : '${minToHHmm(_b.sectionTimes.first.startMin)} 起，'
                                  '第 ${_b.sectionTimes.last.section} 节 ${minToHHmm(_b.sectionTimes.last.endMin)} 止'}',
                        ),
                        const SizedBox(height: 10),
                        Row(
                          children: [
                            Text('课程 ${_b.courses.length} 门',
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
                            child: Text('还没有课程。点「+ 新增课程」开始建立自己的课表。',
                                style: TextStyle(
                                    fontSize: 12, color: Color(0xFF8B97AC))),
                          ),
                        for (final c in _b.courses) _courseCard(c),
                        const SizedBox(height: 6),
                        _backupCard(),
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

  Widget _summary(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: const TextStyle(fontSize: 12, color: Color(0xFF94A0B5))),
          const SizedBox(height: 2),
          Text(value, style: const TextStyle(fontSize: 13, color: inkPrimary)),
        ],
      ),
    );
  }

  Widget _courseCard(Course c) {
    final rules = _rulesOf(c.id);
    final templates = _templatesOf(c.id);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: GestureDetector(
        key: ValueKey('course-${c.id}'),
        onTap: () => _openCourse(c),
        behavior: HitTestBehavior.opaque,
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: glassTintRow,
            borderRadius: BorderRadius.circular(glassRadius),
            border: Border.all(color: glassEdgeSoft),
          ),
          child: Row(
            children: [
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                    color: courseColor(c.colorIndex), shape: BoxShape.circle),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      c.shortName.isNotEmpty
                          ? '${c.shortName}（${c.name}）'
                          : c.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 15, color: inkPrimary),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      [
                        if (c.teacher.isNotEmpty) c.teacher,
                        if (c.location.isNotEmpty) c.location,
                        '$rules 个时段',
                        '$templates 个模板',
                        if (c.isVirtual) '虚拟课程',
                        if (!c.autoTodoEnabled) '不自动生成',
                      ].join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 11, color: Color(0xFF94A0B5)),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right,
                  size: 20, color: Color(0xFF8B97AC)),
            ],
          ),
        ),
      ),
    );
  }

  /// 「备份与恢复」：导出 JSON 到应用文档目录（鸿蒙端是同名子页）
  Widget _backupCard() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: glassEdgeSoft),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('备份与恢复',
              style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  color: inkPrimary)),
          const SizedBox(height: 4),
          const Text(
              '导出一个 JSON 文件（放在 App 的文档目录），可以拷到电脑或发给别人排查；'
              '恢复在「设置 → 数据 → 导入备份…」里。',
              style: TextStyle(fontSize: 11, color: Color(0xFF94A0B5))),
          const SizedBox(height: 8),
          Row(
            children: [
              _PillAction(text: '导出备份', onTap: _export),
              if (_exportPath != null) const SizedBox(width: 8),
              if (_exportPath != null)
                _PillAction(
                  text: '复制路径',
                  onTap: () async {
                    await Clipboard.setData(ClipboardData(text: _exportPath!));
                    if (!mounted) return;
                    ScaffoldMessenger.of(context)
                        .showSnackBar(const SnackBar(content: Text('路径已复制')));
                  },
                ),
            ],
          ),
          if (_exportPath != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: SelectableText(_exportPath!,
                  style:
                      const TextStyle(fontSize: 11, color: Color(0xFF8FC9A0))),
            ),
          const SizedBox(height: 8),
          Text(backupSummary(_b),
              style: const TextStyle(
                  fontSize: 11, height: 1.5, color: Color(0xFF8B97AC))),
        ],
      ),
    );
  }

  Future<void> _export() async {
    try {
      final path = await writeBackupFile(backupToJson(_b));
      if (!mounted) return;
      setState(() => _exportPath = path);
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('已导出到 App 文档目录')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('导出失败：$e')));
    }
  }

  Future<void> _openCourse(Course? existing) async {
    final next = await showDialog<BackupBundle>(
      context: context,
      barrierColor: const Color(0x8C0C1220),
      builder: (_) => _CourseEditor(b: _b, existing: existing),
    );
    if (next != null) _apply(next);
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
    Navigator.of(context).pop(_with(_b, courses: courses));
  }

  void _delete() {
    final rules = _b.rules.where((r) => r.courseId != _id).toList();
    final templates = _b.templates.where((t) => t.courseId != _id).toList();
    final courses = _b.courses.where((c) => c.id != _id).toList();
    Navigator.of(context)
        .pop(_with(_b, courses: courses, rules: rules, templates: templates));
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
    const names = ['一', '二', '三', '四', '五', '六', '日'];
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
            Row(
              children: [
                Expanded(
                  child: Text(_id == 0 ? '新增课程' : '编辑课程',
                      style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w500,
                          color: inkPrimary)),
                ),
                GestureDetector(
                  onTap: () => Navigator.of(context).pop(),
                  behavior: HitTestBehavior.opaque,
                  child: const Padding(
                    padding: EdgeInsets.only(left: 12, bottom: 4),
                    child:
                        Icon(Icons.close, size: 18, color: Color(0xFFA9B5C9)),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _field(_name, '课程全名', '高等数学'),
                    if (_error != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(_error!,
                            style: const TextStyle(
                                fontSize: 11, color: Color(0xFFFF8080))),
                      ),
                    _field(_short, '简称（课表格子里显示）', '高数'),
                    _field(_teacher, '教师', '王老师'),
                    _field(_location, '默认地点', '理教 101'),
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
                    ),
                    _switchRow(
                      '虚拟课程（不定时上课）',
                      _virtual,
                      (v) => setState(() => _virtual = v),
                    ),
                    if (_id > 0) ...[
                      const _Label('时段规则'),
                      if (_rules.isEmpty)
                        const Text('还没有时段。一周上两次就加两条。',
                            style: TextStyle(
                                fontSize: 12, color: Color(0xFF8B97AC))),
                      for (final r in _rules)
                        _row(
                          '周${names[r.weekday - 1]} · 第 ${r.startSection}-${r.endSection} 节'
                          '${r.location.isNotEmpty ? ' · ${r.location}' : ''}'
                          '${r.isQuiz ? ' · 习题课' : ''}',
                          onEdit: () => _editRule(r),
                          onDelete: () {
                            setState(() => _b = _with(_b,
                                rules: _b.rules
                                    .where((x) => x.id != r.id)
                                    .toList()));
                          },
                        ),
                      _PillAction(text: '+ 添加时段', onTap: () => _editRule(null)),
                      const _Label('待办模板'),
                      const Text('课时排进计划、打勾完成之后，会像真课下课一样按模板生成待办。',
                          style: TextStyle(
                              fontSize: 11, color: Color(0xFF8B97AC))),
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
                      _PillAction(
                          text: '+ 添加模板', onTap: () => _editTemplate(null)),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                if (_id > 0)
                  GestureDetector(
                    onTap: () {
                      if (_confirmDelete) {
                        _delete();
                      } else {
                        setState(() => _confirmDelete = true);
                      }
                    },
                    behavior: HitTestBehavior.opaque,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 10),
                      child: Text(_confirmDelete ? '确认删除课程' : '删除课程',
                          style:
                              const TextStyle(fontSize: 13, color: dangerRed)),
                    ),
                  ),
                const Spacer(),
                FilledButton(
                  onPressed: _save,
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF2E6BE6),
                    foregroundColor: Colors.white,
                    minimumSize: const Size(110, 40),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(20)),
                  ),
                  child: const Text('保存', style: TextStyle(fontSize: 14)),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _field(TextEditingController c, String label, String hint) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: TextField(
        controller: c,
        style: const TextStyle(fontSize: 14, color: inkPrimary),
        cursorColor: accentBlue,
        decoration: InputDecoration(
          labelText: label,
          labelStyle: const TextStyle(fontSize: 11, color: Color(0xFF94A0B5)),
          hintText: hint,
          hintStyle: const TextStyle(fontSize: 13, color: Color(0xFF8B97AC)),
          enabledBorder: const UnderlineInputBorder(
              borderSide: BorderSide(color: Color(0x24FFFFFF))),
          focusedBorder: const UnderlineInputBorder(
              borderSide: BorderSide(color: accentBlue)),
        ),
        onChanged: (_) {
          if (_error != null) setState(() => _error = null);
        },
      ),
    );
  }

  Widget _switchRow(String text, bool value, ValueChanged<bool> onChanged) {
    return Row(
      children: [
        Expanded(
          child: Text(text,
              style: const TextStyle(fontSize: 13, color: inkPrimary)),
        ),
        Switch(
            value: value,
            activeThumbColor: const Color(0xFF2E6BE6),
            onChanged: onChanged),
      ],
    );
  }

  Widget _row(String text,
      {required VoidCallback onEdit, required VoidCallback onDelete}) {
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
            _MiniAction(text: '改', color: accentBlue, onTap: onEdit),
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
  late bool _quiz = widget.existing?.isQuiz ?? false;

  @override
  void dispose() {
    _location.dispose();
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
      weeksMask:
          widget.existing?.weeksMask ?? '1' * (b.semester?.totalWeeks ?? 16),
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
                      fontSize: 16,
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
              const _Label('起止节次'),
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
              const SizedBox(height: 6),
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
              const SizedBox(height: 8),
              TextField(
                controller: _location,
                style: const TextStyle(fontSize: 13, color: inkPrimary),
                decoration: const InputDecoration(
                  labelText: '地点（留空用课程默认地点）',
                  labelStyle: TextStyle(fontSize: 11, color: Color(0xFF94A0B5)),
                  enabledBorder: UnderlineInputBorder(
                      borderSide: BorderSide(color: Color(0x24FFFFFF))),
                  focusedBorder: UnderlineInputBorder(
                      borderSide: BorderSide(color: accentBlue)),
                ),
              ),
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
  late String _category = widget.existing?.category ?? 'homework';
  late bool _enabled = widget.existing?.enabled ?? true;
  String? _error;

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
              Text(widget.existing == null ? '添加待办模板' : '修改待办模板',
                  style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w500,
                      color: inkPrimary)),
              const SizedBox(height: 4),
              const Text(
                  '变量：%C 课程全名 / %c 简称 / %D 布置日期 / %d 完整日期 / %W 周 / %T 节次 / %N 第几次 / %R 教室',
                  style: TextStyle(fontSize: 10, color: Color(0xFF8B97AC))),
              const SizedBox(height: 8),
              TextField(
                controller: _title,
                style: const TextStyle(fontSize: 14, color: inkPrimary),
                decoration: const InputDecoration(
                  labelText: '标题模板',
                  labelStyle: TextStyle(fontSize: 11, color: Color(0xFF94A0B5)),
                  hintText: '例如：%c 第 %N 次作业',
                  hintStyle: TextStyle(fontSize: 13, color: Color(0xFF8B97AC)),
                  enabledBorder: UnderlineInputBorder(
                      borderSide: BorderSide(color: Color(0x24FFFFFF))),
                  focusedBorder: UnderlineInputBorder(
                      borderSide: BorderSide(color: accentBlue)),
                ),
                onChanged: (_) {
                  if (_error != null) setState(() => _error = null);
                },
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(_error!,
                      style: const TextStyle(
                          fontSize: 11, color: Color(0xFFFF8080))),
                ),
              const _Label('截止规则'),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final r in const [
                    ('none', '不设截止'),
                    ('same_day', '当天'),
                    ('days', 'N 天后'),
                    ('weekday', '指定星期'),
                    ('week_end', '本周日'),
                    ('next_session', '下次课'),
                  ])
                    _Chip(
                      text: r.$2,
                      selected: _rule == r.$1,
                      onTap: () => setState(() => _rule = r.$1),
                    ),
                ],
              ),
              if (_rule == 'days' || _rule == 'weekday') ...[
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: TextField(
                    controller: _param,
                    keyboardType: TextInputType.number,
                    style: const TextStyle(fontSize: 13, color: inkPrimary),
                    decoration: InputDecoration(
                      labelText: _rule == 'days' ? '几天后（数字）' : '星期几（1-7）',
                      labelStyle: const TextStyle(
                          fontSize: 11, color: Color(0xFF94A0B5)),
                      enabledBorder: const UnderlineInputBorder(
                          borderSide: BorderSide(color: Color(0x24FFFFFF))),
                      focusedBorder: const UnderlineInputBorder(
                          borderSide: BorderSide(color: accentBlue)),
                    ),
                  ),
                ),
              ],
              const _Label('预计耗时'),
              Row(
                children: [
                  _RoundTap(
                    icon: Icons.remove,
                    onTap: () => setState(
                        () => _estimate = (_estimate - 15).clamp(15, 480)),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Text('$_estimate 分钟',
                        style:
                            const TextStyle(fontSize: 13, color: inkPrimary)),
                  ),
                  _RoundTap(
                    icon: Icons.add,
                    onTap: () => setState(
                        () => _estimate = (_estimate + 15).clamp(15, 480)),
                  ),
                ],
              ),
              const _Label('类型'),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final c in const [
                    ('homework', '作业'),
                    ('self', '自学'),
                    ('exam', '考试'),
                    ('none', '无'),
                  ])
                    _Chip(
                      text: c.$2,
                      selected: _category == c.$1,
                      onTap: () => setState(() => _category = c.$1),
                    ),
                ],
              ),
              Row(
                children: [
                  const Expanded(
                    child: Text('启用',
                        style: TextStyle(fontSize: 13, color: inkPrimary)),
                  ),
                  Switch(
                      value: _enabled,
                      activeThumbColor: const Color(0xFF2E6BE6),
                      onChanged: (v) => setState(() => _enabled = v)),
                ],
              ),
              const SizedBox(height: 6),
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

class _RoundTap extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  const _RoundTap({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        width: 28,
        height: 28,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Icon(icon, size: 16, color: inkSecondary),
      ),
    );
  }
}
