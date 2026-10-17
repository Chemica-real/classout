// ClassOUT（iOS / Android）—— 第二版：备份 JSON → 本地仓库 → 周课表。
//
// 现在数据流：assets/demo_backup.json（兜底）→ ClassOutRepo → 课表页；
// 页头「导入」可以把一份备份 JSON 粘进来替换全部数据。
// 仓库实现：web 用 MemoryRepo，原生用 SqliteRepo（见 data/sqlite_repo.dart，
// 已在本机 Linux 上用真 SQLite 验过；原生接线还需要 path_provider 取 App 目录）。

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;

import 'data/backup.dart';
import 'data/repo.dart';
import 'ui/home_shell.dart';

void main() => runApp(const ClassOutApp());

class ClassOutApp extends StatelessWidget {
  const ClassOutApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ClassOUT',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(brightness: Brightness.dark, useMaterial3: true),
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
  Future<BackupBundle>? _future;

  @override
  void initState() {
    super.initState();
    _future = rootBundle
        .loadString('assets/demo_backup.json')
        .then(BackupBundle.decode);
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<BackupBundle>(
      future: _future,
      builder: (context, snap) {
        if (snap.hasError) {
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
        return HomeShell(repo: MemoryRepo(), fallback: snap.data!);
      },
    );
  }
}
