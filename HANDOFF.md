# ClassOUT 交接文档

给接手这个项目的 agent。**这份文档是自包含的**，假设你没有读过之前的对话。

---

## 0. 一句话现状

ClassOUT 是一款**纯离线鸿蒙原生（ArkTS）「课表 + 待办 + 计划」三合一 App**，
已成功签名并**安装在用户的真机（华为 nova 15）上运行**，启动无崩溃、种子课表渲染正确、
自动生成待办跑通、提醒已落入系统日历。
**唯一剩下的是：用户还没给出"实际用起来的手感反馈"**——而 UI 手感无法远程验证（原因见 §7）。

---

## 1. 工程位置与常用命令

```bash
cd /home/chemica/ChemicaWorkspace/ClassOUT

./build.sh assembleHap            # 编译（产物 entry/build/default/outputs/default/entry-default-unsigned.hap）
./sign-and-install.sh             # 只签名
./sign-and-install.sh --install   # 签名 + 装到手机
./hdc.sh list targets             # 设备连接检查
./logs.sh --errors                # 看最近的 ERROR/FATAL
./logs.sh                         # 实时滚动 App 日志（tag=ClassOUT）
./tools/watch-logs.sh             # 实时滚动 + 落盘到 .logs/live.log（给 agent 边干活边读用）
./tools/domain-check/run.sh       # 离线断言（当前 188 项，必须全绿）
```

**全量重建也要能过**（每次改完都建议跑一次）：

```bash
./build.sh clean && ./build.sh assembleHap
```

预期：`ERROR: 0`，`WARN: 5`（其中 4 条是故意留的 `getContext` 废弃警告，1 条是 `No signingConfig`，都别"顺手修掉"，见 §7）。

---

## 2. 环境（全部路径与密码）

| 东西 | 位置 |
|---|---|
| 华为官方 CLI 工具链 | `/home/chemica/ChemicaWorkspace/toolchain/cli/command-line-tools` |
| ├ SDK | `<CLI>/sdk/default/openharmony`（**API 18 / 5.1.0**）|
| ├ hvigor / ohpm / hdc / hap-sign-tool | `<CLI>/bin/`、`<CLI>/hvigor/bin/`、`<CLI>/sdk/default/openharmony/toolchains/` |
| └ 自带 node | `<CLI>/tool/node`（v18.20.1）|
| JDK 17（Temurin） | `/home/chemica/ChemicaWorkspace/toolchain/jdk`（`PackageHap` 任务需要 java）|
| hvigor 家目录 | 被 `HVIGOR_USER_HOME` 重定向到 `<项目>/.hvigor`（保持自包含，不写 `$HOME`）|
| 签名材料 | `ClassOUT/signing/`：`classout.p12`（密钥库）、`ClassOUT.cer`、`classoutprofileDebug.p7b`。**口令不在仓库里** —— 在 `signing/local.env`（被 gitignore），模板见 `signing/local.env.example` |

**工具链获取方式**：华为官方 Linux 命令行工具（`commandline-tools-linux-x64-5.1.0.840.zip`，2.15GB），
从 `https://repo.huaweicloud.com/harmonyos/ohpm/5.1.0/` 下载（**免登录**，sha256 已校验）。
26.0.0 版本只在华为登录页上，需要账号。**DevEco Studio 图形 IDE 不支持 Linux 发行版**，
所以整个项目是纯命令行开发，没有 IDE、没有预览器。

> 如果想升到 API 26 的 SDK（拿 64 条代理提醒配额，见 §6），需要用户去华为开发者页面下载 26.0.0 版 CLI。

---

## 3. 真机与签名状态

| 项 | 值 |
|---|---|
| 型号 | `PSN-AL00`（nova 15）|
| 系统 | HarmonyOS `7.0.0.109(SP6C00E105R5P3)`，**API 26**，OpenHarmony 7.0.0.105 |
| UDID | `<UDID>` |
| 设备序列号 | `<设备序列号>` |
| 包名 | `com.chemica.classout` |
| 证书 | 用户实名调试证书，**有效期到 2027-10-13**（证书链：华为根 CA → 开发者关系 CA → 用户）|
| Profile | 调试型，`device-ids` 里就是上面那个 UDID，`acls.allowed-acls: []`（空的，见 §6）|

**调试签名的应用只在「开发者模式」开着时能跑**；鸿蒙手机没有 `.hap` 安装器，装包只能靠 `hdc`。
用户已开启开发者模式 + USB 调试。

---

## 4. 架构与文件地图

> 📐 **计划页正在改版**，设计已与用户逐条确认并定稿在 **`PLAN_REDESIGN.md`**。
> 动 `PlanDayView.ets` 之前**先读那份**；里面记了两条被用户明确否掉的方案
> （内容驱动时间窗、空档折叠），别重新提。状态：设计定稿、尚未编码，
> 第一步是给用户看字号截图（13/14/15vp 三档）。

```
entry/src/main/ets/
├── model/Types.ets              领域类型、北大 12 节作息常量、配色
├── model/WeekMask.ets           周次位掩码（'1'/'0' 字符串，支持 1-16单 / 1-8,10-16 / 1-15(单)）
├── util/DateUtil.ets            日期与分钟换算、相对日期、考试倒计时
├── util/Ctx.ets                 UIAbilityContext 的取法（见 §7 的坑）
├── data/Schema.ets              SQLite 建表（11 张表）
├── data/Db.ets                  连接（Promise 缓存）+ kv + 列迁移 ensureColumn
├── data/TimetableRepo.ets       学期/节次/课程/时段规则/单周覆盖/休息时段
├── data/TodoRepo.ets            模板/待办/黑名单/虚拟课时/计划块
├── data/BackupRepo.ets          全量导出 / 覆盖恢复 / 诊断
├── data/SeedData.ets            ★ 截图转录的课表种子（已核对修正）
├── data/Seeder.ets              首次启动初始化 + 复制上学期
├── domain/Timetable.ets         规则 + 覆盖层 → 某周/某天的课时
├── domain/PlanMath.ets          计划视图纯算术（吸附/夹紧/移位/改时长/找空档/块完成判定）
├── domain/TodoGenerator.ets     ★ 模板变量、ddl 规则、静默补生成（唯一实现，见 §7）
├── domain/Briefing.ets          每日简报正文（纯函数）
├── domain/CalendarReminders.ets ★ 把提醒写进系统日历（代理提醒不可用时的出路）
├── domain/ReminderScheduler.ets 四类提醒的候选构建 + 代理提醒发布 + 预算控制
├── view/TodoInbox.ets           待确认收件箱 / 待办 / 考试 / 新建编辑
├── view/PlanDayView.ets         计划日视图（拖拽、找空档、完成联动）
├── view/CourseManager.ets       课程/时段/模板/学期/节次/休息时段/提醒设置/备份恢复
└── pages/Index.ets              主页面（课表周视图 + 三个标签 + 单周覆盖面板）
```

**数据模型要点**：
- `SessionRule.weeksMask` 是 `'1'/'0'` 字符串，长度 = 学期总周数，天然支持单双周/任意跳周。
- `CourseSession` 有 `originDate`（规则原本排定的日期）——单周覆盖的匹配与撤销都靠它。
- `plan_block` 的 `todo_id` 与 `lesson_id` **只有一个非 0**；取标题/颜色必须走
  `PlanDayView.blockTitle()` / `blockCourseId()`，不要直接读 `todoId`。
- 虚拟课程（`course.is_virtual=1`）没有时段规则，它是一串 `virtual_lesson`，
  排进计划并打勾完成时，与真课下课走**同一条**生成逻辑。

---

## 5. 已验证 vs 未验证（接手第一件事就看这个）

### ✅ 已在真机上验证

| 项 | 证据 |
|---|---|
| 签名 + 安装 | `install bundle successfully`；`bm dump` 显示 `com.chemica.classout` v1.0.0 |
| 启动无崩溃 | `Succeeded in loading the content`；进程长时间存活（`ps -ef \| grep chemica`）|
| 数据库初始化 | `database ready` |
| 种子课表渲染 | 截图与用户原 App 第 6 周完全吻合（课甲 周二1-2 教学楼407 老师甲 …）|
| **待办生成引擎** | `generated todo: 10.13作业 @ 2026-10-13`（命名格式与原 App 一致）|
| **日历提醒** | 首次 `removed=0 added=23`，冷启动 `removed=23 added=23`（幂等）；系统日历里能看到 `12:45 课己 还有 15 分钟上课 · ClassOUT`（13:00 的课，提前量正确）|
| 全新安装路径 | 卸载重装后：种子 → 生成 → 日历同步，全链路正常 |
| **课表页渲染（最近一次复装后）** | 截图确认第 6 周课表格子完整，**两门习题课都在修正后的位置**（课甲习题=周三第10节、课乙习题=周四第10节，绿色虚线框）|
| 底部导航栏 | 三个标签在课表页 / 计划页均完整可见（见下方 bug 表）|

> ⚠️ 关于"用户手机上是不是旧数据"：本机 `bm dump` 的 `installTime` = **2026-10-13 10:25:53**，
> 晚于种子修正时间，且截图确认习题课位置正确。**所以手机上已经是修正版数据**，
> §9 和 TESTING.md 里"你手机上那份是旧的"已经过时，别再让用户手工改。

### 🐞 已由用户实测发现并修复

| 现象 | 根因 | 修复 | 验证程度 |
|---|---|---|---|
| 点底部「待办」（「计划」同病）标签后，**底部导航栏整个消失** | `TodoInbox` / `PlanDayView` 的根节点是 `height('100%')`，而它们是 `Index` 主 `Column` 的**直接子节点**。`height('100%')` 取的是父 Column 的**整个高度**（不是"扣掉兄弟之后剩下的高度"），于是它们占满整屏，把同为子节点的 54vp `TabBar` 顶到屏幕外。「课表」标签页没这个病，因为那里用的是 `Scroll().layoutWeight(1)` | 在 `pages/Index.ets` 里给这两个组件各包一层 `Column().width('100%').layoutWeight(1)`，让它们只吃剩余空间 | 计划页/课表页截图已确认；待办页同一处修复，**待用户点一下确认** |
| 待办拖进网格后**仍留在「待安排」托盘里，可以反复拖出重复块** | `PlanDayView.poolTodos()` 只过滤了 `status === Active`，**漏了"当天已经排过"**。同一个文件里的 `poolLessons()`（虚拟课时托盘）是正确过滤的，所以这是漏改而非设计 | 抽成纯函数 `PlanMath.selectPoolTodos(todos, blocks)`：active 且**当天**没有块才进托盘。`poolTodos()` 改为调用它 | 见下方「关键：只用当天过滤」，离线断言 **188 项全绿**（新增 6 项 + 变异测试验证有效）；**尚未在真机上重拖验证** |

**这条的通用教训**：往 `Index` 主 Column 里加任何新的全屏子组件，**不要给它 `height('100%')`**，
要么用 `layoutWeight(1)`，要么包一层带 `layoutWeight(1)` 的容器。否则就会顶掉 `TabBar`。

**关键：托盘过滤只用「当天」的块，不要改成查全部日期。**
`selectPoolTodos(todos, blocks)` 的 `blocks` 必须是调用方传进来的**当天**块集
（`PlanDayView` 传的是 `listBlocksOn(ctx, this.date)`）。
这样换到明天时待办会重新出现在托盘里，「拆成多块分散在不同天」才仍然可行（TESTING.md 第 15 步）。
改成查全部日期会把多天拆分这个功能废掉。

> 已排的**重复块**是修复前产生的脏数据，修完不会自动消失（本机就有）。让用户在块上长按/点开删掉多余的那几个即可。

### ❌ 未验证（都需要用户动手，见 §7 为什么我做不到）

- **所有 UI 交互**：确认/编辑/删除待办、拖拽待办进网格、拖动色块改时间、
  拖底边改时长、单周覆盖面板、课程编辑、备份导出/恢复。
  （「标签页切换」已由用户实测；「导航栏消失」已修复；「拖拽后托盘不消失」已修复但未真机复验。）
- **手感**：字号大小、拖拽跟手度、按钮点击热区。
- **真实提醒是否响铃**：事件在日历里、带 15 分钟提前量，但"到点弹不弹通知"没人确认过。
- 长时间运行 / 跨天补生成 / 跨周切换的边界。

---

## 6. 最重要的技术结论（必读，否则会重走弯路）

### 6.1 ⚠️ 代理提醒对侧载应用上限是 0 条 —— 实测，不是推测

真机日志：`publish reminder failed: {"code":1700002,"message":"The number of reminders exceeds the limit."}`，
23 条**全部**失败。排查链（每一步都排除了一种可能）：

| 检查 | 结果 | 结论 |
|---|---|---|
| `bm dump -n com.chemica.classout` 的 `reqPermissionStates` | `[0]` | 权限**已授予** |
| SDK 里 `ohos.permission.PUBLISH_AGENT_REMINDER` 定义 | `availableLevel: normal` + `system_grant` | 不需要 ACL |
| 下载的 profile | `acls.allowed-acls: []`，AGC 无申请入口 | **拿不到"代理提醒特权"** |

→ 文档里说的"没有代理提醒特权的应用上限是 0"是真的，**64 条上限是给过审上架应用的**。
**解法：`domain/CalendarReminders.ets`，把提醒写进系统日历**（`WRITE_CALENDAR` 是 normal + user_grant）。
事件用 `description` 打 `ClassOUT` 标记，每次同步先删旧再建新。
代理提醒的代码**保留着**（万一将来 SDK 升级/上架能拿到特权，会自动用上：`published>0` 就不走日历）。

### 6.2 ⚠️ 不要"顺手优化"把上课提醒从日历里去掉

用户的系统日历里本来就有课表（华为日历「PKU 2026 秋学期」），所以我们的上课提醒会重复。
**我明确问过，用户明确选择"全都写，重复就重复"**——因为他要的是那 15 分钟提前量的闹钟。
**"只写作业截止和简报"是被否决过的方案，不要再提。**

### 6.3 UIAbilityContext 的取法（有个隐蔽坑）

用 `EntryAbility.onCreate` 存进 `AppStorage`，页面里先取这份，取不到才回退 `getContext()`。
**绝对不能写成 `abilityContext(getContext(this))`** —— 实参会被无条件求值，
等于把废弃 API 又变成主路径，真被移除时连备份都轮不到用就先崩。
必须是「先取 AppStorage，取不到才调 getContext」。
那 4 条 `getContext has been deprecated` 警告就是这条兜底路径，**别修掉**。

### 6.4 ⚠️ `@Builder` 的参数不是响应式的 —— 要么用 `$$`，要么做成 `@Component`

**用户实测发现**：新建待办界面里点那些胶囊按钮（作业/自学/考试/其他、今天 23:59、
15/30/60 分钟…）**没有任何视觉反应** —— 被点的灰色不变蓝、原本蓝色的不同时变灰。

**根因**：这些控件原先在 4 个文件里各写了一份 `@Builder Chip(text, selected, onTap)`：
`TodoInbox` / `PlanDayView` / `CourseManager` / `Index`（后者叫 `SheetChip`）。
而 **`@Builder` 的参数是按值传入的，首次渲染后就固化了；参数变化不会让 builder 内部重新渲染**。
所以 `selected ? '#2E6BE6' : '#EEF1F6'` 只在第一次渲染时算过一次，之后永远不变 ——
点击时 `this.editCategory` 确实变了（数据是对的），界面却没跟上。

要让 `@Builder` 参数响应式得用 `$$` 语法，而 **`$$` 只支持值类型**，
`onTap: () => void` 这种函数参数根本没法用。所以正解是做真正的自定义组件。

**修复**：抽成 `view/ChipButton.ets` —— 一个 `@Component`，用 `@Prop` 接收 `text`/`selected`/`fontSize`，
`onTap` 作为普通成员（函数不需要参与响应式）。`@Prop` 是单向同步，父组件状态一变就会重渲染。
**37 处调用点**全部改成 `ChipButton({ text, selected, onTap })`（PlanDayView 额外传 `fontSize: LAYOUT.title`）。

**已验证**：装机后用 `uitest uiInput click` 真实点击 + 截图比对 ——
点「15 分钟」后 `60 分钟` 由蓝变灰、`15 分钟` 由灰变蓝；点「作业」后 `其他` 变灰；
点「考试」后 `作业` 变灰且整个表单布局切换。
验证方法见 §7（`uitest` + `dumpLayout`）。

**通用教训**：需要"根据状态变色/变字"的自定义控件，**不要写成 `@Builder`**。
`@Builder` 只适合纯粹由外部参数决定、且自身不需要跟随状态变化的静态片段。
判断标准：**这个片段内部有没有读响应式状态？有就必须是 `@Component`。**

### 6.5 其他 ArkTS / 鸿蒙坑

- **ArkTS 不支持 `as const`**；对象字面量必须有显式声明的类型 → 用静态常量类。
- **`hvigor` 默认写 `$HOME/.hvigor`**；本项目用 `HVIGOR_USER_HOME` 重定向到项目内。
- **`PackageHap` 需要 java**，hvigor 不带 JDK。
- **`CREATE TABLE IF NOT EXISTS` 不会给已有表补列** → `Db.ensureColumn()` 做迁移。
- **通知渠道用 `SERVICE_INFORMATION`**，不是 `SOCIAL_COMMUNICATION`（那是给 IM 的）。
- **北大校本部一天 12 节**（第 9、12 节机动），不是 10 节。
- **鸿蒙不允许后台常驻**（延迟任务最小 2 小时）→「下课立刻生成」实现为
  **下次打开 App 时静默补生成**，时间戳仍记为该节课的下课时刻。
- **SDK 里的 kit 名字别猜**：振动在 `@kit.SensorServiceKit`（不是 `@kit.SensorsKit`）。
  `ls <SDK>/ets/kits/` 一眼就知道。
- **`onTouch` 收不到"父级 Scroll 接管后的 Move 事件"**（实测）。
  所以任何依赖 Move 流来判断手势意图的逻辑（比如"移动了就取消长按"）都不可靠。

### 6.5.1 ⚠️ 触摸事件层 ≠ 手势识别层（这个坑很大，记下来）

判断一个控件和**父级可滚动容器**谁该响应时，必须分清两个层面：

| 层面 | 手段 | 能不能影响 Scroll 的滚动 |
|---|---|---|
| **触摸事件** | `event.stopPropagation()` / `event.preventDefault()` | **不能**（实测拖动时网格照样滚了 78px） |
| **手势识别** | `GestureGroup` / `parallelGesture` / 手势仲裁 API | 能，但机制完全不同 |

**教训**：我曾在触摸事件层反复尝试阻止 Scroll，全部失败，因为 Scroll 的滚动是
**手势识别层**的行为。正确的层面是下面这套：

```ts
// 手势仲裁：每个手势即将被接受时回调，能拿到响应链上**包括父级 Scroll** 的所有识别器
.onGestureRecognizerJudgeBegin(
  (event: BaseGestureEvent, current: GestureRecognizer,
   recognizers: Array<GestureRecognizer>) => GestureJudgeResult)
// GestureJudgeResult: CONTINUE（不干预）| REJECT（否决）| PENDING
// GestureRecognizer.setEnabled(false) 可以直接关掉某个识别器
// shouldBuiltInRecognizerParallelWith() 让**内置手势**（就是 Scroll 的拖动）与你的手势并行
```

**三种挂手势方式的区别（都实测过）**：

| 方式 | 与父级 Scroll 的关系 | 结果 |
|---|---|---|
| `.gesture(GestureGroup(Parallel, LongPress, Pan))` | **抢**手势 | ❌ 从块上起手**完全滚不动**（用户报的 bug） |
| `.onTouch(...)` | 不注册手势，完全不参与竞争 | ✅ 滚动正常，但收不到 Scroll 接管后的 Move |
| `.parallelGesture(LongPressGesture(...))` | 与 Scroll **并行**，被抢走时系统 Cancel | ✅ 滚动正常 + 长按能触发（当前方案） |

---

### 6.6 「所有块完成 → 待办自动完成」必须查跨天

待办可以拆成多块分散在不同天。只查当天的块会把「今天这块做完」误判成「整个待办做完」。
用 `TodoRepo.listBlocksByTodo()` + `PlanMath.allBlocksDone()`。

---

## 7. 远程交互：`uinput` 不行，但 **`uitest uiInput` 行** ✅

### 7.1 ⚠️ 结论已修正（不要再引用旧结论）

**旧结论「UI 只能靠用户手测」是错的。** 之前只试了 `uinput`，而真正能用的是 **`uitest uiInput`**。
已实测：`uitest uiInput click 903 2330` 能把底部标签从「课表」切到「计划」。

```bash
CLI=/home/chemica/ChemicaWorkspace/toolchain/cli/command-line-tools
HDC="$CLI/sdk/default/openharmony/toolchains/hdc"

# 看用法（别猜，参数和 uinput 完全不同）
"$HDC" shell "uitest uiInput help"

# 绝对坐标点击（坐标就是 snapshot_display 截图的像素坐标，1084×2412）
"$HDC" shell "uitest uiInput click 903 2330"

# 还有这些可用：
#   doubleClick / longClick <x> <y>
#   swipe / drag <x1> <y1> <x2> <y2> [velocity]
#   fling <x1> <y1> <x2> <y2> [velocity] [stepLength]
#   dircFling <dir> [velocity]   0=左 1=右 2=上 3=下
#   keyEvent <keyID/Back/Home/Power>
#   inputText <x> <y> <text>   /   text <text>
```

底部标签栏坐标（1084 宽，三格均分）：**课表 ≈ (181, 2330)、待办 ≈ (542, 2330)、计划 ≈ (903, 2330)**。

### 7.1.1 ⚠️ 不要按屏幕尺寸估算坐标 —— 用 `uitest dumpLayout`

上一行的"≈2330"是**错的**，留着当反面教材：按 1084px 三等分 + 估算写出的 y=2330
落在 TabBar 下边界（2328）之外 **2px**，点击会**静默丢失**（`uitest` 仍回 `No Error`）。
当时的症状是"手动点能成、脚本点不成"，我一度误判成"冷启动时序问题"，白折腾了两轮。

**正确做法**：把控件树 dump 下来，读真实 bounds。

```bash
"$HDC" shell "uitest dumpLayout /data/local/tmp/layout.json"   # 实际会存成 layout_<随机数>.json
"$HDC" shell "ls /data/local/tmp/layout_*.json"                # 拿到文件名
"$HDC" file recv /data/local/tmp/layout_XXXX.json .logs/layout.json
```

然后解析出元素真实坐标（注意：**接事件的是外层布局节点，不是 Text 本身** ——
`Text('计划')` 的 `clickable` 是 `false`，真正 `clickable=true` 的是包着它的 `Column`）：

```python
import json
d = json.load(open('.logs/layout.json'))
def walk(n, out):
    if isinstance(n, dict):
        a = n.get('attributes', {})
        b = a.get('bounds', '')
        if a.get('clickable') == 'true':
            out.append((a.get('type'), b, a.get('text', '')))
        for c in n.get('children', []) or []:
            walk(c, out)
    return out
for ty, b, t in walk(d, []):
    print(f'{ty:12} bounds={b:26} text={t!r}')
```

实测结果（供参考，界面改动后会变，**别当常量硬编码**）：

| 元素 | Text 的 bounds | 真正 clickable 的节点 |
|---|---|---|
| 「计划」标签文字 | `[864,2226][943,2272]` | `Column [723,2169][1084,2328]` → 点 **(903, 2249)** |
| 「课表」/「待办」 | 同高 | 同 2328 底边，x 各差 361 |

`dumpLayout` 还能直接告诉你哪些东西**真的可点** —— 排查"按钮点了没反应"时比截图猜强得多。

`uitest` 在设备上位于 `/bin/uitest`，**不需要额外装测试包**。
它注入的是真实触摸事件（实测点错位置会把手机点回桌面，说明确实穿透到系统了）。

### 7.2 `uinput` 为什么不行（留档，别再花时间）

| 手段 | 结果 |
|---|---|
| `uinput -S -c x y`（触控笔点击）| 命令返回 success，**ArkUI 收不到**，标签页不切换 |
| `uinput -T -c x y` | 同上 |
| `uinput -M -m dx dy` + `-c 0` | 鼠标是**相对**移动，坐标不可控；实测把光标甩进手势区触发了回桌面 |
| `uinput -M -g x y x y 100`（绝对坐标 drag，零距离当点击）| 回显 success，**标签页依然没切换** |
| `hdc file recv` 拉数据库 | shell 用户读不到应用沙箱；两个候选路径都不存在 |

**能做**：`snapshot_display` 截图 + `file recv` 拉图（我可以看图）、`hilog` 日志、`aa start` 启动、
`uitest uiInput` 注入交互（**新增**）、`bm dump` 查包、`ps` 查进程、
`aa start -b com.huawei.hmos.calendar -a MainAbility` 打开系统日历截图。

**看数据**：让用户在「管理课程 → 备份与恢复」点「导出备份」，再用
`./hdc.sh file recv /data/app/el2/100/base/com.chemica.classout/haps/entry/files/classout-backup.json ./signing/` 拉下来。
「诊断信息」页里还有**上次启动报告**（种子条数/补生成条数/通知权限/提醒发布结果），让用户截图最快。

> 🧪 **`uitest` 打开了「agent 自己走验收清单」的可能**：`TESTING.md` 里那些"只能手点"的项，
> 现在可以用 `uitest uiInput` 逐项驱动 + 截图比对。**还没有人做过这件事**，值得专门排一轮。
> 注意：拖拽/(PanGesture) 是否也能被 `swipe/drag` 驱动**尚未验证** —— 先试标签点击这类 ClickEvent，
> 再试拖拽。

---

## 8. 离线断言 harness（本项目的核心工程实践）

`tools/domain-check/` 把**不依赖鸿蒙 API 的纯逻辑**抽出来，用本地 tsc 编译后跑断言。
**当前 188 项，必须全绿。**

```bash
./tools/domain-check/run.sh
```

它做了什么：把 `model/`、`util/`、`domain/` 里的纯逻辑复制成 `.ts`（改写 import 路径、
把 `TodoGenerator.ets` 从 `export interface GenerationOutcome` 处切开，只保留纯函数），
用项目本地的 typescript 编译后跑 `test.ts` 的断言。

**为什么值得维护**：这个 App 没法在真机上反复试（装一次要签名+重装，UI 又没法自动点），
所以「算一下」的部分必须能在本地秒验。它已经**实际抓到过 4 个真 bug**：
跨天块完成误判、种子数据错一天、ddl 规则边界、简报正文格式。

**加断言的规矩**：任何新的纯逻辑（计算、格式化、规则）都抽到 `domain/` 下的纯模块里，
再在 `test.ts` 里加断言。**改数据也要能触发断言失败**——这是刻意的，让数据改动必须经过显式确认。

---

## 9. 数据修复状态

`data/SeedData.ets` 里**两门习题课的星期原来各错一天**（我最初从截图底部读不准，被蓝色的 ＋ 按钮挡住了）：

| 课程 | 原来（错） | 现在（已核对）|
|---|---|---|
| 课程甲习题课（教学楼408 老师乙）| 周四 第10节 | **周三 第10节** |
| 课程乙习题课（教学楼406 老师丁）| 周五 第10节 | **周四 第10节** |

两份独立证据一致：用户截图的实际列位置 + 北大官方固定排课「课甲 习题课 周三10-11」。

**已完成**：种子已修正 → 断言更新 → 构建通过 → **已卸载重装到用户手机**（全新数据，日志确认
种子/生成/日历同步全链路正常）。所以用户手机上现在是**正确数据**。

其余转录内容已逐条核对无误（课甲 周二1-2 周四3-4、课乙 周二3-4 周四1-2、课丙 周一5-6 周三3-4、
课丁 周一7-8、课戊 周三5-6 周五3-4、课己 周二5-6、课庚 周三7-8、课程辛 周五5-6、课壬 周五7-8）。

---

## 10. 下一步（优先级从高到低）

1. **计划页改版** —— 设计已定稿在 `PLAN_REDESIGN.md`，用户主动要求的。
   第一步是给用户看字号截图（13/14/15vp 三档），**由他按眼睛定，不要替他定**。
2. **继续拿 UI 手感反馈**。`TESTING.md` 的清单还有大半没走过（F 组的手感问题还没答完）。
   已由用户实测发现并修掉 2 个 bug（导航栏消失、待办拖拽后托盘不消失），都在 §5。
3. **确认提醒真的会响**（事件在日历里、带提前量，但没人确认过到点会不会弹通知）。
4. **`showWeekend` 单独决策**：课表页永远画 7 列，而本学期周末 0 节课，
   等于 28.6% 横向宽度恒空。这是个产品选择（没课的周末要不要藏），
   可能比加视图更划算。**不要顺手改**，问用户。
5. 可选：给日历同步加个开关（用户目前选"全写"，但以后可能想调）。
6. 可选：升级到 API 26 SDK（需要用户登录华为开发者页面下载 26.0.0 CLI），
   可能解锁代理提醒的 64 条配额。

**别做的事**：在没有用户反馈前重构、加功能、换架构。真机上的未知数比代码里的多。

---

## 11. 与这位用户协作的注意点

- **他是编程新手，但学习能力很强**（北大计算机大一，Obsidian + git + nvim 工作流）。
  给操作步骤要**具体到点哪里**，不要只说"配置一下"。
- **他的产品观点很明确，而且经常比"常规做法"更对**（比如"课时是一等公民"这个模型是他提的）。
  拿不准的设计决定**问，不要替他决定**。
- **他讨厌冗长的一次性输出**，设计阶段明确要求过"用问答卡片一次问几个，不要列一大串"。
- **他偏好诚实的进展汇报**：说清"验证过什么/没验证过什么"，不要用"应该没问题"糊过去。
- 已确认的产品决定（不要推翻）：零联网、APK 路线否决、代理提醒→系统日历且**全写**、
  手动录入、不做子任务、ddl 规则可选、静默补生成而非下课时打扰。
