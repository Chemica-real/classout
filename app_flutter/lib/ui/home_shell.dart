// 应用外壳：负责「读数据 → 画界面 → 导入后重画」。
// 数据仓库是注入的，所以 web 用内存版、原生用 SQLite 版都能跑同一套 UI。

import 'package:flutter/material.dart';

import '../data/backup.dart';
import '../data/repo.dart';
import '../data/settings.dart';
import '../domain/reminders.dart';
import '../notify/flutter_notifier.dart';
import '../notify/notifier.dart';
import '../notify/scheduler.dart';
import 'app_frame.dart';
import 'import_dialog.dart';
import 'palette.dart';
import 'plan_page.dart';
import 'settings_page.dart';
import 'timetable_page.dart';
import 'todo_page.dart';

class HomeShell extends StatefulWidget {
  final ClassOutRepo repo;

  /// 库是空的时，用这份兜底数据（演示版就是这么起来的）
  final BackupBundle? fallback;

  /// 通知实现（默认真实插件；测试可注入 FakeNotifier）
  final ReminderNotifier? notifier;

  const HomeShell({super.key, required this.repo, this.fallback, this.notifier});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  BackupBundle? _bundle;
  AppSettings _settings = AppSettings();
  bool _loading = true;
  String? _error;
  int _tab = 0;
  late final ReminderNotifier _notifier = widget.notifier ?? FlutterNotifier();

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    setState(() => _loading = true);
    try {
      final settings = await AppSettings.load(widget.repo);
      var data = await widget.repo.load();
      if (data == null && widget.fallback != null) {
        await widget.repo.replaceAll(widget.fallback!);
        data = await widget.repo.load();
      }
      if (!mounted) return;
      setState(() {
        _bundle = data;
        _settings = settings;
        _loading = false;
        _error = null;
      });
    } catch (e) {
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
      final extra = r.skippedByBudget > 0 ? '，另有 ${r.skippedByBudget} 条超出额度' : '';
      return '已排 ${r.scheduled} 条提醒（系统待发 ${r.pending} 条）$extra';
    } catch (e) {
      return '排提醒失败：$e';
    }
  }

  Future<void> _applySettings(AppSettings next) async {
    setState(() => _settings = next);
    await next.save(widget.repo);
  }

  Future<void> _import() async {
    final bundle = await showImportDialog(context);
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
      body: AppFrame(
        tab: _tab,
        onTab: (i) => setState(() => _tab = i),
        child: switch (_tab) {
          0 => TimetablePage(bundle: bundle, onImport: _import),
          1 => TodoPage(
              bundle: bundle,
              onChanged: _apply,
              customCategories: _settings.customCategories),
          2 => PlanPage(
              bundle: bundle,
              onChanged: _apply,
              window: _settings.planWindow,
              restWindows: bundle.restWindows),
          _ => SettingsPage(
              bundle: bundle,
              onChanged: _apply,
              settings: _settings,
              onSettingsChanged: _applySettings,
              onResyncReminders: _resyncReminders),
        },
      ),
    );
  }
}

