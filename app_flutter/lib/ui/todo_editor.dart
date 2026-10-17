// 待办编辑器 —— 鸿蒙端 `TodoInbox.ets → EditorPanel()`：
// **右侧 84% 抽屉**（点空白遮罩关闭），标题固定、内容可滚，字段顺序与鸿蒙端一致：
//   标题 → 类型 →（考试时）考试日期/开始/结束 →（非考试）截止 → 预计耗时 → 所属课程 → 备注
// 底部「保存」；编辑已有条目时多一个「删除」。

import 'package:flutter/material.dart';

import '../data/note_pref.dart';
import '../domain/categories.dart';
import '../domain/dates.dart';
import '../domain/todo_list.dart' show ddlText;
import '../domain/validate.dart';
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
  List<String> customCategories = const [],
  void Function(String name)? onAddCategory,
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
      customCategories: customCategories,
      onAddCategory: onAddCategory,
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
  final List<String> customCategories;
  final void Function(String name)? onAddCategory;

  const _DrawerHost({
    required this.ctx,
    required this.courses,
    required this.existing,
    required this.asExam,
    this.onNotePref,
    this.customCategories = const [],
    this.onAddCategory,
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
            // 鸿蒙 EditorPanel 外层：`.padding({ right: FLOAT_SIDE, top: 10, bottom: 10 })`
            // —— 右边留一条缝（能看出"底下还有一页"），四角大圆角
            padding: const EdgeInsets.fromLTRB(0, 10, floatSide, 10),
            child: Glass(
              sheet: true,
              radius: glassRadius,
              padding: const EdgeInsets.fromLTRB(18, 14, 18, 14),
              child: _EditorBody(
                ctx: ctx,
                courses: courses,
                existing: existing,
                asExam: asExam,
                onNotePref: onNotePref,
                customCategories: customCategories,
                onAddCategory: onAddCategory,
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
  final List<String> customCategories;
  final void Function(String name)? onAddCategory;

  const _EditorBody({
    required this.ctx,
    required this.courses,
    required this.existing,
    required this.asExam,
    this.onNotePref,
    this.customCategories = const [],
    this.onAddCategory,
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

  /// 自定义类型（就地新建；同时回写设置页那份列表）
  late List<String> _custom = List.of(widget.customCategories);
  bool _catCreating = false;
  final TextEditingController _catDraft = TextEditingController();
  String _catError = '';

  /// 预计耗时「自定义」的输入态
  final TextEditingController _estDraft = TextEditingController();
  bool _estFocus = false;
  String _estError = '';

  /// 删除的二次确认（编辑已有条目时才有）
  bool _confirmDelete = false;

  static const List<int> _presetEstimates = [15, 30, 60, 90, 120, 180];


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
    _catDraft.dispose();
    _estDraft.dispose();
    super.dispose();
  }

  bool get _customEstimateActive => !_presetEstimates.contains(_estimateMin);
  String get _customChipLabel =>
      _customEstimateActive ? '$_estimateMin 分钟' : '自定义';

  /// 自定义时长失焦/提交：非 5 倍数对齐到最近 5，越界夹紧，**并把结果写回输入框**
  void _commitCustomEstimate() {
    setState(() => _estFocus = false);
    final raw = _estDraft.text.trim();
    if (raw.isEmpty) return;
    final n = int.tryParse(raw);
    if (n == null) {
      setState(() => _estError = '时长要填一个数字');
      return;
    }
    final verdict = validateEstimate(n, false);
    final fixed = normalizeEstimate(n, false);
    setState(() {
      _estimateMin = fixed;
      _estDraft.text = '$fixed';
      _estError = verdict.ok ? '' : '已对齐到 $fixed 分钟（${verdict.message}）';
    });
  }

  void _addCategoryInline() {
    final name = _catDraft.text.trim();
    final verdict = validateCategoryName(name, _custom);
    if (!verdict.ok) {
      setState(() => _catError = verdict.message);
      return;
    }
    setState(() {
      _custom = addCustomCategory(_custom, name);
      _catCreating = false;
      _catDraft.text = '';
      _catError = '';
      _category = name;
    });
    widget.onAddCategory?.call(name);
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
    final examStartText = _examStart.isEmpty ? '未选' : '$_examDate $_examStart';
    final examEndText = _examEnd.isEmpty ? '未选' : '$_examDate $_examEnd';
    final catOptions = <(String, String)>[
      (TodoCategory.homework, '作业'),
      (TodoCategory.self, '自学'),
      (TodoCategory.exam, '考试'),
      (TodoCategory.none, '无'),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 抽屉头：标题固定不滚；右侧 ✕ = 关掉（底部也有取消）
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
                child: Text('✕',
                    style: TextStyle(fontSize: 14, color: Color(0xFFA9B5C9))),
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
                const SizedBox(height: 14),
                _InputBox(
                  key: const ValueKey('todo-title'),
                  controller: _title,
                  hint: '例如：数学作业 P12 第 3-5 题',
                  autofocus: widget.existing == null,
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
                    for (final o in catOptions)
                      _Chip(
                        text: o.$2,
                        selected: _category == o.$1,
                        onTap: () => setState(() => _category = o.$1),
                      ),
                    for (final name in _custom)
                      _Chip(
                        text: name,
                        selected: _category == name,
                        onTap: () => setState(() => _category = name),
                      ),
                    // 「＋ 新建类型」：琥珀色，和内置/自定义的蓝/灰刻意不同
                    GestureDetector(
                      key: const ValueKey('todo-new-category'),
                      onTap: () => setState(() {
                        _catCreating = !_catCreating;
                        _catDraft.text = '';
                        _catError = '';
                      }),
                      behavior: HitTestBehavior.opaque,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(
                          color: const Color(0x29E8B25C), // rgba(232,178,92,0.16)
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: const Text('＋ 新建类型',
                            style: TextStyle(
                                fontSize: 12, color: Color(0xFFE8B25C))),
                      ),
                    ),
                  ],
                ),
                if (_catCreating) ...[
                  Padding(
                    padding: const EdgeInsets.only(top: 2, bottom: 4),
                    child: Row(
                      children: [
                        Expanded(
                          child: _InputBox(
                            key: const ValueKey('todo-cat-input'),
                            controller: _catDraft,
                            hint: '新类型名（最多 $categoryNameMax 个字）',
                            onChanged: (_) =>
                                setState(() => _catError = ''),
                          ),
                        ),
                        const SizedBox(width: 8),
                        _Pill(
                          text: '添加',
                          background: const Color(0x33E8B25C),
                          foreground: const Color(0xFFE8B25C),
                          onTap: _addCategoryInline,
                        ),
                        const SizedBox(width: 8),
                        _Pill(
                          text: '取消',
                          background: const Color(0x1FFFFFFF),
                          foreground: const Color(0xFFA9B5C9),
                          onTap: () => setState(() {
                            _catCreating = false;
                            _catError = '';
                          }),
                        ),
                      ],
                    ),
                  ),
                  if (_catError.isNotEmpty)
                    Text(_catError,
                        style: const TextStyle(
                            fontSize: 11, color: Color(0xFFFF8A8A))),
                ],
                // 备注：考试时就是「考场 / 座位」，同一个 note 字段
                Padding(
                  padding: const EdgeInsets.only(top: 6, bottom: 6),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(isExam ? '考场 / 座位' : '备注',
                            style: const TextStyle(
                                fontSize: 12, color: Color(0xFF94A0B5))),
                      ),
                      GestureDetector(
                        onTap: () {
                          setState(() => noteExpanded = !noteExpanded);
                          widget.onNotePref?.call(noteExpanded);
                        },
                        behavior: HitTestBehavior.opaque,
                        child: Padding(
                          padding: const EdgeInsets.only(left: 10),
                          child: Text(noteExpanded ? '收起 ▴' : '展开 ▾',
                              style: const TextStyle(
                                  fontSize: 11, color: accentBlue)),
                        ),
                      ),
                    ],
                  ),
                ),
                if (noteExpanded)
                  Container(
                    height: 150,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 8),
                    // 鸿蒙 TextArea 同样没有可见底色
                    decoration: BoxDecoration(
                      color: Colors.transparent,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: TextField(
                      controller: _note,
                      maxLines: null,
                      expands: true,
                      textAlignVertical: TextAlignVertical.top,
                      style:
                          const TextStyle(fontSize: 13, color: inkPrimary),
                      cursorColor: accentBlue,
                      decoration: InputDecoration(
                        isDense: true,
                        border: InputBorder.none,
                        hintText: isExam
                            ? '教学楼 101 · 12 号座'
                            : '可选，随便记点什么',
                        hintStyle: const TextStyle(
                            fontSize: 13, color: Color(0xFF8B97AC)),
                      ),
                    ),
                  )
                else
                  _InputBox(
                    key: const ValueKey('todo-note'),
                    controller: _note,
                    hint: isExam ? '教学楼 101 · 12 号座' : '可选，随便记点什么',
                    onChanged: (_) {},
                  ),
                if (isExam) ...[
                  _Label('考试时间'),
                  _timeRow('开始', examStartText,
                      () => _pickExamTime(start: true)),
                  _timeRow('结束', examEndText,
                      () => _pickExamTime(start: false)),
                  Text(
                      _estError.isNotEmpty
                          ? _estError
                          : '保存后会自动排进计划视图（与已有的块重叠也照排）',
                      style: TextStyle(
                          fontSize: 10,
                          color: _estError.isNotEmpty
                              ? const Color(0xFFFF8A8A)
                              : const Color(0xFF8B97AC))),
                ] else ...[
                  _Label('截止'),
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    children: [
                      for (final p in presets)
                        _Chip(
                          text: '${p.$1} 23:59',
                          selected: _ddl == p.$2,
                          onTap: () => setState(() => _ddl = p.$2),
                        ),
                      _Chip(
                        text: '无截止',
                        selected: _ddl.isEmpty,
                        onTap: () => setState(() => _ddl = ''),
                      ),
                      _Chip(
                        text: _ddl.isNotEmpty &&
                                !presets.any((p) => p.$2 == _ddl)
                            ? _ddlShort(_ddl)
                            : '自定义…',
                        selected: _ddl.isNotEmpty &&
                            !presets.any((p) => p.$2 == _ddl),
                        onTap: _pickCustomDdl,
                      ),
                    ],
                  ),
                  Text(_ddl.isEmpty ? '截止：无' : '截止：${ddlText(_ddl)}',
                      style: const TextStyle(
                          fontSize: 11, color: Color(0xFF8B97AC))),
                  _Label('预计耗时'),
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    children: [
                      for (final m in _presetEstimates)
                        _Chip(
                          text: '$m 分钟',
                          selected: _estimateMin == m,
                          onTap: () => setState(() {
                            _estimateMin = m;
                            _estDraft.text = '';
                            _estFocus = false;
                          }),
                        ),
                      _Chip(
                        key: const ValueKey('todo-est-custom'),
                        text: _customChipLabel,
                        selected: _customEstimateActive || _estFocus,
                        onTap: () => setState(() {
                          _estFocus = true;
                          _estDraft.text = '$_estimateMin';
                        }),
                      ),
                    ],
                  ),
                  if (_estFocus || _customEstimateActive) ...[
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        Expanded(
                          child: _InputBox(
                            key: const ValueKey('todo-est-input'),
                            controller: _estDraft,
                            hint: '如 25',
                            keyboardType: TextInputType.number,
                            onChanged: (v) {
                              final n = int.tryParse(v);
                              if (n != null && validateEstimate(n, false).ok) {
                                setState(() {
                                  _estimateMin = n;
                                  _estError = '';
                                });
                              }
                            },
                            onSubmitted: (_) => _commitCustomEstimate(),
                          ),
                        ),
                        const SizedBox(width: 8),
                        const Text('分钟',
                            style: TextStyle(
                                fontSize: 12, color: Color(0xFF94A0B5))),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                        _estError.isNotEmpty
                            ? _estError
                            : '15–600 分钟，且必须是 5 分钟的整数倍',
                        style: TextStyle(
                            fontSize: 10,
                            color: _estError.isNotEmpty
                                ? const Color(0xFFFF8A8A)
                                : const Color(0xFF8B97AC))),
                  ],
                ],
                if (widget.courses.isNotEmpty) ...[
                  // 鸿蒙这里漏了 width('100%')，文字被 Column 默认居中 —— 真机图如此，照抄
                  const Center(child: _Label('所属课程')),
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    children: [
                      _Chip(
                        text: '无',
                        selected: _courseId == 0,
                        onTap: () => setState(() => _courseId = 0),
                      ),
                      for (final c in widget.courses)
                        _Chip(
                          text: c.shortName.isNotEmpty ? c.shortName : c.name,
                          selected: _courseId == c.id,
                          onTap: () => setState(() => _courseId = c.id),
                        ),
                    ],
                  ),
                ],
                const SizedBox(height: 20),
                Row(
                  children: [
                    Expanded(
                      child: _Pill(
                        text: '取消',
                        background: const Color(0x24FFFFFF),
                        foreground: const Color(0xFFC3CDDE),
                        onTap: () => Navigator.of(widget.ctx).pop(),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _Pill(
                        key: const ValueKey('todo-save'),
                        text: '保存',
                        background: const Color(0xFF2E6BE6),
                        foreground: Colors.white,
                        onTap: _submit,
                      ),
                    ),
                  ],
                ),
                // ---- 删除（只对已存在的待办；点两下才真删）----
                if (widget.existing != null) ...[
                  Padding(
                    padding: const EdgeInsets.only(top: 18, bottom: 14),
                    child: Divider(
                        height: 1, color: Colors.white.withValues(alpha: 0.12)),
                  ),
                  if (_confirmDelete) ...[
                    const Text('确定删除这条待办？删除后不可恢复。',
                        style: TextStyle(
                            fontSize: 11, color: Color(0xFFFF8A8A))),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: _Pill(
                            text: '取消',
                            background: const Color(0x24FFFFFF),
                            foreground: const Color(0xFFC3CDDE),
                            onTap: () =>
                                setState(() => _confirmDelete = false),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: _Pill(
                            key: const ValueKey('todo-delete-confirm'),
                            text: '确认删除',
                            background: const Color(0xFFD64545),
                            foreground: Colors.white,
                            onTap: () => Navigator.of(widget.ctx)
                                .pop(const TodoEditorResult.delete()),
                          ),
                        ),
                      ],
                    ),
                  ] else
                    _Pill(
                      key: const ValueKey('todo-delete'),
                      text: '删除待办',
                      background: const Color(0x2ED64545), // rgba(214,69,69,0.18)
                      foreground: const Color(0xFFFF8A8A),
                      height: 40,
                      onTap: () => setState(() => _confirmDelete = true),
                    ),
                  const SizedBox(height: 14),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// 考试的开始 / 结束行（鸿蒙端：标签 40 + 值 + 「选择…」）
  Widget _timeRow(String label, String value, VoidCallback pick) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          SizedBox(
            width: 40,
            child: Text(label,
                style:
                    const TextStyle(fontSize: 12, color: Color(0xFF94A0B5))),
          ),
          Expanded(
            child: Text(value,
                style:
                    const TextStyle(fontSize: 13, color: Color(0xFFF2F5FA))),
          ),
          _Pill(
            text: '选择…',
            background: const Color(0x24FFFFFF),
            foreground: const Color(0xFF7FA8FF),
            height: 32,
            onTap: pick,
          ),
        ],
      ),
    );
  }

  /// 考试时间：先选日期再选时刻（鸿蒙端两个系统滚轮）
  Future<void> _pickExamTime({required bool start}) async {
    final d = await showDatePicker(
      context: context,
      initialDate: parseDate(_examDate),
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (d == null || !mounted) return;
    final t = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(
          hour: int.parse((start ? _examStart : _examEnd).substring(0, 2)),
          minute: int.parse((start ? _examStart : _examEnd).substring(3, 5))),
    );
    if (t == null || !mounted) return;
    setState(() {
      _examDate = formatDate(d);
      final hhmm = minToHHmm(t.hour * 60 + t.minute);
      if (start) {
        _examStart = hhmm;
        if (_examEnd.compareTo(hhmm) <= 0) {
          _examEnd = _addMinutes(hhmm, 120);
        }
      } else {
        _examEnd = hhmm;
      }
    });
  }

  String _ddlShort(String ddl) {
    // 鸿蒙 `ddlShort`：'2026-10-15 14:07' → '10/15 14:07'（**斜线**，不是 10-15）
    if (ddl.length < 16) return '自定义…';
    return '${ddl.substring(5, 7)}/${ddl.substring(8, 10)} '
        '${ddl.substring(11, 16)}';
  }

  /// 自定义截止：日期 + 时间（鸿蒙端 `pickDateTime`，分钟不限）
  Future<void> _pickCustomDdl() async {
    final base = _ddl.isEmpty ? today() : parseDate(_ddl.substring(0, 10));
    final picked = await showDatePicker(
      context: context,
      initialDate: base,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked == null || !mounted) return;
    final hm = _ddl.length >= 16
        ? TimeOfDay(
            hour: int.tryParse(_ddl.substring(11, 13)) ?? 23,
            minute: int.tryParse(_ddl.substring(14, 16)) ?? 59)
        : const TimeOfDay(hour: 23, minute: 59);
    final time = await showTimePicker(context: context, initialTime: hm);
    if (time == null || !mounted) return;
    setState(() => _ddl = '${formatDate(picked)} '
        '${minToHHmm(time.hour * 60 + time.minute)}');
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
      {super.key,
      required this.text,
      required this.selected,
      required this.onTap});

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


/// 胶囊输入框（鸿蒙端裸 `TextInput`：高 40、圆角 20、无边框）
class _InputBox extends StatelessWidget {
  final TextEditingController controller;
  final String hint;
  final ValueChanged<String> onChanged;
  final ValueChanged<String>? onSubmitted;
  final bool autofocus;
  final TextInputType? keyboardType;
  const _InputBox({
    super.key,
    required this.controller,
    required this.hint,
    required this.onChanged,
    this.onSubmitted,
    this.autofocus = false,
    this.keyboardType,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 40,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      alignment: Alignment.centerLeft,
      decoration: const BoxDecoration(),
      child: TextField(
        controller: controller,
        autofocus: autofocus,
        keyboardType: keyboardType,
        style: const TextStyle(fontSize: 14, color: inkPrimary),
        cursorColor: accentBlue,
        onChanged: onChanged,
        onSubmitted: onSubmitted,
        decoration: InputDecoration(
          isDense: true,
          border: InputBorder.none,
          hintText: hint,
          hintStyle:
              const TextStyle(fontSize: 14, color: Color(0xFF8B97AC)),
        ),
      ),
    );
  }
}

/// 胶囊按钮（鸿蒙端默认 Button：圆角胶囊、居中文字）
class _Pill extends StatelessWidget {
  final String text;
  final Color background;
  final Color foreground;
  final VoidCallback onTap;
  final double height;
  const _Pill({
    super.key,
    required this.text,
    required this.background,
    required this.foreground,
    required this.onTap,
    this.height = 40,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        height: height,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(height / 2),
        ),
        child: Text(text,
            style: TextStyle(
                fontSize: height >= 36 ? 14 : 12,
                fontWeight: FontWeight.w500,
                color: foreground)),
      ),
    );
  }
}
