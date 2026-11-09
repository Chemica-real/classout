# Android 正式签名与分享流程

Android 包名固定为 `com.chemica.classout`。自 2026-11-09 起，`flutter build apk --release`
使用本机的正式 keystore，不再使用 Flutter 模板的 debug 签名。

## 本机文件（绝对不要提交）

- `app_flutter/android/app/classout-release.jks`：正式签名密钥，有效期 100 年
- `app_flutter/android/key.properties`：store/key 密码与 alias
- `.signing/keystore-password.txt`：同一密码的备份副本

这三个位置已在 `.gitignore` / `app_flutter/android/.gitignore` 中忽略。
请把 `.jks` 和密码备份到至少两个离线位置；**丢失密钥后无法给已安装用户发更新**。

证书摘要：

- SHA-256: `26feb25501991a8ab0461723e4049e086a9753533ceecd3db54e8eed066f4e7c`
- SHA-1: `9817b3dadf3d21ebee7e913ad61a68838720b5c9`

## 构建

```bash
cd app_flutter
export PATH=/home/chemica/ChemicaWorkspace/toolchain/flutter-sdk/bin:/home/chemica/ChemicaWorkspace/toolchain/jdk/bin:$PATH
export JAVA_HOME=/home/chemica/ChemicaWorkspace/toolchain/jdk
flutter build apk --release
```

产物：`app_flutter/build/app/outputs/flutter-apk/app-release.apk`。
分享副本放在 `dist/`（该目录被 git 忽略）。

## 发版规则

1. 在 `app_flutter/pubspec.yaml` 提升 `version`（例如 `1.10.1+1010100`），versionCode 必须递增。
2. 用同一把 keystore 签名构建。
3. 验证签名：

```bash
export JAVA_HOME=/home/chemica/ChemicaWorkspace/toolchain/jdk
export PATH="$JAVA_HOME/bin:$PATH"
/home/chemica/ChemicaWorkspace/toolchain/android-sdk/build-tools/36.0.0/apksigner \
  verify --print-certs app_flutter/build/app/outputs/flutter-apk/app-release.apk
```

4. 手机若装过旧 **debug 签名**包，不能直接覆盖正式签名包：
   需要先备份数据，再卸载旧包安装新包。之后所有更新都用正式签名，可正常覆盖。

## 上架注意

- 先确认隐私政策正文与实际权限（通知、日历）一致；日历同步默认关闭。
- `SCHEDULE_EXACT_ALARM` 在部分商店需要用途说明；没有精确闹钟权限时会回退 inexact。
- 当前 APK 是 universal APK；若上架可再切 ABI split 或 AAB。
