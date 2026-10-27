#!/usr/bin/env python3
"""把 docs/manual 里的真机截图转成 AGC 要求的 **9:16 / 1080×1920** 竖版截图。

    python3 tools/make-store-shots.py

为什么需要这一步：AGC 素材规范要求手机竖版截图 **1080×1920（9:16）**，
而真机（PSN-AL00）截图是 1084×2412（约 9:20），直接传会被判"比例不符"。
做法：裁掉状态栏与底部手势区 → 缩到高 1920 → 居中放在 1080×1920 画布上，
背景用同一张图放大模糊压暗（不是留白边，也不是拉伸裁掉内容）。

产物：dist/store/phone-9x16/<原名>.jpg（1080×1920，JPEG，< 5MB）
"""

import os
import sys

from PIL import Image, ImageEnhance, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC_DIR = os.path.join(ROOT, 'docs/manual')
OUT_DIR = os.path.join(ROOT, 'dist/store/phone-9x16')
W, H = 1080, 1920
# 真机 1084×2412：状态栏 0–108，底部手势区 2295 以后（导航栏到 2295）
CROP_TOP, CROP_BOTTOM = 108, 2295


def convert(src: str, dst: str):
    im = Image.open(src).convert('RGB')
    # 1) 去掉状态栏 / 手势区，剩 App 界面
    app = im.crop((0, CROP_TOP, im.width, min(CROP_BOTTOM, im.height)))

    # 2) 背景：铺满 1080×1920（裁切填满）→ 模糊 + 压暗
    scale_bg = max(W / app.width, H / app.height)
    bg = app.resize((int(app.width * scale_bg) + 1, int(app.height * scale_bg) + 1),
                    Image.LANCZOS)
    left = (bg.width - W) // 2
    top = (bg.height - H) // 2
    bg = bg.crop((left, top, left + W, top + H))
    bg = bg.filter(ImageFilter.GaussianBlur(36))
    bg = ImageEnhance.Brightness(bg).enhance(0.45)

    # 3) 前景：完整 App 界面，缩到高 1920，水平居中
    scale_fg = H / app.height
    fw = int(app.width * scale_fg)
    fg = app.resize((fw, H), Image.LANCZOS)
    x = (W - fw) // 2
    bg.paste(fg, (x, 0))
    bg.save(dst, 'JPEG', quality=92, optimize=True)


def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    names = sorted(f for f in os.listdir(SRC_DIR)
                   if f.lower().endswith(('.jpg', '.jpeg', '.png')))
    if not names:
        print(f'没有找到截图：{SRC_DIR}', file=sys.stderr)
        raise SystemExit(1)
    for name in names:
        src = os.path.join(SRC_DIR, name)
        dst = os.path.join(OUT_DIR, os.path.splitext(name)[0] + '.jpg')
        convert(src, dst)
        with Image.open(dst) as out:
            size = out.size
        print(f'{name} → {os.path.relpath(dst, ROOT)}  {size[0]}×{size[1]}  '
              f'{os.path.getsize(dst) // 1024} KB')
    print(f'\n共 {len(names)} 张，输出目录：{os.path.relpath(OUT_DIR, ROOT)}')


if __name__ == '__main__':
    main()
