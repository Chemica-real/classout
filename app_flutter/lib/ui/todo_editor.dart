// 新建待办的对话框（第一版：标题 + 类型 + 截止 + 所属课程）。
// 编辑已有条目、考试的时间段、备注、预计耗时留到下一轮。

import 'package:flutter/material.dart';

import '../domain/dates.dart';
import '../model/types.dart';
import 'palette.dart';

Future<Todo?> showTodoEditor(BuildContext context, {required List<Course> courses}) {
  return showDialog<Todo>(context: context, builder: (_) => _Editor(courses: courses));
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

class _Editor extends StatefulWidget {
  final List<Course> courses;
  const _Editor({required this.courses});

  @override
  State<_Editor> createState() => _EditorState();
}

class _EditorState extends State<_Editor> {
  final _title = TextEditingController();
  String _category = TodoCategory.homework;
  String _ddl = '';
  int _courseId = 0;
  String? _error;

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  void _submit() {
    final title = _title.text.trim();
    if (title.isEmpty) {
      setState(() => _error = '标题不能为空');
      return;
    }
    Navigator.of(context).pop(Todo(
      title: title,
      category: _category,
      ddl: _ddl,
      courseId: _courseId,
      status: TodoStatus.active,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final presets = ddlPresets();
    return AlertDialog(
      title: const Text('新建待办'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: _title,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: '标题',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                onChanged: (_) {
                  if (_error != null) setState(() => _error = null);
                },
              ),
              if (_error != null) ...[
                const SizedBox(height: 6),
                Text(_error!,
                    style: const TextStyle(fontSize: 12, color: Color(0xFFFF8080))),
              ],
              const SizedBox(height: 12),
              const Text('类型', style: TextStyle(fontSize: 12, color: inkSecondary)),
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                children: [
                  for (final o in [
                    (TodoCategory.homework, '作业'),
                    (TodoCategory.self, '自学'),
                    (TodoCategory.none, '无'),
                  ])
                    ChoiceChip(
                      label: Text(o.$2, style: const TextStyle(fontSize: 12)),
                      selected: _category == o.$1,
                      onSelected: (_) => setState(() => _category = o.$1),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              const Text('截止', style: TextStyle(fontSize: 12, color: inkSecondary)),
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                children: [
                  ChoiceChip(
                    label: const Text('无截止', style: TextStyle(fontSize: 12)),
                    selected: _ddl.isEmpty,
                    onSelected: (_) => setState(() => _ddl = ''),
                  ),
                  for (final p in presets)
                    ChoiceChip(
                      label: Text(p.$1, style: const TextStyle(fontSize: 12)),
                      selected: _ddl == p.$2,
                      onSelected: (_) => setState(() => _ddl = p.$2),
                    ),
                ],
              ),
              if (widget.courses.isNotEmpty) ...[
                const SizedBox(height: 12),
                const Text('所属课程', style: TextStyle(fontSize: 12, color: inkSecondary)),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  children: [
                    ChoiceChip(
                      label: const Text('不关联', style: TextStyle(fontSize: 12)),
                      selected: _courseId == 0,
                      onSelected: (_) => setState(() => _courseId = 0),
                    ),
                    for (final c in widget.courses)
                      ChoiceChip(
                        label: Text(c.label, style: const TextStyle(fontSize: 12)),
                        selected: _courseId == c.id,
                        onSelected: (_) => setState(() => _courseId = c.id),
                      ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _submit, child: const Text('保存')),
      ],
    );
  }
}
