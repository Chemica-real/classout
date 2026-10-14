#!/usr/bin/env python3
"""按**属性**把浅色主题的颜色字面量映射成深色主题（HANDOFF §18.5）。

为什么不一把全局替换：同一个字面量在不同属性下要走不同的表 ——
`fontColor('#FFFFFF')` 是彩色按钮上的白字（**保留**），
`backgroundColor('#FFFFFF')` 却是浅底（要换成半透明白）。
`color:`（描边/分隔线/阴影）又和上面两张表都不同。

用法：
    python3 tools/darken-theme.py            # dry-run，只打印将要发生的改动
    python3 tools/darken-theme.py --apply    # 真的写回
"""
import re
import sys

FILES = [
    "entry/src/main/ets/pages/Index.ets",
    "entry/src/main/ets/view/TodoInbox.ets",
    "entry/src/main/ets/view/PlanDayView.ets",
    "entry/src/main/ets/view/CourseManager.ets",
    "entry/src/main/ets/view/SettingsPage.ets",
    "entry/src/main/ets/view/ChipButton.ets",
]

LIT = re.compile(
    r"#[0-9A-Fa-f]{6}\b"
    r"|rgba\([0-9]+\s*,\s*[0-9]+\s*,\s*[0-9]+\s*,\s*[0-9.]+\s*\)"
    r"|rgb\([0-9]+\s*,\s*[0-9]+\s*,\s*[0-9]+\s*\)"
)

# 属性 → 表。找**同一行里最近的那个**属性词，所以一行有多个颜色也能各归各的。
PROPS = [
    "fontColor(", "backgroundColor(", "fill(", "stroke(",
    "color:", ".color(", "colors:", "shadow(",
    "placeholderColor(", "caretColor(", "hintColor:", "borderColor:",
]
FONT_PROPS = {"fontColor(", "placeholderColor(", "caretColor(", "hintColor:"}
BG_PROPS = {"backgroundColor(", "fill("}

# ---- §18.5 文字色（fontColor）----
FONT = {
    '#12161F': '#F2F5FA',   # 主文字
    '#1B2430': '#EAF0FA',   # 主文字（次级）
    '#3C4657': '#CBD6E8',   # 正文
    '#4A5568': '#C3CDDE',   # 次级正文
    '#5A6478': '#A9B5C9',   # 弱文字
    '#7A8598': '#9BA7BD',   # 弱文字
    '#8A94A6': '#94A0B5',   # 提示文字
    '#98A2B3': '#8B97AC',   # 提示文字
    '#8A98AC': '#8B97AC',   # 提示文字
    '#B0B8C4': '#7C8798',   # 最弱（刻度）
    '#C2CBDA': '#DCE4F0',   # 浅文字
    '#2E6BE6': '#7FA8FF',   # 强调蓝文字（深底上要提亮）
    '#D64545': '#FF8080',   # 危险文字
    '#C0392B': '#FF8A8A',   # 危险文字
    '#3C6E47': '#7BD69A',   # 成功/模板文字
    '#5B7A5B': '#8FC9A0',   # 成功文字
    '#B26B00': '#E8B25C',   # 警示文字
    '#8A5A00': '#E0A94E',   # 警示文字
    '#9DB2C8': '#C7D3E4',   # 通用浅色 / 无色课程兜底
    '#7C8AA0': '#8FA0BA',   # 无色课程的兜底色
    '#8A7A55': '#D8C48A',   # 虚拟课时文字
    '#FFFFFF': '#FFFFFF',   # ⚠️ 彩色按钮上的白字，**不要动**
}

# ---- §18.5 背景色（backgroundColor / fill）----
BG = {
    '#EEF1F6': 'rgba(255,255,255,0.14)',   # 胶囊/次要按钮底
    '#F2F4F8': 'rgba(255,255,255,0.10)',   # 小按钮底
    '#F7F8FA': 'rgba(255,255,255,0.08)',   # 行底
    '#F2F6FF': 'rgba(255,255,255,0.10)',   # 行底
    '#F5F6F8': 'rgba(255,255,255,0.06)',   # 计划页"今天"列高亮
    '#E8ECF3': 'rgba(255,255,255,0.10)',   # 计划页课程灰带
    '#EDEFF3': 'rgba(255,255,255,0.12)',   # 分隔线色当底用
    '#FDECEA': 'rgba(214,69,69,0.18)',     # 危险浅底
    '#FFF4F4': 'rgba(214,69,69,0.14)',     # 危险浅底
    '#FFF8F8': 'rgba(214,69,69,0.12)',     # 危险浅底
    '#EAF1FF': 'rgba(46,107,230,0.22)',    # 信息浅底
    '#FFF4E5': 'rgba(178,107,0,0.20)',     # 警示浅底
    'rgba(255,246,226,0.55)': 'rgba(240,190,90,0.16)',   # 虚拟课时托盘卡
    'rgba(46,107,230,0.18)': 'rgba(46,107,230,0.30)',    # 托盘选中态
    'rgba(248,250,254,0.30)': 'rgba(10,12,22,0.42)',     # 管理课程背板（压暗）
    '#2E6BE6': '#2E6BE6',                  # 主按钮底（保持）
    '#D64545': '#D64545',                  # 危险按钮底（保持）
    '#FFFFFF': 'rgba(255,255,255,0.10)',   # 兜底（现已无纯白底，防御性）
}

# ---- §18.5 边框 / 分隔线 / 其他（color: / border / shadow）----
LINE = {
    '#EDEFF3': 'rgba(255,255,255,0.12)',   # 分隔线（时间网格横线、页头下边）
    '#E3E8F0': 'rgba(255,255,255,0.14)',   # 卡片边
    '#D8DEE9': 'rgba(255,255,255,0.12)',   # 边（色板未选中框）
    '#12161F': '#F2F5FA',                  # 计划块选中框：深色下要变成亮框
    '#F5D9D9': 'rgba(214,69,69,0.30)',     # 危险边
    '#F0DFC0': 'rgba(240,190,90,0.28)',    # 虚拟课时卡边
    '#B0B8C4': 'rgba(255,255,255,0.35)',   # 拖拽虚线空位：要看得见
    '#2E6BE6': '#7FA8FF',                  # 选中/强调描边：深底上要提亮
    '#FFFFFF': '#FFFFFF',                  # 习题课白色虚线框（保持）
    'rgba(28,45,90,0.18)': 'rgba(0,0,0,0.35)',   # 阴影（保持深色）
    'rgba(28,45,90,0.13)': 'rgba(0,0,0,0.30)',   # 阴影（保持深色）
}

# 已经是深色、保持不动的（遮罩 / 提示胶囊 / 缩放提示 / 手改过的新值）
KEEP_EXACT = {
    'rgba(12,18,28,0.45)', 'rgba(12,18,28,0.86)', 'rgba(12,18,28,0.88)',
    'rgba(46,107,230,0.30)',      # 计划页托盘选中态（新值）
    '#7FA8FF',                    # 提亮后的强调色（新值）
    'rgba(240,190,90,0.16)',      # 虚拟课时托盘卡底（新值）
    'rgba(240,190,90,0.28)',      # 虚拟课时托盘卡边（新值）
}

# 行里找不到属性词的（多行三元表达式、@Builder 实参、return 兜底色）—— 都是文字色
ORPHAN = {
    '#9DB2C8': '#C7D3E4',
    '#D64545': '#FF8080',
    '#5A6478': '#A9B5C9',
    '#2E6BE6': '#7FA8FF',
    '#7C8AA0': '#8FA0BA',
}


def table_for(prop):
    if prop is None:
        return ORPHAN, 'orphan'
    if prop in FONT_PROPS:
        return FONT, 'font'
    if prop in BG_PROPS:
        return BG, 'bg'
    return LINE, 'line'


def main():
    apply = "--apply" in sys.argv
    counter = {"n": 0}
    problems = []
    for f in FILES:
        src = open(f, encoding="utf-8").read()
        out = []
        for i, line in enumerate(src.split("\n"), 1):
            stripped = line.lstrip()
            is_comment = stripped.startswith("//") or stripped.startswith("*") \
                or stripped.startswith("/*")
            if is_comment or not LIT.search(line):
                out.append(line)
                continue
            def sub(m):
                lit = m.group(0)
                if lit in KEEP_EXACT:
                    return lit
                head = line[:m.start()]
                prop, best = None, -1
                for p in PROPS:
                    j = head.rfind(p)
                    if j > best:
                        best, prop = j, p
                table, kind = table_for(prop)
                if lit not in table:
                    problems.append(f"{f}:{i}  [{kind}/{prop}] 未映射: {lit}  | {stripped[:90]}")
                    return lit
                new = table[lit]
                if new != lit:
                    counter["n"] += 1
                    print(f"{f}:{i}  [{kind:6}] {lit:26} -> {new}")
                return new
            out.append(LIT.sub(sub, line))
        if apply:
            open(f, "w", encoding="utf-8").write("\n".join(out))
    print(f"\n==== {'已写入' if apply else 'dry-run'}：{counter['n']} 处改动 ====")
    if problems:
        print("==== ⚠️ 未映射（必须人工处理）====")
        for p in problems:
            print(p)


if __name__ == "__main__":
    main()
