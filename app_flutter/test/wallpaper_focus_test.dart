// 壁纸 focus（'dx,dy,zoom'）：解析/规范化 + 保存到 kv + 设置页按钮出现。

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:classout/data/backup.dart';
import 'package:classout/data/settings.dart';
import 'package:classout/ui/settings_page.dart';
import 'package:classout/domain/wallpaper.dart';
import 'package:classout/data/wallpaper.dart';
import 'package:classout/ui/wallpaper_view.dart';

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

  _wallpaperImageTests();
}

// 1x1 透明 PNG（够用：cover 只看比值，1:1 图填 360x800 → 800x800）
final List<int> _png1x1 = <int>[
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00,
  0x0A, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49,
  0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
];

Future<void> _pumpWallpaper(WidgetTester tester, String focus, String path) async {
  // 取景框就是屏幕：360x800（测试默认 800x600 会让 cover 算出别的尺寸）
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: Stack(children: [
        Positioned.fill(child: WallpaperImage(path: path, focus: focus)),
      ]),
    ),
  ));
  await tester.pumpAndSettle();
}

void _wallpaperImageTests() {
  testWidgets('WallpaperImage：按 geometry 摆图（1:1 图 → 800x800，fx=1 对齐左缘）',
      (tester) async {
    final tmp = File('${Directory.systemTemp.path}/wp_geom.png')
      ..writeAsBytesSync(_png1x1);
    addTearDown(() => tmp.deleteSync());

    // 先把图片尺寸写进缓存（真机上是异步解码；FakeAsync 下要先在 runAsync 里跑一次）
    await tester.runAsync(() => wallpaperImageSize(tmp.path));

    await _pumpWallpaper(tester, '0,0,1', tmp.path);
    var rect = tester.getRect(find.byType(Image));
    expect(rect.width, closeTo(800, 0.5));
    expect(rect.height, closeTo(800, 0.5));
    expect(rect.left, closeTo(-220, 0.5)); // 居中：(360-800)/2

    await _pumpWallpaper(tester, '1,0,1', tmp.path);
    rect = tester.getRect(find.byType(Image));
    expect(rect.left, closeTo(0, 0.5)); // fx=1 → 顶到右缘（左移 220）
  });
}
