// 待办编辑器 —— 鸿蒙端 `TodoInbox.ets → EditorPanel()`：
// **右侧 84% 抽屉**（点空白遮罩关闭），标题固定、内容可滚，字段顺序与鸿蒙端一致：
//   标题 → 类型 →（考试时）考试日期/开始/结束 →（非考试）截止 → 预计耗时 → 所属课程 → 备注
// 底部「保存」；编辑已有条目时多一个「删除」。

import 'package:flutter/material.dart';

import '../data/note_pref.dart';
import '../domain/dates.dart';
import '../model/types.dart';
import 'app_frame.dart';
import 'theme.dart';

/// 编辑器结果：改好的条目，或者"用户要删掉这一条"
class TodoEditorResult {
  final Todo? todo;
  final bool delete;
  const TodoEditorResult(this.todo) : delete = false;
  const TodoEditorResult.delete()
      : todo = null,
        delete = true;
}

Future<TodoEditorResult?> showTodoEditor(
  BuildContext context, {
  required List<Course> courses,
  Todo? existing,
  bool asExam = false,
  void Function(bool on)? onNotePref,
}) {
  return showGeneralDialog<TodoEditorResult>(
    context: context,
    barrierDismissible: true,
    barrierLabel: '关闭编辑器',
    barrierColor: const Color(0x730C1220), // rgba(12,18,28,0.45)
    transitionDuration: dur(durDrawer),
    pageBuilder: (ctx, _, __) => _DrawerHost(
      ctx: ctx,
      courses: courses,
      existing: existing,
      asExam: asExam,
      onNotePref: onNotePref,
    ),
    transitionBuilder: (ctx, anim, _, child) {
      final curved = CurvedAnimation(parent: anim, curve: drawerCurve);
      return SlideTransition(
        position: Tween<Offset>(begin: const Offset(1, 0), end: Offset.zero)
            .animate(curved),
        child: FadeTransition(opacity: curved, child: child),
      );
    },
  );
}

/// 四个快捷截止（与鸿蒙端一致：今天 / 明天 / 本周日 / 3 天后，都是 23:59）
List<(String, String)> ddlPresets() {
  final t = today();
  final wd = weekdayOf(t); // 1..7
  return [
    ('今天', '${formatDate(t)} 23:59'),
    ('明天', '${formatDate(addDays(t, 1))} 23:59'),
    ('本周日', '${formatDate(addDays(t, 7 - wd))} 23:59'),
    ('3 天后', '${formatDate(addDays(t, 3))} 23:59'),
  ];
}

class _DrawerHost extends StatelessWidget {
  final BuildContext ctx;
  final List<Course> courses;
  final Todo? existing;
  final bool asExam;
  final void Function(bool on)? onNotePref;

  const _DrawerHost({
    required this.ctx,
    required this.courses,
    required this.existing,
    required this.asExam,
    this.onNotePref,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      type: MaterialType.transparency,
      child: Align(
        alignment: Alignment.centerRight,
        child: FractionallySizedBox(
          widthFactor: drawerWidthFactor,
          heightFactor: 1,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(0, floatTop, 0, floatGap),
            child: Glass(
              sheet: true,
              radius: 18,
              padding: const EdgeInsets.fromLTRB(18, 14, 18, 14),
              child: _EditorBody(
                ctx: ctx,
                courses: courses,
                existing: existing,
                asExam: asExam,
                onNotePref: onNotePref,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _EditorBody extends StatefulWidget {
  final BuildContext ctx;
  final List<Course> courses;
  final Todo? existing;
  final bool asExam;
  final void Function(bool on)? onNotePref;

  const _EditorBody({
    required this.ctx,
    required this.courses,
    required this.existing,
    required this.asExam,
    this.onNotePref,
  });

  @override
  State<_EditorBody> createState() => _EditorBodyState();
}

class _EditorBodyState extends State<_EditorBody> {
  late final TextEditingController _title;
  late final TextEditingController _note;
  late String _category;
  late String _ddl;
  late String _examDate;
  late String _examStart;
  late String _examEnd;
  late int _courseId;
  late int _estimateMin;
  String? _error;

  static const List<String> _startTimes = [
    '08:00',
    '09:00',
    '10:00',
    '14:00',
    '15:00',
    '19:00'
  ];
  static const List<int> _durations = [60, 90, 120, 150];

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _title = TextEditingController(text: e?.title ?? '');
    _note = TextEditingController(text: e?.note ?? '');
    _category = e?.category ??
        (widget.asExam ? TodoCategory.exam : TodoCategory.homework);
    _ddl = e?.ddl ?? '';
    _examDate = _ddl.length >= 10 ? _ddl.substring(0, 10) : formatDate(today());
    _examStart = _ddl.length >= 16 ? _ddl.substring(11, 16) : '09:00';
    _examEnd = (e?.endAt.length ?? 0) >= 16
        ? e!.endAt.substring(11, 16)
        : _addMinutes(_examStart, 120);
    _courseId = e?.courseId ?? 0;
    _estimateMin = e?.estimateMin ?? 60;
  }

  @override
  void dispose() {
    _title.dispose();
    _note.dispose();
    super.dispose();
  }

  static String _addMinutes(String hhmm, int minutes) {
    final h = int.parse(hhmm.substring(0, 2));
    final m = int.parse(hhmm.substring(3, 5));
    final total = (h * 60 + m + minutes).clamp(0, 23 * 60 + 59);
    return minToHHmm(total);
  }

  void _submit() {
    final title = _title.text.trim();
    if (title.isEmpty) {
      setState(() => _error = '标题不能为空');
      return;
    }
    final e = widget.existing;
    final isExam = _category == TodoCategory.exam;
    Navigator.of(widget.ctx).pop(TodoEditorResult(Todo(
      id: e?.id ?? 0, // 新建时由调用方分配
      title: title,
      category: _category,
      ddl: isExam ? '$_examDate $_examStart' : _ddl,
      endAt: isExam ? '$_examDate $_examEnd' : (e?.endAt ?? ''),
      courseId: _courseId,
      estimateMin: isExam ? 0 : _estimateMin,
      note: _note.text.trim(),
      status: e?.status ?? TodoStatus.active,
      priority: e?.priority ?? 1,
      source: e?.source ?? 'manual',
      generationKey: e?.generationKey ?? '',
      submitChannel: e?.submitChannel ?? '',
      repeatRule: e?.repeatRule ?? '',
      photos: e?.photos ?? '',
      createdAt: e?.createdAt ?? DateTime.now().millisecondsSinceEpoch,
      confirmedAt: e?.confirmedAt ?? 0,
      doneAt: e?.doneAt ?? 0,
    )));
  }

  @override
  Widget build(BuildContext context) {
    final isExam = _category == TodoCategory.exam;
    final presets = ddlPresets();
    final wd = weekdayOf(today());
    final dates = [
      ('今天', formatDate(today())),
      ('明天', formatDate(addDays(today(), 1))),
      ('3 天后', formatDate(addDays(today(), 3))),
      ('本周日', formatDate(addDays(today(), 7 - wd))),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(widget.existing == null ? '新建待办' : '编辑待办',
                  style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w500,
                      color: inkPrimary)),
            ),
            GestureDetector(
              onTap: () => Navigator.of(widget.ctx).pop(),
              behavior: HitTestBehavior.opaque,
              child: const Padding(
                padding: EdgeInsets.only(left: 12, bottom: 4),
                child: Icon(Icons.close, size: 18, color: Color(0xFFA9B5C9)),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Expanded(
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: _title,
                  autofocus: widget.existing == null,
                  style: const TextStyle(fontSize: 15, color: inkPrimary),
                  cursorColor: accentBlue,
                  decoration: const InputDecoration(
                    hintText: '例如：数学作业 P12 第 3-5 题',
                    hintStyle:
                        TextStyle(fontSize: 14, color: Color(0xFF8B97AC)),
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
                _Label('类型'),
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  children: [
                    for (final o in [
                      (TodoCategory.homework, '作业'),
                      (TodoCategory.self, '自学'),
                      (TodoCategory.exam, '考试'),
                      (TodoCategory.none, '无'),
                    ])
                      _Chip(
                        text: o.$2,
                        selected: _category == o.$1,
                        onTap: () => setState(() => _category = o.$1),
                      ),
                  ],
                ),
                if (isExam) ...[
                  _Label('考试日期'),
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    children: [
                      for (final d in dates)
                        _Chip(
                          text: '${d.$1} ${d.$2.substring(5)}',
                          selected: _examDate == d.$2,
                          onTap: () => setState(() => _examDate = d.$2),
                        ),
                    ],
                  ),
                  _Label('开始'),
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    children: [
                      for (final t in _startTimes)
                        _Chip(
                          text: t,
                          selected: _examStart == t,
                          onTap: () => setState(() {
                            _examStart = t;
                            if (_examEnd.compareTo(t) <= 0) {
                              _examEnd = _addMinutes(t, 120);
                            }
                          }),
                        ),
                    ],
                  ),
                  _Label('结束'),
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    children: [
                      for (final m in _durations)
                        _Chip(
                          text: _addMinutes(_examStart, m),
                          selected: _examEnd == _addMinutes(_examStart, m),
                          onTap: () => setState(
                              () => _examEnd = _addMinutes(_examStart, m)),
                        ),
                    ],
                  ),
                ] else ...[
                  _Label('截止'),
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    children: [
                      _Chip(
                        text: '无截止',
                        selected: _ddl.isEmpty,
                        onTap: () => setState(() => _ddl = ''),
                      ),
                      for (final p in presets)
                        _Chip(
                          text: p.$1,
                          selected: _ddl == p.$2,
                          onTap: () => setState(() => _ddl = p.$2),
                        ),
                      _Chip(
                        text: '自定义…',
                        selected: _ddl.isNotEmpty &&
                            !presets.any((p) => p.$2 == _ddl),
                        onTap: _pickCustomDdl,
                      ),
                    ],
                  ),
                  _Label('预计耗时'),
                  Row(
                    children: [
                      _RoundTap(
                        icon: Icons.remove,
                        onTap: () => setState(() =>
                            _estimateMin = (_estimateMin - 15).clamp(15, 480)),
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: Text('$_estimateMin 分钟',
                            style: const TextStyle(
                                fontSize: 13, color: inkPrimary)),
                      ),
                      _RoundTap(
                        icon: Icons.add,
                        onTap: () => setState(() =>
                            _estimateMin = (_estimateMin + 15).clamp(15, 480)),
                      ),
                    ],
                  ),
                ],
                if (widget.courses.isNotEmpty) ...[
                  _Label('所属课程'),
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    children: [
                      _Chip(
                        text: '不关联',
                        selected: _courseId == 0,
                        onTap: () => setState(() => _courseId = 0),
                      ),
                      for (final c in widget.courses)
                        _Chip(
                          text: c.label,
                          selected: _courseId == c.id,
                          onTap: () => setState(() => _courseId = c.id),
                        ),
                    ],
                  ),
                ],
                Row(
                  children: [
                    const _Label('备注'),
                    const Spacer(),
                    GestureDetector(
                      onTap: () {
                        setState(() => noteExpanded = !noteExpanded);
                        widget.onNotePref?.call(noteExpanded);
                      },
                      behavior: HitTestBehavior.opaque,
                      child: Padding(
                        padding:
                            const EdgeInsets.only(top: 16, bottom: 8, left: 8),
                        child: Text(noteExpanded ? '收起 ▾' : '展开 ▸',
                            style: const TextStyle(
                                fontSize: 11, color: accentBlue)),
                      ),
                    ),
                  ],
                ),
                TextField(
                  controller: _note,
                  minLines: noteExpanded ? 3 : 1,
                  maxLines: noteExpanded ? 8 : 3,
                  style: const TextStyle(fontSize: 13, color: inkPrimary),
                  cursorColor: accentBlue,
                  decoration: const InputDecoration(
                    hintText: '记得写过程…',
                    hintStyle:
                        TextStyle(fontSize: 13, color: Color(0xFF8B97AC)),
                    enabledBorder: UnderlineInputBorder(
                        borderSide: BorderSide(color: Color(0x24FFFFFF))),
                    focusedBorder: UnderlineInputBorder(
                        borderSide: BorderSide(color: accentBlue)),
                  ),
                ),
                const SizedBox(height: 14),
              ],
            ),
          ),
        ),
        Row(
          children: [
            if (widget.existing != null)
              GestureDetector(
                onTap: () => Navigator.of(widget.ctx)
                    .pop(const TodoEditorResult.delete()),
                behavior: HitTestBehavior.opaque,
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                  child: Text('删除',
                      style: TextStyle(fontSize: 13, color: dangerRed)),
                ),
              ),
            const Spacer(),
            FilledButton(
              onPressed: _submit,
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFF2E6BE6),
                foregroundColor: Colors.white,
                minimumSize: const Size(120, 40),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(20)),
              ),
              child: const Text('保存', style: TextStyle(fontSize: 14)),
            ),
          ],
        ),
      ],
    );
  }

  Future<void> _pickCustomDdl() async {
    final base = _ddl.isEmpty ? today() : parseDate(_ddl.substring(0, 10));
    final picked = await showDatePicker(
      context: context,
      initialDate: base,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked == null) return;
    setState(() => _ddl = '${formatDate(picked)} 23:59');
  }
}

class _Label extends StatelessWidget {
  final String text;
  const _Label(this.text);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 16, bottom: 8),
        child: Text(text,
            style: const TextStyle(fontSize: 12, color: Color(0xFF94A0B5))),
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
