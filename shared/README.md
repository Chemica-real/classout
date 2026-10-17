# `shared/` —— 三端唯一的"合同"

ClassOUT 现在是**一个产品、多套实现**：

| 端 | 语言 / UI | 状态 |
|---|---|---|
| 鸿蒙（HarmonyOS NEXT） | ArkTS / ArkUI | ✅ 已上真机，v1.5.0 |
| iOS | Dart / Flutter（规划中） | 🚧 |
| Android | Dart / Flutter（同一份 Dart 代码） | 🚧 |

ArkTS 的代码**不能**跑在 iOS/Android 上，所以"同步开发"同步的不是代码，而是**规则**。
这个目录就是规则本身，避免三端各写一份、慢慢跑偏。

## 这里有什么

| 文件 | 作用 | 谁生成 |
|---|---|---|
| `schema.sql` | 12 张表的权威 DDL（19 条语句含索引） | `tools/sync-contract.sh` 从 `data/Schema.ets` 抽，**别手改** |
| `fixtures/*.json` | **规则的标准答案**：每条是 `{fn, args, expect}` | `tools/fixtures/gen.js` 从鸿蒙端编译产物生成 |
| `backup-v1.md` | 备份 JSON 的字段规范（跨平台挪数据的通道） | 手写 |

## 改规则的工作流（照做就不会漂）

1. 改 `shared/fixtures/*.json` 里的期望值（**先让它红**）；
2. 改鸿蒙端 `domain/*.ets`；
3. `./tools/sync-contract.sh`（跑 524 条断言 + 重新生成 fixtures，看是否一致）；
4. 改 Dart 端 `app_flutter/lib/domain/*.dart`；
5. `cd app_flutter && flutter test`（跑同一批 fixtures）；
6. 两边都绿 → 三端行为一致，可以提交。

## 为什么 fixtures 是"生成"的，不是手写的

因为鸿蒙端这些规则已经被 **524 条断言 + 真机** 验证过了。fixtures 的定位是
**等价性基准**（"iOS 必须和鸿蒙算得一样"），不是"正确性证明"。
手抄 115 组数字必然打错，让机器从已验证的实现里冻结出来才可靠。

⚠️ 反过来要注意：如果鸿蒙端某条规则**本身是错的**，fixtures 会把错误也冻住。
所以发现规则可疑时，先修鸿蒙端 → 再重新生成 fixtures，**别直接改 fixtures 去迁就某一端**。

## 三端怎么跑同一批 fixtures

- **鸿蒙端**：`fixtures` 目前是"导出"的（`./tools/sync-contract.sh`），
  权威断言仍在 `tools/domain-check/test.ts`（524 条）。
- **Dart 端**：`app_flutter/test/fixtures_test.dart` 读 `shared/fixtures/*.json`，
  按 `fn` 名派发到本端实现，逐条比对。
- **以后若换语言/加平台**：新实现只要通过同一批 fixtures，就算"接上了"。
