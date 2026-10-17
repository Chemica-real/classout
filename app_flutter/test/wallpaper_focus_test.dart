// 壁纸 focus（'dx,dy,zoom'）：解析/规范化 + 保存到 kv + 设置页按钮出现。

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:classout/data/backup.dart';
import 'package:classout/data/settings.dart';
import 'package:classout/ui/settings_page.dart';
import 'package:classout/domain/wallpaper.dart';

BackupBundle _demo() =>
    BackupBundle.decode(File('assets/demo_backup.json').readAsStringSync());

void main() {
  test('focus 解析：坏值回默认，zoom 夹在 1..4（鸿蒙 WALLPAPER_MAX_ZOOM）', () {
    expect(parseWallpaperFocus('0,0,1'), [0, 0, 1]);
    final f = parseWallpaperFocus('0.5,-0.25,2.5');
    expect(f[0], 0.5);
    expect(f[1], -0.25);
    expect(f[2], 2.5);
    expect(parseWallpaperFocus('乱写'), [0, 0, 1]);
    expect(parseWallpaperFocus('9,9,9')[0], 1);
    expect(parseWallpaperFocus('9,9,9')[2], 4);
    expect(parseWallpaperFocus('0,0,0.2')[2], 1);
    expect(formatWallpaperFocus(0.5, -0.25, 2), '0.5,-0.25,2');
  });

  testWidgets('有壁纸时背景卡出现「调整位置 / 区域」与「居中」，点居中写回 kv',
      (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    // 造一个存在的壁纸文件（AppFrame/Settings 的预览会用 File.existsSync）
    final tmp = File('${Directory.systemTemp.path}/wp_test.jpg')
      ..writeAsBytesSync(const [0xFF, 0xD8, 0xFF, 0xD9]);
    addTearDown(() => tmp.deleteSync());

    var settings = AppSettings(
        wallpaperPath: tmp.path, wallpaperFocus: '0.300,0.200,1.500');
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: StatefulBuilder(
          builder: (context, setState) => SettingsPage(
            bundle: _demo(),
            onChanged: (_) {},
            settings: settings,
            onSettingsChanged: (next) => setState(() => settings = next),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('调整位置 / 区域'), findsOneWidget);
    final center = find.byKey(const ValueKey('wp-center'));
    await tester.ensureVisible(center);
    await tester.pumpAndSettle();
    // 悬浮标题条可能压住目标：按 ScrollPosition 往下挪
    final pos =
        tester.state<ScrollableState>(find.byType(Scrollable).first).position;
    for (var i = 0; i < 6; i++) {
      if (tester.getRect(center).top > 90) break;
      pos.jumpTo((pos.pixels - 60).clamp(0.0, pos.maxScrollExtent));
      await tester.pumpAndSettle();
    }
    await tester.tap(center);
    await tester.pumpAndSettle();
    expect(settings.wallpaperFocus, '0,0,1');
  });
}
