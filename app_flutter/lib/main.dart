// ClassOUT（iOS / Android）—— 第一版：备份 JSON → 周课表。
//
// 现在数据来自打包进来的演示备份（assets/demo_backup.json）；
// 下一步是「从文件导入用户的备份」+ 接本地数据库（schema 见 ../shared/schema.sql）。

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;

import 'data/backup.dart';
import 'ui/timetable_page.dart';

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
        return TimetablePage(bundle: snap.data!);
      },
    );
  }
}
