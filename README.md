# ClassOUT

纯离线的鸿蒙原生「**课表 + 待办 + 计划**」三合一 App。为 Chemica_（北大 2026 级计算机）的个人使用习惯定制。

目标设备：华为 nova 15（PSN-AL00），HarmonyOS 7.0.0（API 26）。
**零联网**：不申请网络权限，不抓教务、不抓教学网。

---

## 这版和别的课表 App 不一样的地方

现成课表 App 的作业模块是「手动新建 + 扁平 ddl 列表」。ClassOUT 换掉了这个模型：

- **下课自动生成待办**：每门课可以配生成模板（如 `%D作业`），课时结束后自动生成，先落进**待确认收件箱**，你确认/改名/改截止/删除；删了就记住不再生成。
  （调研确认：**没有任何一款国产课表 App 做到这件事**。）
- **待办 → 计划**：待办可以定下时间排进计划，变成时间块；计划界面同时画出课表块、计划块和当天所有 ddl。
- **课时是一等公民**：真课课时由规则排出；虚拟课程（CS106L 那种）是一串等着被分配的课时，打勾完成后触发同一套模板。

## 当前状态

| 模块 | 状态 |
|---|---|
| 命令行构建链（Ubuntu + 华为官方 CLI，无 IDE） | ✅ 通 |
| 数据层（SQLite：学期/节次/课程/规则/单周覆盖/模板/待办/计划块/黑名单） | ✅ |
| 课表周视图（自定义 12 节 + 周次掩码 + 今日高亮） | ✅ |
| 单周覆盖：点课格子即可停课 / 换教室 / 调课 / 补课，可逐条撤销 | ✅ 只改某一周，不动规则；「本周调整 N」可查可撤 |
| 待办：模板静默补生成 → 待确认收件箱 → 确认/删除/手动新建 | ✅ |
| 计划：日视图时间网格、拖动移位、拖底边改时长、拖待办进网格、块打勾联动待办完成 | ✅ |
| 一键找空档（⚡ 跳过课表与休息时段） | ✅ 休息时段可在「管理课程 → 休息时段」增删改 |
| 提醒：四类（上课前 / 截止 / 计划块 / 每日简报） | ✅ **走系统日历**。代理提醒对侧载应用上限为 0（实测 1700002），详见「已知坑」|
| 每日简报 + 提醒设置 | ✅ 每天早上一条「今天几节课 + 今天截止什么」；时间与上课提前量可调 |
| 课程/时段/模板编辑 UI（手动录入） | ✅ 增删改课程、配时段规则、配生成模板、一键重置为种子 |
| 自定义节次时间编辑器 | ✅ 12 节起止时间随便改、可加第 13 节、机动节次开关 |
| 多学期与「复制上学期」 | ✅ 新建学期并切换、从其他学期克隆课表与模板 |
| 虚拟课程（CS106L 那种不定时上课的） | ✅ 一讲一讲等着被排进计划；课时打勾完成 → 跟真课下课一样触发生成模板 |
| 备份与恢复 + 诊断 | ✅ 全量导出 JSON、整份覆盖恢复、各表条数、**上次启动报告**（种子/补生成/提醒发布结果）|
| 考试 | ✅ 独立类型 + 倒计时（还有 N 天）+ 考场座位；自动进每日简报 |
| 领域逻辑离线断言（188 项） | ✅ 全通过：ddl 对照截图实证、拖拽吸附夹紧、找空档避开午休、覆盖层、简报正文、备份往返、考试倒计时、跨天块完成判定 |
| **真机验证** | ❌ **代码从未在真机上跑过**（缺 AGC 签名） |
| v1.1 清单 | ✅ 已清空：虚拟课程、每日简报、备份/恢复、考试都已完成 |

## 构建

```bash
./build.sh assembleHap     # 产物：entry/build/default/outputs/default/entry-default-unsigned.hap
./build.sh clean
./build.sh --help          # 全部任务
```

依赖（都在 `../toolchain/` 下，已就位）：

- 华为 **Command Line Tools for Linux x64** 5.1.0.840（含 SDK API 18、hvigor 5.18.5、ohpm、hdc、hap-sign-tool、自带 node 18）
- **JDK 17**（Temurin，`PackageHap` 任务需要 java；hvigor 不带 JDK）

环境变量可覆盖：`CLASS_OUT_CLI_HOME`、`HVIGOR_USER_HOME`、`JAVA_HOME`。

> 为什么不用 DevEco Studio：官方 IDE 只支持 Windows/macOS。华为官方发布的 Linux 命令行工具能跑通
> `hvigorw assembleHap` + 签名 + `hdc install` 全流程，所以开发就在 Ubuntu 上做。

## 离线验证领域逻辑

周次掩码、排课计算、模板渲染、ddl 规则、拖拽吸附、找空档都是纯函数，不碰鸿蒙 API，所以可以脱离真机验证：

```bash
./tools/domain-check/run.sh      # 188 项断言
```

它把 `model/`、`util/`、`domain/` 里的纯逻辑抽成 `.ts`，用本地 tsc 编译后跑断言。
**ddl 一节直接对照截图实测数据**：课甲 → `10/14 23:59`、课乙 → `10/15`、课丁 → `10/18`、
课丙 → `10/19`，作业名 `10.13作业` —— 全部一致。

## 签名与安装

```bash
./sign-and-install.sh --install
```

`signing/` 里已经有本地生成的密钥库和 CSR。**还缺 `classout.cer` 与 `classout.p7b`**，
这两个必须由本人实名注册华为开发者账号后在 AGC 下载 —— 步骤见 `signing/README.md`。

装到手机后如果行为不对：

```bash
./logs.sh --errors     # 看最近的 ERROR / FATAL（ArkTS 崩溃一般在这里）
./logs.sh              # 实时滚动 App 自己的日志（tag=ClassOUT）
./logs.sh --clear      # 重跑 App 前清一下缓冲
```

> 已实测：用未签名的包试装，真机回报 `code:9568320 error: no signature file`。
> 说明手机连接、开发者模式、hdc 安装通道**全部正常**，只差签名这一步。

**装到手机后如果哪里不对，最快的反馈方式**：打开「管理课程 → 备份与恢复」，
把「诊断信息」（含上次启动报告）截图发出来 —— 里面直接写着种子写入条数、补生成待办条数、
通知权限是否开启、四类提醒各发布了几条、有没有超预算。比抓日志快得多。

## 目录结构

```
entry/src/main/ets/
├── model/Types.ets              领域类型、北大 12 节作息、配色
├── model/WeekMask.ets           周次掩码（单双周/多段周次/跳周）
├── util/DateUtil.ets            日期与分钟换算
├── data/Schema.ets              SQLite 建表
├── data/Db.ets                  连接与 kv
├── data/TimetableRepo.ets       学期/节次/课程/规则/覆盖的读写
├── data/TodoRepo.ets            模板/待办/黑名单/计划块的读写
├── data/SeedData.ets            截图转录的课表种子（⚠️ 待核对）
├── data/Seeder.ets              首次启动初始化
├── data/BackupRepo.ets          全量备份 / 恢复 / 诊断
├── domain/Timetable.ets         规则 + 覆盖层 → 某周/某天的课时
├── domain/PlanMath.ets          计划视图的纯算术（吸附/夹紧/移位/改时长/找空档）
├── domain/Briefing.ets          每日简报正文（纯函数，可离线断言）
├── domain/CalendarReminders.ets 把提醒写进系统日历（代理提醒不可用时的唯一出路）
├── domain/Backup.ets            备份格式定义与序列化/校验（纯函数，可离线断言）
├── domain/TodoGenerator.ets     模板变量、ddl 规则、静默补生成
├── domain/ReminderScheduler.ets 代理提醒滚动窗口与预算
├── view/TodoInbox.ets           待确认收件箱 + 手动新建
├── view/PlanDayView.ets         计划日视图
├── view/CourseManager.ets       课程/时段/模板编辑 + 学期与复制上学期
└── pages/Index.ets              主页面（课表/待办/计划）

tools/domain-check/              纯逻辑离线断言（./run.sh）
```

## 已知坑（踩过的，记下来免得再踩）

- **⚠️ 代理提醒（reminderAgentManager）对侧载应用上限是 0 条 —— 实测结论，不是推测。**
  真机日志：`publish reminder failed: {"code":1700002,"message":"The number of reminders exceeds the limit."}`，
  23 条**全部**失败。排查过程：`bm dump` 显示 `reqPermissionStates: [0]`（权限**已授予**）、
  SDK 里该权限是 `availableLevel: normal` + `system_grant`（不需要 ACL）、
  profile 里 `acls.allowed-acls: []` 且 AGC 没有申请入口
  → 这是文档里说的「代理提醒特权」，**个人侧载应用拿不到，64 条上限是给过审应用的**。
  **解法：改用系统日历承载提醒**（`domain/CalendarReminders.ets`）。
  `WRITE_CALENDAR` 是 `normal + user_grant`，弹框授权即可；无限条数、不依赖应用存活。
  事件用 `description` 打 `ClassOUT` 标记，每次同步先删旧的再建新的。
  实测：首次 `removed=0 added=23`，冷启动后 `removed=23 added=23`（幂等、不堆积）。
  代价：事件会出现在系统日历里 —— 对课表和作业截止来说通常反而是好事。
  - **已确认的产品决定（2026-10-13）**：用户的系统日历里本来就有课表（华为日历「PKU 2026 秋学期」），
    但用户明确选择**四类提醒全部写入系统日历**（"重复就重复"），因为我们要的是那 15 分钟提前量的闹钟。
    **不要"顺手优化"成只写作业截止和简报** —— 那是被明确否决过的方案。
  - 真机验证：日历里能看到 `12:45 课己 还有 15 分钟上课 · ClassOUT`（13:00 的课，提前量正确）。
- **ArkTS 不支持 `as const`**，对象字面量必须有显式声明的类型 → 用静态常量类。
- **UIAbilityContext 的拿法**：在 `EntryAbility.onCreate` 里存进 `AppStorage`，页面里优先取这份；
  只有取不到时才退回已废弃的 `getContext()`。所以 `Index/TodoInbox/PlanDayView/CourseManager`
  各有 **1 条 `getContext` 废弃警告，是故意留的兜底，不要"顺手修掉"**。
  ⚠️ **别写成 `abilityContext(getContext(this))`**：实参会被无条件求值，等于把废弃 API 又变成主路径，
  真被移除时连备份都轮不到用就先崩了。必须是「先取 AppStorage，取不到才调 getContext」。
- **代理提醒用 `SERVICE_INFORMATION`** 而不是 `SOCIAL_COMMUNICATION`：后者是给 IM 类应用的，
  工具类应用发上去可能被判权限不足。
- **`Db.get` 用 Promise 缓存**：多个组件同时初始化时不会重复开库、重复建表。
- **`plan_block` 的 `todo_id` 与 `lesson_id` 只有一个非 0**：前者是普通待办排的块，
  后者是虚拟课时排的块。取标题/颜色一律走 `blockTitle()` / `blockCourseId()`，不要直接读 `todoId`。
- **「所有块完成 → 待办自动完成」必须查跨全部日期的块**（`TodoRepo.listBlocksByTodo` + `PlanMath.allBlocksDone`）。
  一个待办本来就可以拆成多块分散在不同天，只查当天的块会把「今天这块做完」误判成「整个待办做完」。
- **「课时结束触发模板」只有一条实现**：`domain/TodoGenerator.ets` 里的 `generateForSession()`。
  真课下课（`generateMissedTodos` 里补生成）和虚拟课时完成（`generateForLesson`）都走它，
  去重键是 `课程|日期|模板`，所以重复触发不会生成两份。
- **`hvigor` 要写 `$HOME/.hvigor`**；本项目用 `HVIGOR_USER_HOME` 把它重定向到 `<项目>/.hvigor`，保持自包含。
- **API 26 上代理提醒上限是 64 条**（API ≤25 是 30）；没有「代理提醒特权」的应用上限是 **0**，需要申请。
- **鸿蒙不允许后台常驻**（延迟任务最小间隔 2 小时），所以「下课立刻生成」实现为**下次打开 App 时静默补生成**，
  时间戳仍记为该节课的下课时间。
- 北大校本部是**一天 12 节**（第 9、12 节为机动），不是 10 节。
