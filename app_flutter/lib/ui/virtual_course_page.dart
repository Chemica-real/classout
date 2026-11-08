// 虚拟课程文件夹 / 课时页 —— 对齐鸿蒙 1.10.0 的 TodoInbox 虚拟课程区。
//
// 待办页只列“课程文件夹”（颜色 + 全名 + 已完成/总讲数）；点进去才是课时页。
// 每一讲可以打勾、改名、改这一讲时长、删除；打勾会同步已有计划块并按模板生成待办。

import 'dart:io';

import 'package:flutter/material.dart';

import 'wallpaper_view.dart';

import '../data/backup.dart';
import '../domain/dates.dart' show formatDate, today;
import '../domain/timetable.dart' show lessonTitleOf;
import '../domain/todo_generator.dart' show generateForLesson;
import '../model/types.dart';
import 'theme.dart';

class VirtualCoursePage extends StatefulWidget {
  final BackupBundle bundle;
  final Course course;
  final ValueChanged<BackupBundle> onChanged;
  final String wallpaperPath;
  final String wallpaperFocus;

  const VirtualCoursePage({
    super.key,
    required this.bundle,
    required this.course,
    required this.onChanged,
    this.wallpaperPath = '',
    this.wallpaperFocus = '0,0,1',
  });

  @override
  State<VirtualCoursePage> createState() => _VirtualCoursePageState();
}

class _VirtualCoursePageState extends State<VirtualCoursePage> {
  late BackupBundle _b = widget.bundle;

  List<VirtualLesson> get _lessons {
    final out = _b.lessons.where((l) => l.courseId == widget.course.id).toList();
    out.sort((a, b) => a.seq - b.seq);
    return out;
  }

  int get _doneCount => _lessons.where((l) => l.done).length;

  int _durationOf(VirtualLesson l) {
    final raw = l.durationMin > 0 ? l.durationMin : widget.course.lessonDurationMin;
    final rounded = (raw / 5).round() * 5;
    return rounded.clamp(15, 200);
  }

  List<PlanBlock> _blocksOf(VirtualLesson l) {
    final out = _b.blocks.where((b) => b.lessonId == l.id).toList();
    out.sort((a, b) {
      final c = a.date.compareTo(b.date);
      return c != 0 ? c : a.startMin - b.startMin;
    });
    return out;
  }

  BackupBundle _copy({
    List<Todo>? todos,
    List<PlanBlock>? blocks,
    List<VirtualLesson>? lessons,
  }) =>
      BackupBundle(
        app: _b.app,
        version: _b.version,
        exportedAt: _b.exportedAt,
        semesters: _b.semesters,
        sectionTimes: _b.sectionTimes,
        courses: _b.courses,
        rules: _b.rules,
        overrides: _b.overrides,
        todos: todos ?? _b.todos,
        blocks: blocks ?? _b.blocks,
        restWindows: _b.restWindows,
        templates: _b.templates,
        lessons: lessons ?? _b.lessons,
      );

  void _apply(BackupBundle next) {
    setState(() => _b = next);
    widget.onChanged(next);
  }

  Future<void> _toggle(VirtualLesson l) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    var lessons = _b.lessons
        .map((x) => x.id == l.id
            ? VirtualLesson(
                id: x.id,
                courseId: x.courseId,
                seq: x.seq,
                title: x.title,
                durationMin: x.durationMin,
                done: !x.done,
                doneAt: x.done ? 0 : now,
              )
            : x)
        .toList();
    final blocks = _blocksOf(l);
    var nextBlocks = _b.blocks;
    var todos = _b.todos;
    if (!l.done) {
      if (blocks.isNotEmpty) {
        final first = blocks.first;
        nextBlocks = _b.blocks
            .map((b) => b.lessonId == l.id
                ? PlanBlock(
                    id: b.id,
                    todoId: b.todoId,
                    lessonId: b.lessonId,
                    date: b.date,
                    startMin: b.startMin,
                    endMin: b.endMin,
                    done: true,
                  )
                : b)
            .toList();
        final sem = _b.semester;
        if (sem != null) {
          final end = first.startMin + _durationOf(l);
          final out = generateForLesson(
            courses: _b.courses,
            rules: _b.rules,
            times: _b.sectionTimes,
            templates: _b.templates,
            todos: todos,
            sem: sem,
            lesson: l,
            date: first.date,
            startMin: first.startMin,
            endMin: end,
            nextId: todos.fold(0, (m, t) => t.id > m ? t.id : m),
          );
          todos = [...todos, ...out.created];
        }
      } else {
        // 没排课：用当前时间 + 这一讲时长生成待办，不补计划块（鸿蒙同款）
        final sem = _b.semester;
        if (sem != null) {
          final d = today();
          final nowMin = DateTime.now().hour * 60 + DateTime.now().minute;
          final start = ((nowMin + 4) ~/ 5) * 5;
          final out = generateForLesson(
            courses: _b.courses,
            rules: _b.rules,
            times: _b.sectionTimes,
            templates: _b.templates,
            todos: todos,
            sem: sem,
            lesson: l,
            date: formatDate(d),
            startMin: start,
            endMin: start + _durationOf(l),
            nextId: todos.fold(0, (m, t) => t.id > m ? t.id : m),
          );
          todos = [...todos, ...out.created];
        }
      }
    } else {
      nextBlocks = _b.blocks
          .map((b) => b.lessonId == l.id
              ? PlanBlock(
                  id: b.id,
                  todoId: b.todoId,
                  lessonId: b.lessonId,
                  date: b.date,
                  startMin: b.startMin,
                  endMin: b.endMin,
                  done: false,
                )
              : b)
          .toList();
    }
    _apply(_copy(todos: todos, blocks: nextBlocks, lessons: lessons));
  }

  Future<void> _edit(VirtualLesson l) async {
    final nameCtl = TextEditingController(text: l.title);
    var duration = _durationOf(l);
    var durationChanged = false;
    var error = '';
    final saved = await showGeneralDialog<bool>(
      context: context,
      barrierDismissible: true,
      barrierLabel: '',
      barrierColor: Colors.black45,
      transitionDuration: dur(300),
      pageBuilder: (ctx, _, __) => Align(
        alignment: Alignment.centerRight,
        child: SafeArea(
          child: Material(
            color: Colors.transparent,
            child: FractionallySizedBox(
            widthFactor: 0.86,
            heightFactor: 1,
            child: StatefulBuilder(
        builder: (ctx, setLocal) => Padding(
          padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
          child: Container(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
            decoration: const BoxDecoration(
              color: Color(0xF20E1420),
              borderRadius: BorderRadius.horizontal(left: Radius.circular(22)),
              border: Border(left: BorderSide(color: glassEdgeSoft)),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Expanded(
                        child: Text('编辑课时',
                            style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.w700,
                                color: inkPrimary))),
                    IconButton(
                        onPressed: () => Navigator.pop(ctx),
                        icon: const Icon(Icons.close, color: inkSecondary)),
                  ],
                ),
                const Text('课时名称',
                    style: TextStyle(fontSize: 12, color: inkTertiary)),
                TextField(
                  controller: nameCtl,
                  style: const TextStyle(color: inkPrimary, fontSize: 16),
                  decoration: InputDecoration(
                    hintText: '留空则用课程简称 + 第几讲',
                    hintStyle: const TextStyle(color: inkTertiary),
                    filled: true,
                    fillColor: glassTintRow,
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: BorderSide(color: glassEdgeSoft)),
                  ),
                ),
                const SizedBox(height: 14),
                const Text('这一讲时长',
                    style: TextStyle(fontSize: 12, color: inkTertiary)),
                Text('$duration 分钟',
                    style: const TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w600,
                        color: inkPrimary)),
                Slider(
                  value: duration.toDouble(),
                  min: 15,
                  max: 200,
                  divisions: 37,
                  label: '$duration',
                  activeColor: const Color(0xFF2E6BE6),
                  inactiveColor: Colors.white.withValues(alpha: 0.16),
                  thumbColor: const Color(0xFF7FA8FF),
                  onChanged: (v) => setLocal(() {
                    duration = (v / 5).round() * 5;
                    durationChanged = true;
                  }),
                ),
                Text(
                  l.durationMin > 0
                      ? '当前这一讲单独设了 ${_durationOf(l)} 分钟；课程默认 ${widget.course.lessonDurationMin} 分钟'
                      : '当前跟随课程默认 ${widget.course.lessonDurationMin} 分钟',
                  style: const TextStyle(fontSize: 11, color: inkTertiary),
                ),
                if (error.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(error,
                        style: const TextStyle(
                            fontSize: 12, color: dangerRed)),
                  ),
                const SizedBox(height: 14),
                Row(
                  children: [
                    TextButton(
                      onPressed: () async {
                        final ok = await showDialog<bool>(
                          context: ctx,
                          builder: (dctx) => AlertDialog(
                            backgroundColor: const Color(0xFF141C2B),
                            title: const Text('删除这一讲？',
                                style: TextStyle(color: inkPrimary)),
                            content: const Text(
                                '这一讲和它的计划块会删除；已经生成的待办会保留。',
                                style: TextStyle(color: inkSecondary)),
                            actions: [
                              TextButton(
                                  onPressed: () =>
                                      Navigator.pop(dctx, false),
                                  child: const Text('取消')),
                              TextButton(
                                  onPressed: () => Navigator.pop(dctx, true),
                                  child: const Text('删除',
                                      style:
                                          TextStyle(color: dangerRed))),
                            ],
                          ),
                        );
                        if (ok == true && ctx.mounted) {
                          _deleteLesson(l);
                          Navigator.pop(ctx, false);
                        }
                      },
                      child: const Text('删除这一讲',
                          style: TextStyle(color: dangerRed)),
                    ),
                    const Spacer(),
                    FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFF2E6BE6),
                        foregroundColor: Colors.white,
                        shape: const StadiumBorder(),
                      ),
                      onPressed: () {
                        final blocks = _blocksOf(l);
                        for (final b in blocks) {
                          if (b.startMin + duration > 1440) {
                            setLocal(() => error = '超过 24:00 了，先把开始时间挪早一点');
                            return;
                          }
                        }
                        _saveLesson(
                            l, nameCtl.text.trim(), duration, durationChanged);
                        Navigator.pop(ctx, true);
                      },
                      child: const Text('保存'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
          ),
        ),
      ),
      ),
      ),
      transitionBuilder: (ctx, animation, _, child) => SlideTransition(
        position: Tween<Offset>(
                begin: const Offset(1, 0), end: Offset.zero)
            .animate(CurvedAnimation(
                parent: animation, curve: curveOr(drawerCurve))),
        child: child,
      ),
    );
    nameCtl.dispose();
    if (saved == true) setState(() {});
  }

  void _saveLesson(
      VirtualLesson l, String name, int duration, bool durationChanged) {
    final lessons = _b.lessons
        .map((x) => x.id == l.id
            ? VirtualLesson(
                id: x.id,
                courseId: x.courseId,
                seq: x.seq,
                title: name,
                // 没动滑条就保留原来的“跟随/覆盖”状态，不强行写死
                durationMin: durationChanged ? duration : x.durationMin,
                done: x.done,
                doneAt: x.doneAt,
              )
            : x)
        .toList();
    final blocks = durationChanged
        ? _b.blocks
            .map((b) => b.lessonId == l.id
                ? PlanBlock(
                    id: b.id,
                    todoId: b.todoId,
                    lessonId: b.lessonId,
                    date: b.date,
                    startMin: b.startMin,
                    endMin: b.startMin + duration,
                    done: b.done,
                  )
                : b)
            .toList()
        : _b.blocks;
    _apply(_copy(lessons: lessons, blocks: blocks));
  }

  void _deleteLesson(VirtualLesson l) {
    final lessons = _b.lessons.where((x) => x.id != l.id).toList();
    final blocks = _b.blocks.where((b) => b.lessonId != l.id).toList();
    _apply(_copy(lessons: lessons, blocks: blocks));
  }

  @override
  Widget build(BuildContext context) {
    final lessons = _lessons;
    final hasWallpaper =
        widget.wallpaperPath.isNotEmpty && File(widget.wallpaperPath).existsSync();
    return Scaffold(
      backgroundColor: const Color(0xFF0E1420),
      body: Container(
        decoration: const BoxDecoration(gradient: pageGradient),
        child: Stack(
          children: [
            if (hasWallpaper)
              Positioned.fill(
                child: WallpaperImage(
                    path: widget.wallpaperPath, focus: widget.wallpaperFocus),
              ),
            if (hasWallpaper)
              const Positioned.fill(
                child: ColoredBox(color: Color(0x9E060810)),
              ),
            SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 6),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: glassTintPanel,
                  borderRadius: BorderRadius.circular(glassRadius),
                  border: Border.all(color: glassEdgeStrong),
                  boxShadow: glassShadowSheet,
                ),
                child: Row(
                  children: [
                    GestureDetector(
                      onTap: () => Navigator.pop(context),
                      behavior: HitTestBehavior.opaque,
                      child: const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 4),
                        child: Row(
                          children: [
                            Icon(Icons.chevron_left, color: accentBlue, size: 20),
                            Text('返回',
                                style: TextStyle(
                                    fontSize: 14, color: accentBlue)),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(widget.course.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.w700,
                              color: inkPrimary)),
                    ),
                    Text('$_doneCount / ${lessons.length} 讲',
                        style: const TextStyle(
                            fontSize: 12, color: inkSecondary)),
                  ],
                ),
              ),
            ),
            Expanded(
              child: ListView.separated(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                itemCount: lessons.length,
                separatorBuilder: (_, __) => const SizedBox(height: 8),
                itemBuilder: (_, i) {
                  final l = lessons[i];
                  final blocks = _blocksOf(l);
                  final schedule = blocks.isEmpty
                      ? '未排'
                      : '${blocks.first.date.substring(5)} ${_hhmm(blocks.first.startMin)}';
                  return GestureDetector(
                    onTap: () => _edit(l),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 12),
                      decoration: BoxDecoration(
                        color: glassTintRow,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: glassEdgeSoft),
                        boxShadow: glassShadowRow,
                      ),
                      child: Row(
                        children: [
                          InkWell(
                            onTap: () => _toggle(l),
                            customBorder: const CircleBorder(),
                            child: Padding(
                              padding: const EdgeInsets.all(4),
                              child: Icon(
                                l.done
                                    ? Icons.check
                                    : Icons.radio_button_unchecked,
                                size: 20,
                                color: l.done ? inkTertiary : inkPrimary,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  lessonTitleOf(l, _b.courses),
                                  style: TextStyle(
                                    fontSize: 15,
                                    color: l.done ? inkTertiary : inkPrimary,
                                    decoration: l.done
                                        ? TextDecoration.lineThrough
                                        : null,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  '$schedule · ${_durationOf(l)} 分钟',
                                  style: const TextStyle(
                                      fontSize: 11, color: inkTertiary),
                                ),
                              ],
                            ),
                          ),
                          const Icon(Icons.chevron_right,
                              size: 18, color: inkTertiary),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
            ),
          ],
        ),
      ),
    );
  }

  String _hhmm(int min) =>
      '${(min ~/ 60).toString().padLeft(2, '0')}:${(min % 60).toString().padLeft(2, '0')}';
}
