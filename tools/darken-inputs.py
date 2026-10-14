#!/usr/bin/env python3
"""给全 App 的 `TextInput` 补上深色主题的文字/占位/光标色。

为什么必须**显式**设：`TextInput` 的默认文字色是跟随系统浅色主题的**近黑色**，
在深色玻璃面板上等于看不见。颜色字面量扫描抓不到它 —— 因为代码里根本没写颜色。
（用户实测反馈：「各输入框中纯黑色字体难以看清」。）

只在**还没有** `.fontColor(` 的输入框上插入，重复跑是幂等的。
"""
import re
import sys

FILES = [
    "entry/src/main/ets/pages/Index.ets",
    "entry/src/main/ets/view/TodoInbox.ets",
    "entry/src/main/ets/view/PlanDayView.ets",
    "entry/src/main/ets/view/CourseManager.ets",
    "entry/src/main/ets/view/SettingsPage.ets",
]

INSERT = [".fontColor('#F2F5FA')", ".placeholderColor('#8B97AC')", ".caretColor('#7FA8FF')"]


def end_of_call(src, open_paren):
    """从 TextInput( 的 '(' 开始，返回配对 ')' 的下标（跳过字符串字面量）。"""
    depth = 0
    i = open_paren
    quote = None
    while i < len(src):
        ch = src[i]
        if quote:
            if ch == "\\":
                i += 2
                continue
            if ch == quote:
                quote = None
        elif ch in "'\"":
            quote = ch
        elif ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
            if depth == 0:
                return i
        i += 1
    raise ValueError("括号不配对")


def main():
    apply = "--apply" in sys.argv
    n = 0
    for f in FILES:
        src = open(f, encoding="utf-8").read()
        out = src
        # 从后往前替换，避免下标漂移
        spots = [m.start() for m in re.finditer(r"\bTextInput\(", src)]
        for at in reversed(spots):
            open_paren = src.index("(", at)
            close = end_of_call(src, open_paren)
            # 往后看这条链上有没有已经设过 fontColor
            tail = src[close:close + 900]
            if ".fontColor(" in tail.split("\n\n")[0][:400] and tail.lstrip().startswith("."):
                # 保险：只有链上（不是下一个控件）才算
                first_chain = tail[:200]
                if ".fontColor(" in first_chain:
                    continue
            line_start = src.rfind("\n", 0, at) + 1
            indent = " " * (len(src[line_start:at]) - len(src[line_start:at].lstrip()) + 2)
            ins = "".join(f"\n{indent}{x}" for x in INSERT)
            out = out[:close + 1] + ins + out[close + 1:]
            n += 1
        if apply:
            open(f, "w", encoding="utf-8").write(out)
        print(f"{f}: 补 {len(spots)} 处 TextInput 配色")
    print(f"==== {'已写入' if apply else 'dry-run'}：{n} 处 ====")


if __name__ == "__main__":
    main()
