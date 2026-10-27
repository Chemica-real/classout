#!/usr/bin/env bash
# 打「上架用」的**发布包**：release 构建 → 发布证书/Profile 签名 → 校验 → 落到 dist/
#
#   ./sign-release.sh              # 构建 + 签名 + 校验
#   ./sign-release.sh --no-build   # 只用已有的 unsigned .app 签名（构建过就别重跑）
#
# 前置（**全部在 .gitignore 里，不入库**）：
#   signing/release/*.p12   发布密钥库（可以直接复用 signing/classout.p12，见 signing/release/README.md）
#   signing/release/*.cer   AGC 下载的**发布证书**
#   signing/release/*.p7b   AGC 下载的**发布 Profile**
#   signing/local.env       口令：CLASS_OUT_KEY_PWD（或 CLASS_OUT_RELEASE_KEY_PWD 单独给发布用）
#
# 为什么和 sign-and-install.sh 分开：
#   调试包和发布包用的证书/Profile 完全不同（发布 Profile 不带 UDID 白名单、签出来的包装不上手机），
#   而且发布包是 **.app**（app pack），不是 .hap。混在一个脚本里迟早把上架包签成调试包。
#
# ⚠️ 构建要带那个 locale shim 的 PATH（见 HANDOFF §23.5）：
#      export PATH="/home/chemica/ChemicaWorkspace/.locale-shim:$PATH"

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLI_HOME="${CLASS_OUT_CLI_HOME:-/home/chemica/ChemicaWorkspace/toolchain/cli/command-line-tools}"
JAVA_HOME="${JAVA_HOME:-/home/chemica/ChemicaWorkspace/toolchain/jdk}"

JAR="$CLI_HOME/sdk/default/openharmony/toolchains/lib/hap-sign-tool.jar"

REL_DIR="$PROJECT_DIR/signing/release"
DIST_DIR="$PROJECT_DIR/dist"

# 口令：local.env 或环境变量。发布口令可以单独一个，没设就复用调试那个。
if [ -f "$PROJECT_DIR/signing/local.env" ]; then
  # shellcheck disable=SC1091
  . "$PROJECT_DIR/signing/local.env"
fi
KEY_PWD="${CLASS_OUT_RELEASE_KEY_PWD:-${CLASS_OUT_KEY_PWD:-}}"
# 密钥别名：复用 classout.p12 的话它是 classout-debug；新生成的按你起的名字来
KEY_ALIAS="${CLASS_OUT_RELEASE_KEY_ALIAS:-classout-release}"

BUILD_MODE="release"
DO_BUILD=1
[ "${1:-}" = "--no-build" ] && DO_BUILD=0

die() { echo "错误：$*" >&2; exit 1; }
pick() { find "$REL_DIR" -maxdepth 1 -iname "*.$1" 2>/dev/null | head -1; }

[ -x "$JAVA_HOME/bin/java" ] || die "找不到 java（JAVA_HOME=$JAVA_HOME）"
[ -f "$JAR" ] || die "找不到 hap-sign-tool.jar：$JAR"
[ -d "$REL_DIR" ] || die "没有 signing/release/ 目录　→ 见 signing/release/README.md"

KEYSTORE="$(pick p12)"
CERT="$(pick cer)"
PROFILE="$(pick p7b)"
[ -n "$KEYSTORE" ] || die "signing/release/ 里没有 .p12 密钥库"
[ -n "$CERT" ]     || die "signing/release/ 里没有 .cer **发布证书**（AGC → 证书、App ID 和 Profile → 证书）"
[ -n "$PROFILE" ]  || die "signing/release/ 里没有 .p7b **发布 Profile**（AGC → Profile → 类型选『发布』）"
[ -n "$KEY_PWD" ]  || die "没有签名口令。请在 signing/local.env 里设 CLASS_OUT_KEY_PWD=…（或 CLASS_OUT_RELEASE_KEY_PWD=…）"

echo "==> 密钥库：$KEYSTORE"
echo "==> 发布证书：$CERT"
echo "==> 发布 Profile：$PROFILE"
echo "==> 密钥别名：$KEY_ALIAS（复用调试密钥库时要设 CLASS_OUT_RELEASE_KEY_ALIAS=classout-debug）"

if [ "$DO_BUILD" = "1" ]; then
  echo "==> release 构建（assembleApp）"
  "$PROJECT_DIR/build.sh" assembleApp || die "构建失败。若报 locale / Cannot read properties of undefined，先把 locale shim 加进 PATH（见 HANDOFF §23.5）"
fi

# hvigor 把 app pack 放在这里；没有 signingConfig 时是 -unsigned.app
UNSIGNED="$(find "$PROJECT_DIR/build/outputs" -name '*-unsigned.app' 2>/dev/null | head -1)"
[ -n "$UNSIGNED" ] || die "找不到未签名的 app pack（build/outputs/**/*-unsigned.app）　→ 先跑 ./build.sh assembleApp"

VERSION="$(grep -o '"versionName"[[:space:]]*:[[:space:]]*"[^"]*"' "$PROJECT_DIR/AppScope/app.json5" | head -1 | sed 's/.*"\([^"]*\)"$/\1/')"
CODE="$(grep -o '"versionCode"[[:space:]]*:[[:space:]]*[0-9]*' "$PROJECT_DIR/AppScope/app.json5" | head -1 | sed 's/[^0-9]//g')"
mkdir -p "$DIST_DIR"
OUT_APP="$DIST_DIR/ClassOUT-${VERSION}-release.app"

echo "==> 签名（.app 是 zip，所以 -inForm zip）"
"$JAVA_HOME/bin/java" -jar "$JAR" sign-app \
  -mode localSign \
  -keyAlias "$KEY_ALIAS" \
  -keyPwd "$KEY_PWD" \
  -appCertFile "$CERT" \
  -profileFile "$PROFILE" \
  -profileSigned 1 \
  -inFile "$UNSIGNED" \
  -inForm zip \
  -outFile "$OUT_APP" \
  -signAlg SHA256withECDSA \
  -keystoreFile "$KEYSTORE" \
  -keystorePwd "$KEY_PWD"

echo "==> 校验签名"
"$JAVA_HOME/bin/java" -jar "$JAR" verify-app \
  -inFile "$OUT_APP" -inForm zip \
  -outCertChain "$REL_DIR/verify-release-certchain.cer" \
  -outProfile "$REL_DIR/verify-release-profile.p7b"

echo ""
echo "==> 完成：$OUT_APP"
echo "    版本：$VERSION（versionCode $CODE）"
echo ""
echo "接下来（都要在 AGC 网页上做，见 AGC-FILL.md）："
echo "  1. 软件包管理 → 上传这个 .app：只做邀请测试选「仅测试」，正式上架选「测试和正式上架」"
echo "  2. 应用信息 / 版本信息：按 AGC-FILL.md 逐字段填（图标、截图、隐私声明、隐私标签、内容分级）"
echo "  3. 版权信息：软著/电子版权证书（手机应用必须传，且只收 JPG/PNG/BMP）"
echo "  4. 备案信息：本应用无网络权限 → 选「您的APP为单机APP」，不需要备案号"
echo "  5. 邀请测试流程见 AGC-FILL.md §4；正式上架提交后一般 1–7 个工作日"
