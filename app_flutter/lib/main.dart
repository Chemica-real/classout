// ClassOUT（iOS / Android）—— 第二版：备份 JSON → 本地仓库 → 周课表。
//
// 数据流：assets/demo_backup.json（空库时兜底）→ ClassOutRepo → 各页面；
// 页头「导入」可以把一份备份 JSON 粘进来替换全部数据。
// 仓库实现按平台自动选（data/repo_factory.dart）：
//   web   → MemoryRepo（刷新即回到演示数据）
//   原生  → SqliteRepo（App 数据目录下的 classout.db，schema 来自 assets/schema.sql）

import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;

import 'data/backup.dart';
import 'data/repo.dart';
import 'data/repo_factory.dart';
import 'ui/home_shell.dart';

void main() => runApp(const ClassOutApp());

class ClassOutApp extends StatelessWidget {
  const ClassOutApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ClassOUT',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        useMaterial3: true,
        // web 端必须自带中文字体（否则 CanvasKit 会去 fonts.gstatic.com 找兜底字体，
        // 国内网络基本连不上 → 满屏豆腐块）。原生端用系统字体更好，所以只在 web 用。
        fontFamily: kIsWeb ? 'ClassOutCJK' : null,
      ),
      home: const _Boot(),
    );
  }
}

class _Boot extends StatefulWidget {
  const _Boot();

  @override
  State<_Boot> createState() => _BootState();
}

class _BootState extends State<_Boot> {
  Future<(ClassOutRepo, BackupBundle)>? _future;

  @override
  void initState() {
    super.initState();
    _future = () async {
      try {
        final repo = await openRepo();
        // --- 给 CI 看的自检日志（GitHub Actions 里 grep 这几行判断真跑起来了）---
        debugPrint('[ClassOUT] db opened');
        final demo =
            BackupBundle.decode(await rootBundle.loadString('assets/demo_backup.json'));
        debugPrint('[ClassOUT] demo bundle ok: courses=${demo.courses.length}');
        return (repo, demo);
      } catch (e) {
        debugPrint('[ClassOUT] boot error: $e');
        rethrow;
      }
    }();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<(ClassOutRepo, BackupBundle)>(
      future: _future,
      builder: (context, snap) {
        if (snap.hasError) {
          debugPrint('[ClassOUT] boot failed: ${snap.error}');
          return Scaffold(
            body: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text('读不出演示数据：\n${snap.error}', textAlign: TextAlign.center),
              ),
            ),
          );
        }
        if (!snap.hasData) {
          return const Scaffold(body: Center(child: CircularProgressIndicator()));
        }
        final (repo, demo) = snap.data!;
        return HomeShell(repo: repo, fallback: demo);
      },
    );
  }
}
