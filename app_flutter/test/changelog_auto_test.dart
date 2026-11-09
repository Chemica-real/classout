import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:classout/data/backup.dart';
import 'package:classout/data/repo.dart';
import 'package:classout/ui/home_shell.dart';

BackupBundle _demo() =>
    BackupBundle.decode(File('assets/demo_backup.json').readAsStringSync());

void main() {
  testWidgets('旧版本升级后自动弹更新日志', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    final repo = MemoryRepo(_demo());
    await repo.setKv('last_seen_version', '1.9.2');
    await tester.pumpWidget(
        MaterialApp(home: HomeShell(repo: repo, fallback: _demo())));
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    expect(find.textContaining('更新日志'), findsOneWidget);
    expect(find.text('开始使用'), findsOneWidget);
  });
}
