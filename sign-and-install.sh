#!/usr/bin/env bash
# 给已编译的 .hap 签名（必要时并安装到真机）
#
#   ./sign-and-install.sh             # 只签名
#   ./sign-and-install.sh --install   # 签名后 hdc install
#
# 前置：signing/classout.cer 与 signing/classout.p7b 已从 AGC 下载到位（见 signing/README.md）

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLI_HOME="${CLASS_OUT_CLI_HOME:-/home/chemica/ChemicaWorkspace/toolchain/cli/command-line-tools}"
JAVA_HOME="${JAVA_HOME:-/home/chemica/ChemicaWorkspace/toolchain/jdk}"

JAR="$CLI_HOME/sdk/default/openharmony/toolchains/lib/hap-sign-tool.jar"
HDC="$CLI_HOME/sdk/default/openharmony/toolchains/hdc"

SIGN_DIR="$PROJECT_DIR/signing"
KEY_ALIAS="classout-debug"
KEYSTORE="$SIGN_DIR/classout.p12"

# 口令不写在脚本里，也不写进任何入库的文件 —— 从 signing/local.env 或环境变量读。
# local.env 被 .gitignore 挡住；这样仓库里没有秘密，交接文档照样自包含。
if [ -f "$SIGN_DIR/local.env" ]; then
  # shellcheck disable=SC1091
  . "$SIGN_DIR/local.env"
fi
KEY_PWD="${CLASS_OUT_KEY_PWD:-}"

# 证书与 Profile 自动识别：AGC 下载下来的文件名五花八门，大小写也不一定
pick_file() {
  find "$SIGN_DIR" -maxdepth 1 -iname "*.$1" ! -iname 'verify-*' 2>/dev/null | head -1
}
CERT="${CLASS_OUT_CERT:-$(pick_file cer)}"
PROFILE="${CLASS_OUT_PROFILE:-$(pick_file p7b)}"

OUT_DIR="$PROJECT_DIR/entry/build/default/outputs/default"
IN_HAP="$OUT_DIR/entry-default-unsigned.hap"
OUT_HAP="$OUT_DIR/entry-default-signed.hap"
COMPATIBLE_VERSION=18

die() { echo "错误：$*" >&2; exit 1; }

[ -x "$JAVA_HOME/bin/java" ] || die "找不到 java（JAVA_HOME=$JAVA_HOME）"
[ -f "$JAR" ] || die "找不到 hap-sign-tool.jar：$JAR"
[ -f "$KEYSTORE" ] || die "找不到密钥库 $KEYSTORE"
[ -n "$KEY_PWD" ] || die "没有签名口令。请创建 signing/local.env 并写入 CLASS_OUT_KEY_PWD=你的口令，或设同名环境变量（模板见 signing/local.env.example）"
[ -n "$CERT" ] || die "signing/ 里没有 .cer 证书　→ 去 AGC 下载调试证书（见 signing/README.md）"
[ -n "$PROFILE" ] || die "signing/ 里没有 .p7b 的 Profile　→ 去 AGC 下载调试 Profile（见 signing/README.md）"
echo "==> 证书：$CERT"
echo "==> Profile：$PROFILE"
[ -f "$IN_HAP" ] || die "找不到未签名的 hap $IN_HAP　→ 先跑 ./build.sh assembleHap"

echo "==> 签名 $IN_HAP"
"$JAVA_HOME/bin/java" -jar "$JAR" sign-app \
  -mode localSign \
  -keyAlias "$KEY_ALIAS" \
  -keyPwd "$KEY_PWD" \
  -appCertFile "$CERT" \
  -profileFile "$PROFILE" \
  -profileSigned 1 \
  -inFile "$IN_HAP" \
  -outFile "$OUT_HAP" \
  -signAlg SHA256withECDSA \
  -keystoreFile "$KEYSTORE" \
  -keystorePwd "$KEY_PWD" \
  -compatibleVersion "$COMPATIBLE_VERSION" \
  -signCode 1

echo "==> 校验签名"
"$JAVA_HOME/bin/java" -jar "$JAR" verify-app -inFile "$OUT_HAP" -outCertChain "$SIGN_DIR/verify-certchain.cer" -outProfile "$SIGN_DIR/verify-profile.p7b"
ls -la "$OUT_HAP"

if [ "${1:-}" = "--install" ]; then
  [ -x "$HDC" ] || die "找不到 hdc：$HDC"
  echo "==> 已连接设备："
  "$HDC" list targets
  echo "==> 安装（手机上需已开启开发者模式与 USB 调试）"
  "$HDC" install -r "$OUT_HAP"
  echo "==> 完成。桌面上应该出现 ClassOUT。"
fi
