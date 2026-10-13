#!/usr/bin/env bash
# ClassOUT 命令行构建脚本
# 环境：Ubuntu + 华为官方 Command Line Tools（无 DevEco Studio）
#
#   ./build.sh assembleHap        # 编译出 unsigned .hap
#   ./build.sh clean              # 清理
#   ./build.sh --help             # 查看全部任务
#
# 可用环境变量覆盖：
#   CLASS_OUT_CLI_HOME   Command Line Tools 解压目录
#   HVIGOR_USER_HOME     hvigor 的缓存/包装器目录（默认 <项目>/.hvigor）
#   JAVA_HOME            JDK 17（PackageHap 打包 .hap 需要 java）

set -euo pipefail

CLI_HOME="${CLASS_OUT_CLI_HOME:-/home/chemica/ChemicaWorkspace/toolchain/cli/command-line-tools}"
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 打包 HAP 需要 java；hvigor 本身不带 JDK
if [ -z "${JAVA_HOME:-}" ]; then
  for candidate in \
    "/home/chemica/ChemicaWorkspace/toolchain/jdk" \
    "/usr/lib/jvm/java-17-openjdk-amd64"; do
    if [ -x "$candidate/bin/java" ]; then
      export JAVA_HOME="$candidate"
      break
    fi
  done
fi
if [ -n "${JAVA_HOME:-}" ]; then
  export PATH="$JAVA_HOME/bin:$PATH"
else
  echo "警告：找不到 java，PackageHap 会失败。请安装 JDK 17 或设置 JAVA_HOME。" >&2
fi

if [ ! -x "$CLI_HOME/bin/hvigorw" ]; then
  echo "找不到 hvigorw：$CLI_HOME/bin/hvigorw" >&2
  echo "请设置 CLASS_OUT_CLI_HOME 指向 Command Line Tools 解压目录。" >&2
  exit 1
fi

# hvigorw 会自己补 DEVECO_NODE_HOME / DEVECO_SDK_HOME，这里显式设定更稳
export DEVECO_NODE_HOME="$CLI_HOME/tool/node"
export DEVECO_SDK_HOME="$CLI_HOME/sdk"
export PATH="$DEVECO_NODE_HOME/bin:$PATH"

# 默认把 hvigor 家目录放在项目内：避免写 $HOME（且与工作区隔离）
if [ -z "${HVIGOR_USER_HOME:-}" ]; then
  export HVIGOR_USER_HOME="$PROJECT_DIR/.hvigor"
fi

cd "$PROJECT_DIR"
exec "$CLI_HOME/bin/hvigorw" --no-daemon "$@"
