# `app_flutter/` —— ClassOUT 的 iOS / Android 实现（Dart + Flutter）

鸿蒙端是 `../entry/`（ArkTS）；这一端和它共用**规则**，不共用代码。
规则的唯一来源是 `../shared/`，见 `../shared/README.md`。

```bash
export PATH=/home/chemica/ChemicaWorkspace/toolchain/flutter-sdk/bin:$PATH
flutter pub get
flutter test            # 353 条 fixture + TimeAxis 不变式，必须全绿
flutter run -d web-server --web-port 8081   # 浏览器预览（本机没装 Chrome，用你自己的浏览器打开）
```

> 没装 Flutter 的机器上也能验证规则层：`dart pub get && dart test`
> （测试用 `package:test` 写，两条路都跑得通）。
