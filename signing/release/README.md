# 发布（上架）签名材料放这里

这个目录**不在 git 里**（`.gitignore` 挡着 `/signing/release/`）。
上架要用的三样东西放进来，`./sign-release.sh` 就认这三个扩展名。

| 文件 | 从哪来 | 说明 |
|---|---|---|
| `*.p12` | 本地生成，或**直接复制** `../classout.p12` | 发布密钥库。复用调试那个也合法（同一个应用可以只有一把私钥），此时别名是 `classout-debug` |
| `*.cer` | AGC 下载 | **发布证书**（类型选「发布」）。上传 CSR 后生成 |
| `*.p7b` | AGC 下载 | **发布 Profile**（类型选「发布」）。**发布 Profile 不需要 UDID 白名单**，这也是它和调试 Profile 最大的区别 |

口令仍然只在 `../local.env` 里（`CLASS_OUT_KEY_PWD`，或单独给发布设 `CLASS_OUT_RELEASE_KEY_PWD`）。

---

## 怎么拿到发布证书和 Profile

1. 打开 <https://developer.huawei.com/consumer/cn/service/josp/agc/index.html> →
   **我的项目** → 你的项目 → **添加应用**（如果还没建）。
   - 平台选 **APP（HarmonyOS）**
   - **应用包名必须和 `AppScope/app.json5` 里的 `bundleName` 完全一致**：`com.chemica.classout`
   - 包名**创建后不能改**，填错只能删了重建
2. 左侧 **证书、App ID 和 Profile → 证书** → **新增证书**：
   - 类型选 **发布证书**
   - 上传 CSR：用现成的 `../classout.csr`；没有就本地重新生成一把（见下）
   - 下载 `.cer` → 放进本目录
   - ⚠️ 一个账号最多 **3 个证书**，别乱建
3. **Profile** → **新增 Profile**：
   - 类型选 **发布**
   - 选刚建的发布证书、选应用（包名要对上）
   - 下载 `.p7b` → 放进本目录
   - 发布 Profile **不用勾设备**（勾了设备的那是调试/测试用的）
4. 打发布包：
   ```bash
   export PATH="/home/chemica/ChemicaWorkspace/.locale-shim:$PATH"   # 见 HANDOFF §23.5
   ./sign-release.sh
   # 产物：dist/ClassOUT-<版本号>-release.app
   ```

> 想复用调试那套私钥（最省事）：`cp ../classout.p12 .`，然后
> `echo 'CLASS_OUT_RELEASE_KEY_ALIAS=classout-debug' >> ../local.env`。

## 重新生成一把发布密钥库 + CSR（可选）

本机没有 DevEco，用 SDK 自带的 `hap-sign-tool` 生成：

```bash
CLI=/home/chemica/ChemicaWorkspace/toolchain/cli/command-line-tools
JAVA=/home/chemica/ChemicaWorkspace/toolchain/jdk/bin/java
JAR="$CLI/sdk/default/openharmony/toolchains/lib/hap-sign-tool.jar"

# 1) 密钥库（记好口令与别名）
"$JAVA" -jar "$JAR" generate-keypair \
  -keyAlias "classout-release" -keyPwd '你的口令' \
  -keyAlg ECC -keySize NIST-P-256 \
  -keystoreFile signing/release/classout-release.p12 -keystorePwd '你的口令'

# 2) CSR（subject 里**不能用中文**，AGC 会报错）
"$JAVA" -jar "$JAR" generate-csr \
  -keyAlias "classout-release" -keyPwd '你的口令' \
  -subject "C=CN,O=YourName,OU=Dev,CN=YourName" \
  -signAlg SHA256withECDSA \
  -keystoreFile signing/release/classout-release.p12 -keystorePwd '你的口令' \
  -outFile signing/release/classout-release.csr
```

## 打出来的包为什么装不上手机？

**正常。** 发布证书/Profile 签出来的包**只能上架、不能侧载运行**（这也是判断"我是不是
真的签成发布包了"的一个土办法）。要在自己手机上跑，用 `./sign-and-install.sh`（调试签名）。

## 上架前必须先解决的（详情见 HANDOFF §22.6）

| 项 | 状态 |
|---|---|
| **图标** | ✅ 已换成完全自绘（`tools/make-icon.py`；AGC 用 `docs/store/app-icon-1024.png` / `-216.png`） |
| **软著 / 电子版权认证** | ❌ 没有，个人开发者上架要交；办理有周期，越早越好 |
| **APP 备案号** | ❌ 没有，境内分发要求先备案 |
| **隐私政策** | ✅ 公网可开：<https://gitee.com/the-person-on-the-tree/classout/blob/master/PRIVACY.md>；用户权利页：<https://gitee.com/the-person-on-the-tree/classout/blob/master/PRIVACY_RIGHTS.md> |
| **发布证书 / 发布 Profile** | ❌ `signing/release/` 里还没有（只有本说明）；去 AGC 申请后放进来 |
| 签名材料口令 | ✅ 口令与私钥都已被 `.gitignore` 挡住 |

> 完整的上架逐条清单、AGC 填报文案、权限/隐私标签对照、截图建议见仓库根目录 **`STORE.md`**。
