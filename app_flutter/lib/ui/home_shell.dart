// 应用外壳：负责「读数据 → 画界面 → 导入后重画」。
// 数据仓库是注入的，所以 web 用内存版、原生用 SQLite 版都能跑同一套 UI。

import 'package:flutter/material.dart';

import '../data/backup.dart';
import '../data/repo.dart';
import '../data/settings.dart';
import '../domain/reminders.dart';
import '../domain/dates.dart';
import '../domain/motto.dart';
import '../domain/timetable.dart';
import '../domain/todo_generator.dart';
import '../notify/flutter_notifier.dart';
import '../notify/notifier.dart';
import '../notify/scheduler.dart';
import 'app_frame.dart';
import 'backup_picker.dart';
import 'import_dialog.dart';
import 'palette.dart';
import 'plan_page.dart';
import 'settings_page.dart';
import 'boot_screen.dart';
import 'course_header.dart';
import 'course_manager.dart';
import 'session_sheet.dart';
import 'theme.dart' as theme;
import 'timetable_page.dart';
import 'todo_page.dart';

class HomeShell extends StatefulWidget {
  final ClassOutRepo repo;

  /// 库是空的时，用这份兜底数据（演示版就是这么起来的）
  final BackupBundle? fallback;

  /// 通知实现（默认真实插件；测试可注入 FakeNotifier）
  final ReminderNotifier? notifier;

  /// 「从文件选备份」的实现（默认真实 file_picker；测试可注入假实现）
  final BackupPicker? backupPicker;

  const HomeShell({
    super.key,
    required this.repo,
    this.fallback,
    this.notifier,
    this.backupPicker,
  });

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  BackupBundle? _bundle;
  AppSettings _settings = AppSettings();
  bool _loading = true;
  String? _error;
  int _tab = 0;
  bool _syncing = false;

  /// 启动清单走到第几步（0..4），见 boot_screen.dart 的 bootSteps
  int _bootStep = 0;
  bool _bootReady = false;

  /// 过场层是否还在（true = 显示加载页/小球）
  bool _bootVisible = true;

  /// 悬浮页头的实测高度（课表/待办页据此在滚动内容顶部留白）
  double _headerH = 134;

  /// 当前周次（页头 ‹ › 改它；课表页照着画）
  int _week = 1;
  late final ReminderNotifier _notifier = widget.notifier ?? FlutterNotifier();

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    setState(() {
      _loading = true;
      _bootStep = 0;
      _bootReady = false;
      _bootVisible = true;
    });
    try {
      final settings = await AppSettings.load(widget.repo);
      var data = await widget.repo.load();
      if (data == null && widget.fallback != null) {
        await widget.repo.replaceAll(widget.fallback!);
        data = await widget.repo.load();
      }
      // CI 自检：这一行出现 = 数据层真的读通了
      debugPrint('[ClassOUT] loaded: courses=${data?.courses.length} '
          'todos=${data?.todos.length} rules=${data?.rules.length}');
      // 动画总开关是"内存态"（鸿蒙端 AppStorage('motionOn')）：读库后立刻生效
      theme.motionOn = settings.motionEnabled;
      if (!mounted) return;
      setState(() {
        _bundle = data;
        _settings = settings;
        _loading = false;
        _error = null;
        _bootStep = 1;
        final sem = data?.semester;
        if (sem != null) {
          _week = weekOfDate(sem, DateTime.now()).clamp(1, sem.totalWeeks);
        }
      });
      // 打开 App 时静默补生成「已经下课」的待办（鸿蒙端 generateMissedTodos）
      if (data != null) {
        setState(() => _bootStep = 2);
        await _generateMissed(data);
      }
      // 提醒同步这一步没有真实工作（排提醒是用户手动/定时触发的），只让清单走完
      if (!mounted) return;
      setState(() => _bootStep = 3);
      // 「人为放慢」只在真机生效；测试里不等，免得留下未完成的定时器
      if (ambientMotion) await Future<void>.delayed(dur(bootStepMs));
      if (!mounted) return;
      setState(() {
        _bootStep = 4;
        _bootReady = true;
      });
    } catch (e) {
      debugPrint('[ClassOUT] load error: $e');
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  /// 页面改了数据（勾完成/新建待办…）：先更新界面，再整份写回仓库
  Future<void> _apply(BackupBundle next) async {
    setState(() => _bundle = next);
    await widget.repo.replaceAll(next);
  }

  /// 立即重排提醒：算出计划 → 交给系统通知 → 返回一句人话
  Future<String> _resyncReminders() async {
    final bundle = _bundle;
    if (bundle == null || bundle.semester == null) return '还没有课表，无法排提醒';
    final sem = bundle.semester!;
    final plan = planReminders(
      sem: sem,
      courses: bundle.courses,
      rules: bundle.rules,
      times: bundle.sectionTimes,
      overrides: bundle.overrides,
      todos: bundle.todos.where((t) => t.status == 'active').toList(),
      blocks: bundle.blocks,
      settings: _settings.reminderSettings,
      now: DateTime.now(),
    );
    try {
      final r = await syncNotifications(_notifier, plan);
      if (!r.granted) return '没有通知权限，提醒没排上（去系统设置里开一下）';
      final extra =
          r.skippedByBudget > 0 ? '，另有 ${r.skippedByBudget} 条超出额度' : '';
      return '已排 ${r.scheduled} 条提醒（系统待发 ${r.pending} 条）$extra';
    } catch (e) {
      return '排提醒失败：$e';
    }
  }

  Widget _header(BackupBundle bundle) => CourseHeader(
        sem: bundle.semester,
        week: _week,
        adjustCount: _adjustCount(bundle),
        onPrev: () => setState(() => _week = (_week - 1).clamp(1, _totalWeeks)),
        onNext: () => setState(() => _week = (_week + 1).clamp(1, _totalWeeks)),
        onToday: () => setState(() => _week =
            weekOfDate(bundle.semester!, DateTime.now()).clamp(1, _totalWeeks)),
        onSync: _manualSync,
        onExtra: () => showExtraSheet(context,
            bundle: bundle, week: _week, onChanged: _apply),
        onManage: () =>
            showCourseManager(context, bundle: bundle, onChanged: _apply),
        onOpenAdjust: () =>
            showAdjustSheet(context, bundle: bundle, onChanged: _apply),
      );

  int get _totalWeeks => _bundle?.semester?.totalWeeks ?? 1;

  /// 本周有几条单周调整（页头的「本周调整 N」；没有就不显示）
  int _adjustCount(BackupBundle bundle) {
    final sem = bundle.semester;
    if (sem == null) return 0;
    final dates = {
      for (var d = 1; d <= 7; d++) formatDate(dateOfWeekday(sem, _week, d)),
    };
    return bundle.overrides
        .where((o) => dates.contains(o.newDate) || dates.contains(o.date))
        .length;
  }

  /// 下课自动生成待办：把 last_gen_date 到现在之间已经下课的课时，
  /// 按课程模板生成「待确认」待办（去重键 course|date|template，见 domain/todo_generator.dart）
  Future<void> _generateMissed(BackupBundle data) async {
    final sem = data.semester;
    if (sem == null || data.templates.isEmpty) return;
    final last = await widget.repo.getKv('last_gen_date') ?? '';
    final outcome = generateMissedTodos(
      sem: sem,
      courses: data.courses,
      rules: data.rules,
      overrides: data.overrides,
      times: data.sectionTimes,
      templates: data.templates,
      todos: data.todos,
      lastGenDate: last,
      now: DateTime.now(),
      nextId: data.todos.fold<int>(0, (m, t) => t.id > m ? t.id : m),
    );
    await widget.repo.setKv('last_gen_date', outcome.lastGenDate);
    if (outcome.created.isEmpty || !mounted) return;
    setState(() {
      _bundle = BackupBundle(
        app: data.app,
        version: data.version,
        exportedAt: data.exportedAt,
        semesters: data.semesters,
        sectionTimes: data.sectionTimes,
        courses: data.courses,
        rules: data.rules,
        overrides: data.overrides,
        todos: [...data.todos, ...outcome.created],
        blocks: data.blocks,
        restWindows: data.restWindows,
        templates: data.templates,
      );
    });
    await widget.repo.replaceAll(_bundle!);
  }

  Future<void> _manualSync() async {
    if (_syncing) return;
    setState(() => _syncing = true);
    // 让「正在与日历同步」至少露一下脸（真机上重排可能几毫秒就完事）
    await Future<void>.delayed(const Duration(milliseconds: 700));
    final msg = await _resyncReminders();
    if (!mounted) return;
    setState(() => _syncing = false);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _applySettings(AppSettings next) async {
    setState(() => _settings = next);
    await next.save(widget.repo);
  }

  Future<void> _import() async {
    final bundle = await showImportDialog(context, picker: widget.backupPicker);
    if (bundle == null) return;
    await widget.repo.replaceAll(bundle);
    await _reload();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已导入：${bundle.semester?.name ?? ''}')),
    );
  }

  @override
  Widget build(BuildContext context) {
    // 测试/截图（ambientMotion=false）不播启动流程：直接给应用本体
    if (!ambientMotion) return _buildApp(context);
    return Stack(
      children: [
        Positioned.fill(child: _buildApp(context)),
        if (_bootVisible)
          Positioned.fill(
            child: BootScreen(
              step: _bootStep,
              motto: normalMotto(_settings.motto),
              ready: _bootReady,
              onReveal: () {}, // 应用本体一直挂在下层，扩张时自然露出
              onDone: () {
                if (mounted) setState(() => _bootVisible = false);
              },
            ),
          ),
      ],
    );
  }

  Widget _buildApp(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (_error != null) {
      return Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text('读数据出错：\n$_error', textAlign: TextAlign.center),
          ),
        ),
      );
    }
    final bundle = _bundle;
    if (bundle == null || bundle.semester == null) {
      return Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: const [
              Text('还没有课表', style: TextStyle(fontSize: 18, color: inkPrimary)),
              SizedBox(height: 8),
              Text('用右上角的「导入」把备份粘进来',
                  style: TextStyle(fontSize: 12, color: inkTertiary)),
            ],
          ),
        ),
      );
    }
    return Scaffold(
      body: Stack(
        children: [
          Positioned.fill(
            child: AppFrame(
              tab: _tab,
              onTab: (i) {
                final was = _tab;
                setState(() => _tab = i);
                // 用户 2026-10-16：「每次切换到待办列时，立即补生成下课列表」
                if (i == 1 && was != 1 && _bundle != null)
                  _generateMissed(_bundle!);
              },
              wallpaperPath: _settings.wallpaperPath,
              // 课表 / 待办 / 计划 三页共用同一条页头（鸿蒙端 FloatingBars），
              // 设置页没有它 —— 那些是课表页的导航控件。
              child: _tab == 3
                  ? SettingsPage(
                      bundle: bundle,
                      onChanged: _apply,
                      settings: _settings,
                      onSettingsChanged: _applySettings,
                      onResyncReminders: _resyncReminders,
                      onImport: _import)
                  : _tab == 2
                      // 计划页有自己的日期条，暂时仍用纵向排布
                      ? Column(
                          children: [
                            _header(bundle),
                            Expanded(
                              child: PlanPage(
                                  bundle: bundle,
                                  onChanged: _apply,
                                  window: _settings.planWindow,
                                  restWindows: bundle.restWindows),
                            ),
                          ],
                        )
                      // 课表 / 待办：页头是**悬浮浮窗**，内容从它下面滑过
                      : Stack(
                          children: [
                            Positioned.fill(
                              child: switch (_tab) {
                                0 => TimetablePage(
                                    bundle: bundle,
                                    week: _week,
                                    topInset: _headerH,
                                    onOpenSession: (s) => showSessionSheet(
                                        context,
                                        bundle: bundle,
                                        session: s,
                                        onChanged: _apply),
                                  ),
                                _ => TodoPage(
                                    bundle: bundle,
                                    onChanged: _apply,
                                    topInset: _headerH,
                                    customCategories:
                                        _settings.customCategories),
                              },
                            ),
                            Positioned(
                              left: 0,
                              right: 0,
                              top: 0,
                              child: MeasureSize(
                                onSize: (size) {
                                  if ((size.height - _headerH).abs() > 0.5) {
                                    setState(() => _headerH = size.height);
                                  }
                                },
                                child: _header(bundle),
                              ),
                            ),
                          ],
                        ),
            ),
          ),
          // 同步中：顶部一条玻璃提示（鸿蒙端也是"页面上方弹出同步提示"）
          if (_syncing)
            const Positioned(
              left: 0,
              right: 0,
              top: 0,
              child: SafeArea(
                child: Center(
                  child: Padding(
                    padding: EdgeInsets.only(top: 10),
                    child: Glass(
                      padding:
                          EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      child: Text('正在与日历同步…',
                          style: TextStyle(fontSize: 12, color: inkPrimary)),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
