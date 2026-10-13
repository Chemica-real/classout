#!/usr/bin/env bash
# 实时盯 ClassOUT 的日志，同时落盘到文件。
#
#   ./tools/watch-logs.sh [输出文件]
#
# 默认写到 .logs/live.log（项目内，方便 agent 边跑边读）。
#
# 与 ./logs.sh 的区别：logs.sh 是给人看的滚动输出；这个是给 agent 边干活边读的，
# 去掉了资源/主题那几行噪音（每次启动都会刷一堆，没用），并带行缓冲写盘。
#
# 退出：Ctrl-C，或 kill 掉这个进程。

set -uo pipefail

CLI_HOME="${CLASS_OUT_CLI_HOME:-/home/chemica/ChemicaWorkspace/toolchain/cli/command-line-tools}"
HDC="$CLI_HOME/sdk/default/openharmony/toolchains/hdc"

[ -x "$HDC" ] || { echo "找不到 hdc：$HDC" >&2; exit 1; }

PROJ_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${1:-$PROJ_DIR/.logs/live.log}"
mkdir -p "$(dirname "$OUT")"

echo "== 实时日志 → $OUT （Ctrl-C 退出） =="

"$HDC" shell "hilog -T ClassOUT" 2>&1 | tr -d '\r' | while IFS= read -r line; do
  # 启动时刷屏的主题/资源查找警告，与功能无关，滤掉
  case "$line" in
    *AceTheme*|*AceResource*|*ResourceManager*) continue ;;
  esac
  # 逐行同时写盘 + 打到 stdout。写盘用 >> 直接追加，不经过 tee 的缓冲，
  # 这样 agent 在进程还活着的时候就能读到最新几行。
  printf '%s\n' "$line" >>"$OUT"
  printf '%s\n' "$line"
done
