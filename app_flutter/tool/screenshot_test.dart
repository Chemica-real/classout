// 截图生成器（**不在默认 `flutter test` 里跑**，因为 golden 依平台字体）。
//
//   flutter test --update-goldens tool/screenshot_test.dart
//   → tool/goldens/{timetable,todos}.png
//
// 用途：在没装 Chrome、没有 Mac 的 Linux 上也能"看见"界面长什么样。
// ⚠️ flutter_test 默认字体没有中文、也没有 Material 图标（全渲染成豆腐块），
//    所以这里手动加载系统里的中文字体 + SDK 里的 MaterialIcons。

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FontLoader;
import 'package:flutter_test/flutter_test.dart';

import 'package:classout/data/backup.dart';
import 'package:classout/ui/app_frame.dart';
import 'package:classout/ui/timetable_page.dart';
import 'package:classout/data/settings.dart';
import 'package:classout/ui/backup_picker.dart';
import 'package:classout/ui/import_dialog.dart';
import 'package:classout/ui/plan_page.dart';
import 'package:classout/ui/settings_page.dart';
import 'package:classout/ui/todo_page.dart';

const _cjkCandidates = <String>[
  '/usr/share/fonts/truetype/wqy/wqy-zenhei.ttc',
  '/usr/share/fonts/truetype/arphic/uming.ttc',
];

Future<void> _loadFont(String family, String path) async {
  final f = File(path);
  if (!f.existsSync()) return;
  try {
    final bytes = f.readAsBytesSync();
    final loader = FontLoader(family)
      ..addFont(Future<ByteData>.value(ByteData.view(bytes.buffer)));
    await loader.load();
  } catch (_) {
    // 不支持的字体格式就跳过（界面会显示豆腐块，但不影响布局检查）
  }
}

Future<String?> _loadFonts() async {
  const iconCandidates = <String>[
    '/home/chemica/ChemicaWorkspace/toolchain/flutter-sdk/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
  ];
  for (final p in iconCandidates) {
    await _loadFont('MaterialIcons', p);
  }
  for (final p in _cjkCandidates) {
    if (File(p).existsSync()) {
      await _loadFont('CJK', p);
      return 'CJK';
    }
  }
  return null;
}

Future<void> _shot(WidgetTester tester, Widget page, String name, String? family) async {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: ThemeData(brightness: Brightness.dark, useMaterial3: true, fontFamily: family),
    home: Scaffold(body: AppFrame(tab: name == 'todos' ? 1 : (name == 'plan' ? 2 : (name == 'settings' ? 3 : 0)), onTab: (_) {}, child: page)),
  ));
  await tester.pumpAndSettle();
  await expectLater(
      find.byType(AppFrame), matchesGoldenFile('goldens/$name.png'));
}

/// 假的选文件实现（截图只用来看界面，不会真弹文件框）
class _NoopPicker implements BackupPicker {
  const _NoopPicker();
  @override
  Future<String?> pickBackupText() async => null;
}

void main() {
  final demo = BackupBundle.decode(File('assets/demo_backup.json').readAsStringSync());

  testWidgets('课表页截图', (tester) async {
    final family = await _loadFonts();
    await _shot(
      tester,
      TimetablePage(bundle: demo, onImport: () async {}),
      'timetable',
      family,
    );
  });

  testWidgets('待办页截图', (tester) async {
    final family = await _loadFonts();
    await _shot(
      tester,
      TodoPage(bundle: demo, onChanged: (_) {}),
      'todos',
      family,
    );
  });

  testWidgets('设置页截图', (tester) async {
    final family = await _loadFonts();
    await _shot(
      tester,
      SettingsPage(
        bundle: demo,
        onChanged: (_) {},
        settings: AppSettings(syncIntervalMin: 10),
        onSettingsChanged: (_) {},
      ),
      'settings',
      family,
    );
  });

  testWidgets('导入备份弹窗截图', (tester) async {
    final family = await _loadFonts();
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    final nav = GlobalKey<NavigatorState>();
    await tester.pumpWidget(MaterialApp(
      navigatorKey: nav,
      debugShowCheckedModeBanner: false,
      theme: ThemeData(brightness: Brightness.dark, useMaterial3: true, fontFamily: family),
      home: Scaffold(body: AppFrame(tab: 0, onTab: (_) {}, child: const SizedBox.expand())),
    ));
    await tester.pumpAndSettle();
    // 直接在这个 navigator 上弹导入框
    final fut = showImportDialog(nav.currentContext!, picker: const _NoopPicker());
    await tester.pumpAndSettle();
    await expectLater(find.byType(Dialog), matchesGoldenFile('goldens/import_dialog.png'));
    Navigator.of(nav.currentContext!).pop();
    await fut;
  });

  testWidgets('计划页截图（三日视图，从周五开始）', (tester) async {
    final family = await _loadFonts();
    await _shot(
      tester,
      PlanPage(
        bundle: demo,
        onChanged: (_) {},
        initialDay: DateTime(2026, 10, 16),
        initialThreeDay: true,
      ),
      'plan',
      family,
    );
  });
}
