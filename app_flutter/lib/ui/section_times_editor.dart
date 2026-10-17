// 「上课节次时间」子页 —— 鸿蒙端 `CourseManager.ets → SectionsView()`：
// 顶部「‹ 返回 + 上课节次时间」，一行一节的「开始 / 结束 / 机动 / 删」，
// 底部「+ 加一节」「恢复北大默认 12 节」，最后「保存节次时间」。
//
// 与鸿蒙一致的取舍：编辑期间**立刻影响课表排布**只在保存后发生；输入非法（不是 HH:mm）不写入。

import 'package:flutter/material.dart';

import '../domain/dates.dart';
import '../domain/timetable.dart';
import '../model/types.dart';
import 'app_frame.dart';
import 'theme.dart';

Future<List<SectionTime>?> showSectionTimesEditor(
  BuildContext context, {
  required int semesterId,
  required List<SectionTime> sections,
}) {
  return showDialog<List<SectionTime>>(
    context: context,
    barrierColor: const Color(0x990C1220),
    builder: (ctx) => _SectionsEditor(
        semesterId: semesterId, sections: sections),
  );
}

class _SectionsEditor extends StatefulWidget {
  final int semesterId;
  final List<SectionTime> sections;
  const _SectionsEditor({required this.semesterId, required this.sections});

  @override
  State<_SectionsEditor> createState() => _SectionsEditorState();
}

class _SectionsEditorState extends State<_SectionsEditor> {
  late List<SectionTime> _rows = [
    for (final s in widget.sections)
      SectionTime(
          semesterId: s.semesterId,
          section: s.section,
          startMin: s.startMin,
          endMin: s.endMin,
          flexible: s.flexible),
  ];

  late List<TextEditingController> _starts = _controllers(true);
  late List<TextEditingController> _ends = _controllers(false);

  List<TextEditingController> _controllers(bool start) => [
        for (final s in _rows)
          TextEditingController(text: minToHHmm(start ? s.startMin : s.endMin)),
      ];

  void _rebuildControllers() {
    for (final c in _starts) {
      c.dispose();
    }
    for (final c in _ends) {
      c.dispose();
    }
    _starts = _controllers(true);
    _ends = _controllers(false);
  }

  @override
  void dispose() {
    for (final c in _starts) {
      c.dispose();
    }
    for (final c in _ends) {
      c.dispose();
    }
    super.dispose();
  }

  void _applyText(int i, bool start, String v) {
    final m = hhmmToMin(v);
    if (v.trim().length < 4 || m == null) return;
    setState(() => start ? _rows[i].startMin = m : _rows[i].endMin = m);
  }

  void _addSection() {
    final last = _rows.isEmpty ? null : _rows.last;
    setState(() {
      _rows = [
        ..._rows,
        SectionTime(
          semesterId: widget.semesterId,
          section: (last?.section ?? 0) + 1,
          startMin: (last?.endMin ?? 8 * 60) + 10,
          endMin: (last?.endMin ?? 8 * 60) + 60,
        ),
      ];
      _rebuildControllers();
    });
  }

  void _remove(int i) {
    setState(() {
      _rows = [..._rows]..removeAt(i);
      _rebuildControllers();
    });
  }

  void _resetPku() {
    setState(() {
      _rows = pkuSectionTimes(widget.semesterId);
      _rebuildControllers();
    });
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
              // TopBar：‹ 返回 + 居中标题
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
                  const Text('上课节次时间',
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
                      const Text(
                          '改这里会立刻影响课表格子的排布。北大校本部一天 12 节，第 9、12 节是机动节次（默认画得矮一点）。',
                          style: TextStyle(
                              fontSize: 11, color: Color(0xFF94A0B5))),
                      const SizedBox(height: 10),
                      Row(
                        children: const [
                          SizedBox(
                              width: 26,
                              child: Text('节',
                                  style: TextStyle(
                                      fontSize: 11,
                                      color: Color(0xFF94A0B5)))),
                          Expanded(
                              child: Text('开始',
                                  style: TextStyle(
                                      fontSize: 11,
                                      color: Color(0xFF94A0B5)))),
                          Expanded(
                              child: Text('结束',
                                  style: TextStyle(
                                      fontSize: 11,
                                      color: Color(0xFF94A0B5)))),
                          SizedBox(
                            width: 48,
                            child: Text('机动',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                    fontSize: 11,
                                    color: Color(0xFF94A0B5))),
                          ),
                          SizedBox(
                            width: 24,
                            child: Text('  ',
                                style: TextStyle(
                                    fontSize: 11,
                                    color: Color(0xFF94A0B5))),
                          ),
                        ],
                      ),
                      for (var i = 0; i < _rows.length; i++)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Row(
                            children: [
                              SizedBox(
                                width: 26,
                                child: Text('${_rows[i].section}',
                                    style: const TextStyle(
                                        fontSize: 13,
                                        color: Color(0xFFC3CDDE))),
                              ),
                              Expanded(
                                child: _HhmmField(
                                  controller: _starts[i],
                                  onChanged: (v) => _applyText(i, true, v),
                                ),
                              ),
                              const SizedBox(width: 6),
                              Expanded(
                                child: _HhmmField(
                                  controller: _ends[i],
                                  onChanged: (v) => _applyText(i, false, v),
                                ),
                              ),
                              SizedBox(
                                width: 48,
                                child: Transform.scale(
                                  scale: 0.8,
                                  child: Switch(
                                    value: _rows[i].flexible,
                                    activeThumbColor: const Color(0xFF2E6BE6),
                                    onChanged: (v) => setState(
                                        () => _rows[i].flexible = v),
                                  ),
                                ),
                              ),
                              GestureDetector(
                                onTap: () => _remove(i),
                                behavior: HitTestBehavior.opaque,
                                child: const SizedBox(
                                  width: 24,
                                  child: Text('删',
                                      textAlign: TextAlign.center,
                                      style: TextStyle(
                                          fontSize: 12,
                                          color: Color(0xFFFF8080))),
                                ),
                              ),
                            ],
                          ),
                        ),
                      const SizedBox(height: 16),
                      Row(
                        children: [
                          Expanded(
                            child: _Pill(
                              text: '+ 加一节',
                              background: const Color(0x24FFFFFF),
                              foreground: const Color(0xFF7FA8FF),
                              onTap: _addSection,
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: _Pill(
                              text: '恢复北大默认 12 节',
                              background: const Color(0x24FFFFFF),
                              foreground: const Color(0xFFC3CDDE),
                              onTap: _resetPku,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      _Pill(
                        key: const ValueKey('sections-save'),
                        text: '保存节次时间',
                        background: const Color(0xFF2E6BE6),
                        foreground: Colors.white,
                        onTap: () =>
                            Navigator.of(context).pop(List.of(_rows)),
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

/// 一行里的 HH:mm 输入框（鸿蒙端是裸 TextInput，高 32 左右）
class _HhmmField extends StatelessWidget {
  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  const _HhmmField({required this.controller, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 32,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      alignment: Alignment.centerLeft,
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(8),
      ),
      child: TextField(
        controller: controller,
        onChanged: onChanged,
        style: const TextStyle(fontSize: 13, color: inkPrimary),
        cursorColor: accentBlue,
        decoration: const InputDecoration(
            isDense: true, border: InputBorder.none, hintText: '08:00'),
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  final String text;
  final Color background;
  final Color foreground;
  final VoidCallback onTap;
  const _Pill({
    super.key,
    required this.text,
    required this.background,
    required this.foreground,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        height: 40,
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(text,
            style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w500,
                color: foreground)),
      ),
    );
  }
}
