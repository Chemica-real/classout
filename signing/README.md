# 签名（AGC）操作指引

这个目录里已经有**我替你在本地生成的密钥和 CSR**：

| 文件 | 说明 |
|---|---|
| `classout.p12` | 密钥库（含私钥 `classout-debug`）。**不要提交到 git，不要外传** |
| `classout.csr` | 证书签名请求，拿去 AGC 换证书 |
| `classout.cer` | **要你去 AGC 下载后放进来** |
| `classout.p7b` | **要你去 AGC 下载后放进来**（Provision Profile） |

密钥库口令：**不写在这里，也不入库**。在 `signing/local.env` 里设
`CLASS_OUT_KEY_PWD=你的口令`（该文件被 `.gitignore` 挡住），
或直接设同名环境变量。模板见 `signing/local.env.example`。

> 为什么走 CSR：AGC 也能替你生成密钥，但那样私钥在云端产生。本地生成密钥、只上传 CSR，私钥始终不出这台机器。

---

## 第 0 步：手机侧准备

1. **开开发者模式**：设置 → 关于本机 → 连续点「版本号」7 次 → 返回 → 系统和更新 → 开发人员选项 → 打开 **USB 调试**。
2. **取设备 UDID**（手机插上电脑后）：
   ```bash
   ./hdc.sh list targets
   ./hdc.sh shell bm get -u        # 或 bm get --udid
   ```
   记下那串 UDID，第 3 步要填。

## 第 1 步：注册华为开发者账号

- 打开 <https://developer.huawei.com/consumer/cn/>，注册并完成**实名认证**（身份证 / 银行卡 / 人脸，需满 18 周岁）。
- 不实名的调试证书只有 **14 天**有效期；实名后 **1 年**。
- 额度：**3 个调试证书 / 每个账号每年 100 个设备 UDID / 每个应用 100 个 Profile**。

## 第 2 步：在 AGC 建应用 + 传 CSR 换证书

进入 <https://developer.huawei.com/consumer/cn/service/josp/agc/index.html>：

1. **我的项目** → 新建项目 → 项目里 **添加应用**。
   - 应用名称：`ClassOUT`
   - **包名必须填 `com.chemica.classout`**（和 `AppScope/app.json5` 里的 bundleName 完全一致，填错了装不上）
   - 应用类型选 **应用**，分类随意，**不要**勾选需要联网的类别（这是个纯离线单机应用）
2. **证书、App ID 和 Profile** → **证书** → **新增证书** → 选 **调试证书** → 上传 `classout.csr` → 下载得到的 `.cer`，放进本目录。
3. **设备** → **添加设备** → 填第 0 步拿到的 **UDID**。
4. **Profile** → **新增 Profile** → 类型选 **调试** →
   - 选刚建的调试证书
   - 勾上刚添加的设备
   - 下载 `.p7b`，放进本目录。

## 第 3 步：签名并安装

```bash
cd ..
./sign-and-install.sh            # 只签名
./sign-and-install.sh --install  # 签名并 hdc install 到手机
```

---

## 常见坑

- **`code:9568320 error: no signature file`** → hap 还没签名。**这条已在你这台 nova 15 上实测确认**
  （用未签名的包试装就是这个报错），说明手机连接、开发者模式、hdc 安装通道**全部正常**，
  只差签名这一步。跑 `sign-and-install.sh` 即可。
- **`code:9568322 signature verification failed due to not trusted app source`** → 证书/profile 不是华为信任链，或 profile 里没有这台设备的 UDID。
- **profile 里设备列表为空** → 那是「发布」profile，不能侧载，必须用「调试」profile。
- **开启了纯净模式** → 会连 `hdc install` 一起拦，先在设置里关掉。
- **调试签名的应用只在「开发者模式」开着时能跑**。鸿蒙手机上没有 `.hap` 安装器，装包只能靠 `hdc`。
- 包名（bundleName）一旦在 AGC 建了应用就**不能改**，要改就得删掉重建。

## 这台设备已确认的信息

| 项 | 值 |
|---|---|
| 型号 | `PSN-AL00`（nova 15）|
| 品牌 | HUAWEI |
| **API 版本** | **26**（对应 HarmonyOS 7）|
| 软件版本 | `7.0.0.109(SP6C00E105R5P3)` |
| OpenHarmony | `7.0.0.105` |
| UDID | `<UDID>` |
| hdc 连接 | ✅ 正常（`./hdc.sh list targets` 能看到）|

> 注意：因为 API 26，代理提醒上限是 **64 条**（API ≤25 才是 30）。我们的预算按 60 排。

## 要**上架**（发布签名）怎么办？

调试签名这套只够自己/朋友侧载。上架应用市场要用**发布证书 + 发布 Profile**，
而且交上去的是 **`.app`**（app pack）不是 `.hap`：

```bash
export PATH="/home/chemica/ChemicaWorkspace/.locale-shim:$PATH"   # 见 HANDOFF §23.5
./tools/publish-wizard.sh     # ← 交互式向导：开链接、收发布证书/Profile、打并校验发布包
# 或者材料齐了直接：
./sign-release.sh             # release 构建 + 发布签名 + 校验 → dist/ClassOUT-<版本>-release.app
```

- 发布材料放 `signing/release/`（该目录的**材料文件**已被 `.gitignore` 挡住，说明见
  [`release/README.md`](release/README.md)）。
- 发布包**装不上手机**是正常的（发布签名只能上架）。
- 上架前必须先解决的：**图标版权**（已换成自绘，见 `tools/make-icon.py`）、
  **软著 / 电子版权认证**、**APP 备案号**、**隐私政策链接**（仓库根目录 `PRIVACY.md`）。

---

## 装完之后的排错

```bash
./logs.sh              # 实时看 App 自己的日志（Ctrl-C 退出）
./logs.sh --errors     # 看最近的 ERROR/FATAL（ArkTS 崩溃一般在这里）
./logs.sh --dump       # 一次性打印可能相关的日志
./logs.sh --clear      # 清空日志缓冲，重跑 App 前用
```

