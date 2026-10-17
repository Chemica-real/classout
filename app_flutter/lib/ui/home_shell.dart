// 应用外壳：负责「读数据 → 画界面 → 导入后重画」。
// 数据仓库是注入的，所以 web 用内存版、原生用 SQLite 版都能跑同一套 UI。

import 'package:flutter/material.dart';

import '../data/backup.dart';
import '../data/repo.dart';
import 'app_frame.dart';
import 'import_dialog.dart';
import 'palette.dart';
import 'plan_page.dart';
import 'timetable_page.dart';
import 'todo_page.dart';

class HomeShell extends StatefulWidget {
  final ClassOutRepo repo;

  /// 库是空的时，用这份兜底数据（演示版就是这么起来的）
  final BackupBundle? fallback;

  const HomeShell({super.key, required this.repo, this.fallback});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  BackupBundle? _bundle;
  bool _loading = true;
  String? _error;
  int _tab = 0;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    setState(() => _loading = true);
    try {
      var data = await widget.repo.load();
      if (data == null && widget.fallback != null) {
        await widget.repo.replaceAll(widget.fallback!);
        data = await widget.repo.load();
      }
      if (!mounted) return;
      setState(() {
        _bundle = data;
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
          1 => TodoPage(bundle: bundle, onChanged: _apply),
          2 => PlanPage(bundle: bundle, onChanged: _apply),
          _ => const _ComingSoon('设置'),
        },
      ),
    );
  }
}

class _ComingSoon extends StatelessWidget {
  final String name;
  const _ComingSoon(this.name);

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(name, style: const TextStyle(fontSize: 22, color: inkPrimary)),
          const SizedBox(height: 6),
          const Text('还没做：正在按 待办 → 计划 → 设置 的顺序推进',
              style: TextStyle(fontSize: 12, color: inkTertiary)),
        ],
      ),
    );
  }
}
