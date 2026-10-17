// 壁纸几何（鸿蒙 `domain/Wallpaper.ets`）的测试：数值与鸿蒙 domain-check 逐条同值。

import 'package:flutter_test/flutter_test.dart';

import 'package:classout/domain/wallpaper.dart';

void main() {
  test('cover：1:1 图填 360x800 → 800x800，横向余量 220', () {
    final g = wallpaperGeometry(1000, 1000, 360, 800, 1, 0, 0);
    expect(g.w, 800);
    expect(g.h, 800);
    expect(g.maxDx, 220);
    expect(g.maxDy, 0);
    expect(g.dx, 0);
  });

  test('fx = ±1 挪到最右/最左；超界（2）被夹到 1', () {
    expect(wallpaperGeometry(1000, 1000, 360, 800, 1, 1, 0).dx, 220);
    expect(wallpaperGeometry(1000, 1000, 360, 800, 1, -1, 0).dx, -220);
    expect(wallpaperGeometry(1000, 1000, 360, 800, 1, 2, 0).dx, 220);
  });

  test('zoom 夹在 1..4：0.2 → 1（w=800），99 → 4（w=3200）', () {
    expect(wallpaperGeometry(1000, 1000, 360, 800, 0.2, 0, 0).w, 800);
    expect(wallpaperGeometry(1000, 1000, 360, 800, 99, 0, 0).w, 3200);
    expect(wallpaperMaxZoom, 4);
  });

  test('横图填竖屏：按宽铺满（2000x1000 → 1600x800）', () {
    final g = wallpaperGeometry(2000, 1000, 360, 800, 1, 0, 0);
    expect(g.w, 1600);
    expect(g.h, 800);
    expect(g.maxDx, 620);
    expect(g.maxDy, 0);
  });

  test('坏输入：图/框为 0 → 全 0，不抛', () {
    final g = wallpaperGeometry(0, 0, 360, 800, 1, 0, 0);
    expect(g.w, 0);
    expect(g.maxDx, 0);
    final g2 = wallpaperGeometry(100, 100, 0, 0, 1, 0, 0);
    expect(g2.h, 0);
  });

  test("焦点字符串：'0.5,-0.25,2' ↔ 解析/格式化互逆；坏数据回 (0,0,1)", () {
    final v = parseWallpaperFocus('0.5,-0.25,2');
    expect(v, [0.5, -0.25, 2]);
    expect(formatWallpaperFocus(v[0], v[1], v[2]), '0.5,-0.25,2');
    expect(parseWallpaperFocus(''), [0, 0, 1]);
    expect(parseWallpaperFocus('a,b,c'), [0, 0, 1]);
    expect(parseWallpaperFocus('0,0,99'), [0, 0, 4]);
    expect(parseWallpaperFocus('0,0,0.1'), [0, 0, 1]);
  });
}
