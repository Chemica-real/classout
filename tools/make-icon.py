#!/usr/bin/env python3
"""生成 ClassOUT 的应用图标（**完全自绘**：只有几何图形与渐变，不含任何第三方素材）。

为什么要留这个脚本（而不是扔一张 PNG 进仓库）：
  1. **上架要用"你自己拥有版权"的图标**（HANDOFF §22.6：原来那张是游戏角色素材，会被驳回）。
     脚本本身就是"这张图是我自己画的"的凭据 —— 图和脚本一起入库。
  2. 想换配色/圆角/格子数，改几个常量重跑即可，不用找设计文件。

用法：
    python3 tools/make-icon.py
会同时写：
    AppScope/resources/base/media/app_icon.png      （桌面图标）
    entry/src/main/resources/base/media/startIcon.png（启动图标）
两张图内容一致（和项目原来的做法一样）。
"""

import os

from PIL import Image, ImageDraw, ImageFilter

SIZE = 512

# 上架素材尺寸（AGC 要 1024×1024 的应用图标；216×216 用于部分展示位）。
# 不放大 512 的位图，而是**按比例重新画一遍** —— 放大出来的边缘会糊。
STORE_SIZES = (1024, 216)

# ---- 配色（取自 App 深色主题，见 view/Glass.ets 与 Types.COURSE_COLORS）----
BG_TOP = (36, 48, 74)        # #24304A 深蓝灰
BG_BOTTOM = (14, 20, 32)     # #0E1420 近黑
ACCENT_BLUE = (127, 168, 255)   # #7FA8FF 主色
ACCENT_PURPLE = (176, 139, 232)  # #B08BE8
ACCENT_TEAL = (79, 179, 165)     # #4FB3A5

# ---- 版式：3×3 的圆角格子 = 「课表」最直白的图形化 ----
COLS = 3
ROWS = 3
CELL = 92
GAP = 22
RADIUS = 22


def lerp(a, b, t):
    return tuple(round(a[i] + (b[i] - a[i]) * t) for i in range(3))


def blend(base, over, alpha):
    """把 over 以 alpha 叠在 base 上（over/alpha 都是 0..1 或 0..255）。"""
    return tuple(round(base[i] * (1 - alpha) + over[i] * alpha) for i in range(3))


def render(size: int) -> Image.Image:
    """按 size 画一张（几何全部按 size/512 等比缩放，不是放大位图）。"""
    k = size / SIZE
    def sc(v):
        return int(round(v * k))

    img = Image.new('RGB', (size, size), BG_BOTTOM)
    draw = ImageDraw.Draw(img, 'RGBA')

    # ① 斜向渐变底
    for y in range(size):
        row = lerp(BG_TOP, BG_BOTTOM, y / (size - 1))
        draw.line([(0, y), (size, y)], fill=row)

    # ② 左上角一团柔光（让图标有"玻璃后面透出光"的感觉，和 App 的观感一致）
    glow = Image.new('L', (size, size), 0)
    gd = ImageDraw.Draw(glow)
    gd.ellipse([sc(-140), sc(-190), sc(330), sc(280)], fill=70)
    glow = glow.filter(ImageFilter.GaussianBlur(max(1, sc(80))))
    img.paste(Image.new('RGB', (size, size), ACCENT_BLUE), (0, 0), glow)

    # ③ 3×3 圆角格子
    cell, gap, radius = sc(CELL), sc(GAP), sc(RADIUS)
    grid_w = COLS * cell + (COLS - 1) * gap
    grid_h = ROWS * cell + (ROWS - 1) * gap
    x0 = (size - grid_w) // 2
    y0 = (size - grid_h) // 2

    # 对角线上三格用主色（一眼能读出"一格格的时间"），其余是半透明玻璃格
    accents = {(0, 0): ACCENT_BLUE, (1, 1): ACCENT_PURPLE, (2, 2): ACCENT_TEAL}

    for r in range(ROWS):
        for c in range(COLS):
            cx = x0 + c * (cell + gap)
            cy = y0 + r * (cell + gap)
            box = [cx, cy, cx + cell, cy + cell]
            color = accents.get((r, c))
            if color is not None:
                draw.rounded_rectangle(box, radius=radius, fill=color + (235,))
                # 顶部一条更亮的高光边，读起来像块玻璃
                draw.rounded_rectangle([cx + sc(8), cy + sc(8), cx + cell - sc(8), cy + sc(26)],
                                       radius=max(1, sc(9)), fill=(255, 255, 255, 70))
            else:
                draw.rounded_rectangle(box, radius=radius,
                                       fill=(255, 255, 255, 30),
                                       outline=(255, 255, 255, 46), width=max(1, sc(2)))
    return img


def main():
    img = render(SIZE)
    img.save('AppScope/resources/base/media/app_icon.png')
    img.save('entry/src/main/resources/base/media/startIcon.png')
    print('wrote AppScope/resources/base/media/app_icon.png')
    print('wrote entry/src/main/resources/base/media/startIcon.png')

    # 上架素材（AGC 应用图标）：1024 与 216，都按比例重画
    os.makedirs('docs/store', exist_ok=True)
    for s in STORE_SIZES:
        out = f'docs/store/app-icon-{s}.png'
        render(s).save(out)
        print('wrote', out)


if __name__ == '__main__':
    main()
