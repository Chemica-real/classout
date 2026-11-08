# ClassOUT Android 版交付说明

- 版本：`1.10.0` / versionCode `1010000`
- 包名：`com.chemica.classout`
- 最低系统：Android 9（API 28）
- 安装包：`app_flutter/build/app/outputs/flutter-apk/app-release.apk`（78.1MB）
- 签名：release 签名，可侧载；未上架应用商店
- 设备验收：PFTM10 / Android 14

## 已对齐的功能

| 模块 | 状态 | 真机验收 |
|---|---|---|
| 课表、周切换、页头 | 完成 | 是 |
| Todo：课程筛选、排序、待确认、考试、已完成、恢复/删除 | 完成 | 是 |
| 计划：日/三日、时间轴、灰带、计划块、两页待安排托盘、选中白框、拖动半透明、红线 | 完成 | 是 |
| 虚拟课程：文件夹、完成态、课时页、右侧编辑抽屉、打勾生成待办 | 完成 | 是 |
| 设置：5 组行列表、全部子页、SVG 图标 | 完成 | 是 |
| 学科调色盘：10 色 HSV 编辑、全局联动 | 完成 | 是（测试 + 真机入口） |
| 本地通知：权限、渠道、测试提醒、点击回 App | 完成 | 是 |
| 系统日历：可选开关、写入、关闭清理 | 完成 | 是 |
| 备份/恢复/重置前自动备份 | 完成 | 是（重置确认框） |
| 启动：快速启动、默认页、完整过场 | 完成 | 是 |
| 底部导航 1 秒冷却 | 完成 | 是 |
| HarmonyOS Sans SC 字体 | 完成 | 是 |

## 回归数据

- `flutter test`：**1356 项全过**
- `flutter analyze`：无问题
- 真机常亮：`mHoldScreenWindow=ClassOUT/MainActivity`
- 测试期间未 push 远端

## 已知边界

- 没有鸿蒙真机同时在线，视觉对照基于现有鸿蒙截图与 ArkTS 源尺寸；模糊/系统栏仍属平台差异。
- 设置行已用鸿蒙 SVG；少数非设置页仍用 Material 图标。
- 日历同步写的是系统日历的 ClassOUT 标记事件；关闭时只删带标记的事件。

## 安装

```bash
adb install -r app_flutter/build/app/outputs/flutter-apk/app-release.apk
```

首次启动可在设置 → 启动里选择默认页；快速启动默认开启。
