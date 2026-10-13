#!/usr/bin/env bash
# hdc 包装脚本：把工具链自带的 hdc 加进 PATH
#
#   ./hdc.sh list targets
#   ./hdc.sh shell bm get -u
#   ./hdc.sh install -r path/to/xxx.hap
set -euo pipefail
CLI_HOME="${CLASS_OUT_CLI_HOME:-/home/chemica/ChemicaWorkspace/toolchain/cli/command-line-tools}"
HDC="$CLI_HOME/sdk/default/openharmony/toolchains/hdc"
[ -x "$HDC" ] || { echo "找不到 hdc：$HDC" >&2; exit 1; }
exec "$HDC" "$@"
