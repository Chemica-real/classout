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

## 怎么验 iOS（没有 Mac 也能验一半）

这台开发机是 Linux，**不能** `flutter build ios`，也跑不了 iOS 模拟器。两条替代路：

### a) iPad + Safari 打开 web 构建（验 UI/触摸，今天就能做）

```bash
flutter build web --release --pwa-strategy=none
(cd build/web && python3 -m http.server 8081)   # 监听 0.0.0.0，局域网可访问
# iPad 上和电脑连同一个 Wi-Fi/热点，Safari 打开 http://<电脑局域网IP>:8081/
```
能验：布局、触摸目标、滚动、中文渲染、安全区、键盘遮挡。
不能验：SQLite、通知（web 走内存仓库）。

### b) GitHub Actions 的 macOS runner + iOS 模拟器（验"能不能在 iOS 上跑"）

仓库里的 `.github/workflows/ios-sim.yml` 会在 macOS 上：
`flutter build ios --simulator --no-codesign` → 装进模拟器 → 启动 → 截两张图上传。
**不需要 Apple 开发者账号、不需要 iPhone，public 仓库免费。**

用之前要把仓库镜像到 GitHub 一次：

```bash
git remote add github git@github.com:<你的账号>/classout.git
git push github master --tags        # 以后每次两边都推一次（或只推 github 跑 CI）
```

> 注意：**private 仓库的 macOS 分钟数是 10 倍计费**（免费额度 2000 分钟/月 → 实际 200 分钟），
> 所以想免费跑就用 public 仓库。
