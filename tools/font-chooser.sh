#!/usr/bin/env bash
# 字号试版：三档分别 构建 → 装机 → 冷启动 → 点进计划页 → 截图。
#
#   ./tools/font-chooser.sh
#
# 产物：.logs/font-B.jpeg、.logs/font-C.jpeg、.logs/font-D.jpeg
#
# ⚠️ 踩过的坑（第一版脚本就栽在这）：冷启动后**立刻**发 `uitest uiInput click` 会丢，
# ArkUI 还没挂好；而且点完不验证就会拍出一堆课表页还以为是计划页。
# 所以这里等 14 秒、点击后重试、并且每张图**都要求人眼确认**是计划页。
#
# ⚠️ 字号话题已由用户关闭（2026-10-13：「字号的事不用管了」，见 PLAN_REDESIGN.md §7.3）。
#    这个脚本现在是**遗留物**，正常情况下不该再跑；真要重开字号话题才用得上。
#
# 背景：计划页字号三档候选（见 PLAN_REDESIGN.md §7）。
# 用户选定后：把 PlanDayView.ets 里 `const LAYOUT: LayoutSpec = LAYOUT_X;` 定成一档，
# 然后**删掉这个脚本和多余的档位常量** —— 它是临时工具，不是长期设施。

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ="$(cd "$HERE/.." && pwd)"
CLI_HOME="${CLASS_OUT_CLI_HOME:-/home/chemica/ChemicaWorkspace/toolchain/cli/command-line-tools}"
HDC="$CLI_HOME/sdk/default/openharmony/toolchains/hdc"
SRC="$PROJ/entry/src/main/ets/view/PlanDayView.ets"

[ -x "$HDC" ] || { echo "找不到 hdc：$HDC" >&2; exit 1; }
mkdir -p "$PROJ/.logs"

# 底部标签栏的**真实**坐标来自 `uitest dumpLayout`，不是按屏幕宽三等分猜的。
# 可点击的是外层 Column：bounds=[723,2169][1084,2328] → 中心 (903, 2249)。
# ⚠️ 别用 y=2330！（第一次就是按"三等分+估算"写成 2330，实际落在 TabBar 下边界 2328 之外 2px，
#    于是点击全部丢失。我还一度误判成"冷启动时序问题"。）
TAB_PLAN_X=903
TAB_Y=2249

set_layout() {
  python3 - "$SRC" "$1" <<'PY'
import re, sys
path, spec = sys.argv[1], sys.argv[2]
s = open(path, encoding='utf-8').read()
s2, n = re.subn(r'const LAYOUT: LayoutSpec = LAYOUT_[A-D];',
                f'const LAYOUT: LayoutSpec = {spec};', s)
assert n == 1, f'expected 1 LAYOUT assignment, found {n}'
open(path, 'w', encoding='utf-8').write(s2)
PY
}

shot() {  # shot <远端名> <本地路径>
  "$HDC" shell "snapshot_display -f /data/local/tmp/$1" >/dev/null 2>&1
  "$HDC" file recv "/data/local/tmp/$1" "$2" >/dev/null 2>&1
}

for spec in LAYOUT_B LAYOUT_C LAYOUT_D; do
  tag="${spec#LAYOUT_}"
  echo "=================== $spec ==================="
  set_layout "$spec"
  grep -n 'const LAYOUT: LayoutSpec' "$SRC"

  (cd "$PROJ" && ./build.sh assembleHap >/dev/null 2>&1) \
    || { echo "构建失败" >&2; exit 1; }
  (cd "$PROJ" && ./sign-and-install.sh --install >/dev/null 2>&1) \
    || { echo "安装失败" >&2; exit 1; }

  # 冷启动：先回桌面再启动，避免落在别的应用上
  "$HDC" shell "uitest uiInput keyEvent Home" >/dev/null 2>&1 || true
  "$HDC" shell "aa force-stop com.chemica.classout" >/dev/null 2>&1 || true
  sleep 2
  "$HDC" shell "aa start -b com.chemica.classout -a EntryAbility" >/dev/null 2>&1
  sleep 10   # 等 ArkUI 挂好

  # 点「计划」，点两次（幂等：已经在计划页时再点也无害）
  for _ in 1 2; do
    "$HDC" shell "uitest uiInput click $TAB_PLAN_X $TAB_Y" >/dev/null 2>&1
    sleep 2
  done
  sleep 2

  shot "font-${tag}.jpeg" "$PROJ/.logs/font-${tag}.jpeg"
  echo "→ .logs/font-${tag}.jpeg"
done

echo
echo "完成。**逐张看图确认拍的是计划页（有「待安排」字样）**，别假设。"
