#!/usr/bin/env python3
"""
查当前计划页状态：刻度首行位置、指定块的位置、顶部提示。

用法：
    python3 tools/plan-state.py                # 只报刻度 + 所有可见块
    python3 tools/plan-state.py 哈哈哈2         # 额外报这个块的中心坐标

为什么单独写一个：之前用 inline python + `2>/dev/null` 查状态，
`file recv` 失败时会静默沿用上一次的 dump，导致我按过期坐标操作、
得出错误结论（白测好几轮）。这个脚本会**校验 dump 是否真的更新了**。
"""
import json
import re
import subprocess
import sys
import os
import hashlib

HDC = ("/home/chemica/ChemicaWorkspace/toolchain/cli/command-line-tools"
       "/sdk/default/openharmony/toolchains/hdc")
LOCAL = "/tmp/plan-state.json"


def run(args):
    return subprocess.run([HDC] + args, capture_output=True, text=True)


def dump():
    """dumpLayout 并把文件拉回来。校验文件确实变了，避免沿用旧数据。"""
    before = hashlib.md5(open(LOCAL, 'rb').read()).hexdigest() if os.path.exists(LOCAL) else ''
    run(["shell", "uitest dumpLayout /data/local/tmp/ps.json"])
    # 找出最新的 layout 文件
    ls = run(["shell", "ls -t /data/local/tmp/layout_*.json"])
    files = [f.strip() for f in ls.stdout.strip().split("\n") if f.strip()]
    if not files:
        sys.exit("拿不到 layout 文件列表")
    remote = files[0]
    r = run(["file", "recv", remote, LOCAL])
    if not os.path.exists(LOCAL):
        sys.exit(f"file recv 失败: {r.stdout} {r.stderr}")
    after = hashlib.md5(open(LOCAL, 'rb').read()).hexdigest()
    if after == before:
        print("警告：dump 与上次完全相同（可能没变化，也可能 recv 失败）", file=sys.stderr)
    return json.load(open(LOCAL))


def walk(node, out):
    if isinstance(node, dict):
        a = node.get('attributes', {})
        text = a.get('text', '') or ''
        bounds = a.get('bounds', '')
        m = re.match(r'\[(-?\d+),(-?\d+)\]\[(-?\d+),(-?\d+)\]', bounds or '')
        if text and m:
            x1, y1, x2, y2 = map(int, m.groups())
            out.append((text, x1, y1, x2, y2))
        for c in node.get('children', []) or []:
            walk(c, out)
    return out


def main():
    target = sys.argv[1] if len(sys.argv) > 1 else None
    d = dump()
    items = walk(d, [])

    ruler = None
    hint = None
    blocks = []
    for text, x1, y1, x2, y2 in items:
        if re.match(r'^\d\d:00$', text):
            if ruler is None or y1 < ruler[1]:
                ruler = (text, y1)
        if '激活' in text or '挪到' in text or '时长' in text or '放不下' in text:
            hint = text
        # 计划块：横跨网格、但高度较小（课程灰带更高且文字是简称）
        if 100 < x1 < 200 and (x2 - x1) > 600 and (y2 - y1) < 40:
            blocks.append((text, (x1 + x2) // 2, (y1 + y2) // 2, y2 - y1))

    if ruler:
        print(f"刻度首行: {ruler[0]} @ y={ruler[1]}")
    else:
        print("刻度首行: 没找到")
    print(f"提示: {hint if hint else '(无)'}")
    print("可见计划块:")
    for text, cx, cy, h in blocks:
        print(f"  {text!r:16} 中心=({cx},{cy}) 高={h}")
    if target:
        for text, x1, y1, x2, y2 in items:
            if text == target:
                print(f"目标 {target!r}: 中心=({(x1+x2)//2},{(y1+y2)//2}) bounds=[{x1},{y1}][{x2},{y2}]")
                break
        else:
            print(f"目标 {target!r}: 当前视图内找不到")


if __name__ == '__main__':
    main()
