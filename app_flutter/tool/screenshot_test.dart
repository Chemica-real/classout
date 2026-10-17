// 截图生成器（**不在默认 `flutter test` 里跑**，因为 golden 依平台字体）。
//
//   flutter test --update-goldens tool/screenshot_test.dart
//   → tool/goldens/timetable.png
//
// 用途：在没装 Chrome、没有 Mac 的 Linux 上也能"看见"界面长什么样。
// ⚠️ flutter_test 默认的测试字体没有中文（全渲染成豆腐块），所以这里手动加载
//    系统里的中文字体（WenQuanYi / AR PL / Noto CJK 任一个）。

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FontLoader;
import 'package:flutter_test/flutter_test.dart';

import 'package:classout/data/backup.dart';
import 'package:classout/ui/timetable_page.dart';

const _cjkCandidates = <String>[
  '/usr/share/fonts/truetype/wqy/wqy-zenhei.ttc',
  '/usr/share/fonts/truetype/arphic/uming.ttc',
  '/usr/share/fonts/opentype/noto/NotoSerifCJK-Regular.ttc',
];

/// 图标字体：golden 测试里 Icons.* 也会渲染成豆腐块，这里手动装一下
Future<void> _loadIcons() async {
  final f = File('/home/chemica/ChemicaWorkspace/toolchain/flutter-sdk/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf');
  if (!f.existsSync()) return;
  try {
    final bytes = f.readAsBytesSync();
    final loader = FontLoader('MaterialIcons')
      ..addFont(Future<ByteData>.value(ByteData.view(bytes.buffer)));
    await loader.load();
  } catch (_) {}
}

Future<String?> _loadCjk() async {
  for (final path in _cjkCandidates) {
    final f = File(path);
    if (!f.existsSync()) continue;
    try {
      final bytes = f.readAsBytesSync();
      final loader = FontLoader('CJK')
        ..addFont(Future<ByteData>.value(ByteData.view(bytes.buffer)));
      await loader.load();
      return 'CJK';
    } catch (_) {
      // .ttc 可能不被支持，换下一个
    }
  }
  return null;
}

void main() {
  testWidgets('课表页截图', (tester) async {
    await _loadIcons();
    final family = await _loadCjk();
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    final bundle = BackupBundle.decode(File('assets/demo_backup.json').readAsStringSync());
    await tester.pumpWidget(MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        useMaterial3: true,
        fontFamily: family,
      ),
      home: TimetablePage(bundle: bundle),
    ));
    await tester.pumpAndSettle();

    await expectLater(
      find.byType(TimetablePage),
      matchesGoldenFile('goldens/timetable.png'),
    );
  });
}
