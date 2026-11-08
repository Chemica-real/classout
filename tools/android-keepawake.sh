#!/usr/bin/env bash
# 让已连接的 Android 真机保持唤醒，避免调试/验收时 30 分钟自动熄屏。
#
# 用法（在 ClassOUT/ 下）：
#   ./tools/android-keepawake.sh            # 每 30s 唤醒一次；每 5 分钟轻点左下角空白
#   TAP=0 ./tools/android-keepawake.sh      # 只发 WAKEUP，不点击
#
# 说明：点击坐标取屏幕左下角的布局留白（x=5, y=1200），避开卡片和底部导航。
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ADB="${ADB:-$ROOT/../toolchain/android-sdk/platform-tools/adb}"
TAP="${TAP:-1}"
SERIAL="${SERIAL:-}"
ADB_ARGS=()
if [ -n "$SERIAL" ]; then ADB_ARGS=(-s "$SERIAL"); fi

if ! "$ADB" "${ADB_ARGS[@]}" get-state >/dev/null 2>&1; then
  echo "没有找到已连接的 Android 设备（先开 USB 调试）"
  exit 1
fi

echo "保持唤醒中：设备=$("$ADB" "${ADB_ARGS[@]}" shell getprop ro.product.model | tr -d '\r')"
i=0
while true; do
  "$ADB" "${ADB_ARGS[@]}" shell input keyevent KEYCODE_WAKEUP >/dev/null 2>&1 || true
  "$ADB" "${ADB_ARGS[@]}" shell wm dismiss-keyguard >/dev/null 2>&1 || true
  # 每 10 轮（约 5 分钟）在布局留白处轻点一次，算一次用户活动；不点卡片/导航
  if [ "$TAP" = "1" ] && [ $((i % 10)) -eq 0 ]; then
    "$ADB" "${ADB_ARGS[@]}" shell input tap 5 1200 >/dev/null 2>&1 || true
  fi
  i=$((i + 1))
  sleep 30
done
