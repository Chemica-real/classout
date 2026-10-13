#!/usr/bin/env bash
# 真机日志与排错
#
#   ./logs.sh            实时滚动 ClassOUT 自己的日志（Ctrl-C 退出）
#   ./logs.sh --errors   打印缓冲区里最近的 ERROR/FATAL（ArkTS 崩溃一般在这里）
#   ./logs.sh --dump     一次性打印缓冲区里可能相关的日志
#   ./logs.sh --clear    清空日志缓冲（重新跑 App 前清一下更干净）
#
# 需要手机已连上（./hdc.sh list targets 能看到设备）。

set -euo pipefail

CLI_HOME="${CLASS_OUT_CLI_HOME:-/home/chemica/ChemicaWorkspace/toolchain/cli/command-line-tools}"
HDC="$CLI_HOME/sdk/default/openharmony/toolchains/hdc"

[ -x "$HDC" ] || { echo "找不到 hdc：$HDC" >&2; exit 1; }

mode="${1:-follow}"

case "$mode" in
  --errors)
    echo "== 最近的 ERROR / FATAL =="
    "$HDC" shell hilog -x -L E -v long 2>&1 | tr -d '\r' | tail -120
    ;;
  --dump)
    echo "== 缓冲区里与 ClassOUT 相关的日志 =="
    "$HDC" shell hilog -x -v long 2>&1 | tr -d '\r' \
      | grep -iE 'classout|com\.chemica|arkts|jscrash|jsapp|abilitymanager' | tail -150
    ;;
  --clear)
    "$HDC" shell hilog -r
    echo "已清空日志缓冲"
    ;;
  *)
    echo "== 实时日志：只看 tag=ClassOUT（Ctrl-C 退出）=="
    echo "   （先去手机上打开 ClassOUT）"
    "$HDC" shell hilog -T ClassOUT 2>&1 | tr -d '\r'
    ;;
esac
