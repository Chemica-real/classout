# MIRROR —— 鸿蒙端（ArkTS）→ 安卓/iOS 端（Flutter）对照表

> 目标：**一份源码一个家**。凡是"看得见的行为"（配色、圆角、间距、字号、动效曲线、玻璃参数、
> 页面结构、文案、边界规则），都以鸿蒙端为**唯一标准**；Flutter 这边只做搬运，不自己发明。
>
> 改之前先读这张表：你动的那一行，在鸿蒙端对应哪个文件、为什么是那个值。

## 一、设计 token

| ArkTS | Dart | 说明 |
|---|---|---|
| `entry/src/main/ets/view/Glass.ets`（`PAGE_GRADIENT_*`、`GLOW_*`、`GLASS_*`、`WALLPAPER_VEIL`） | `app_flutter/lib/ui/theme.dart` | 页面渐变 `#0f0c29→#302b63→#24243e`、两个光晕 `#FF6FD8`/`#00D4FF`、玻璃 blur 20 / 圆角 20 / 白 0.16 / 描边 0.25·0.14、压暗薄纱 `rgba(6,8,16,0.62)` |
| `view/Motion.ets`（`DUR_*`、曲线、`motionOn`） | `theme.dart`（`dur*`、`*Curve`、`motionOn`、`ambientMotion`） | 抽屉 300ms / 托盘 260 / 列表项 240 / 标签 200 / 碎裂 320 / 就绪浓缩 2400 / 小球停留 1360 / 白球扩张 1500；曲线 easeOutBack、`(0.33,0,0.20,1)`、`(0.22,0,0.32,1.10)`、easeOutCubic |
| `view/Float.ets`（`FLOAT_SIDE/GAP/TOP`、`H_TABBAR`、`H_WEEKROW`、`H_DAYBAR`、`H_COLHEAD`、`DRAWER_W`） | `theme.dart`（`floatSide/floatGap/floatTop`、`h*`、`drawerWidthFactor`） | 浮窗几何：边距 10、间隙 10、顶部 8、导航栏 54、抽屉宽 84% |
| `model/Types.ets`（`COURSE_COLORS`、`WEEKDAY_CN`） | `theme.dart`（`courseColors`/`courseColor`）、`timetable_page.dart`（`weekdayCnList`） | 10 个课程色，逐项同值 |
| `domain/PlanLayout.ets`（`LAYOUT_A..D`，当前生效 C = 14/11/12/14/12/14/10） | 各页面内联字号（计划页 12/11/14…） | 字号档没抽成常量，改时按本表对照 |

## 二、页面与组件

| ArkTS | Dart | 说明 |
|---|---|---|
| `pages/Index.ets` → `Header()` | `lib/ui/course_header.dart` | 三行页头，**课表/待办/计划共用**（设置页没有） |
| `pages/Index.ets` → 课表（`WeekHeaderRow` / `Grid` / `SessionBlock` / `TabBar`） | `lib/ui/timetable_page.dart` + `lib/ui/app_frame.dart` | 周条、时间轴、7 列、课程块；**底部导航与课表/待办页头都是悬浮浮层**（`tabBarInset` / `topInset`，内容从下面滑过） |
| `pages/Index.ets` → `PageBackground`（`Glass.ets`） | `app_frame.dart`（渐变 + 光晕 + 壁纸） | 壁纸数据来自 `data/wallpaper.dart` |
| `pages/Index.ets` → `LoadingScreen()` + `playBootExit()` | `lib/ui/boot_screen.dart` | 启动加载页：网格底纹 / 双圆环 + 雷达 / ClassOUT 字标 + 标语 / 5 步清单 + 打字机 + 五点 / 浓缩成球 + 喷射 + 白球扩张 |
| `view/TodoInbox.ets` | `lib/ui/todo_page.dart` | 四段列表、卡片；默认值对齐 `openNew/openNewExam`（今天 23:59 / 无 / 考试下周 09:00–11:00）；考试保存自动 `syncExamBlock`、删待办连带删计划块；底部双按钮托盘是**浮层**（`Stack` + `Positioned` + `MeasureSize`，列表从它下面滑过）；待确认卡片的删除走**碎裂掉出**（`SHARD_DX/DY/ROT` 四块 16×16，`DUR_SHARD=320`，播完再收起高度）；列表项进出场 `OPACITY + translate y -10`（`DUR_ITEM`）+ `ValueKey(id)` |
| `view/TodoInbox.ets` → `EditorPanel()` | `lib/ui/todo_editor.dart` | 右侧 84% 抽屉（标题 + ✕ + 可滚表单） |
| `view/PlanDayView.ets`（`DayBarFloat` / `ColHeadRow` / `HourLines` / `RestBands` / `ClassBlock` / `PlanBlockView` / `DdlMarkers` / `TodoPool`） | `lib/ui/plan_page.dart` | 日/三日（**三日 = [前一天, 当天, 后一天]，当天在中间**；‹› 永远只挪 1 天）、时间轴（刻度右边缘 40，网格满宽）、课表灰带、斜纹不可排带、计划块、截止标记（**挂在标记下方的无遮罩浮层**，等价 `bindPopup`）、待安排托盘（高度实测 + 展开状态记 kv）；日期条与托盘都是悬浮浮层（`topInset` / `tabBarInset`），内容 padding 含 `DDL_MARK_ALLOW=36` |
| `view/SettingsPage.ets`（`WallpaperCard`/`MottoCard`/`MotionCard`/`ReminderCard`/…） | `lib/ui/settings_page.dart` | 10 张玻璃卡；内容 padding 与鸿蒙同式（`12 + 标题条 + FLOAT_GAP` / `30 + bottomInset`） |
| `view/PlanDayView.ets` → `BlockEditor()` | `lib/ui/block_editor.dart` | 计划块属性面板：右侧抽屉（日期 ‹›/开始时间 ±/时长 ±/截止/备注/其他块/对半分/标记完成/移除） |
| `domain/Guide.ets` + `view/GuideBar.ets` + `data/GuideRepo.ets` | `lib/domain/guide.dart` + `lib/ui/guide_bar.dart` | 新手演练：步骤脚本（7 步，各自标签页）+ 引导条 + 沙箱（真实数据存 kv `sandbox_backup`，**整张 kv 快照存 `sandbox_prefs`** → 换演练数据 → 退出/冷启动整份还原）；首次启动询问 `guide_prompted`；退出回课表页且不弹提示条 |
| `view/CourseManager.ets` | `lib/ui/course_manager.dart` | **整页换内容**（`_mode = list / semester / sections / backup / course`）：全宽玻璃顶栏（关闭 / ‹ 返回）+ 全屏 `backdropBlur` 薄纱；列表三张入口卡 + 课程卡；学期设置（所有学期 / 新建内联表单）、上课节次时间、备份与恢复（固定文件 `classout-backup.json` 路径常显、琥珀「从备份恢复」→ 内联「取消 / 确认恢复」、按表诊断）、课程编辑（颜色/开关/时段规则/待办模板/删除课程） |
| `view/ChipButton.ets` | `_Choice`/`_Chip`/`_ChipButton`（各页面内） | 选中 = `#2E6BE6` 底 + 白字 |
| `data/Prefs.ets`（`MOTTO_*`、`mottoUnits`、`clampMottoUnits`、`cleanMotto`） | `lib/domain/motto.dart` | 标语：按显示宽度 32（汉字 2 / 半角 1） |
| `domain/Privacy.ets` | `lib/domain/privacy.dart` + `lib/ui/privacy_page.dart` | 隐私说明（上架材料）：9 节正文、更新日期；设置页「关于 → 隐私说明」打开 |
| `data/Prefs.ets`（`NOTE_EXPANDED_*`） | `lib/data/note_pref.dart` | 备注展开状态：kv **`noteExpanded`**（旧键 `note_expanded` 只用于迁移读回），待办编辑窗与计划块面板共用 |
| `data/BackupRepo.ets`（导出/恢复/诊断） | `lib/data/backup_export.dart` + `backup.dart` | 备份 JSON 序列化（布尔写 1/0）、固定文件名 `classout-backup.json`、`backupFilePath` / `readBackupText`、`backupSummary` 逐字同文案、`diagnosticsText` 按表一行；恢复 = 读固定文件整份覆盖（安卓额外：长按「从备份恢复」= 粘贴/选文件导入） |
| `data/WallpaperRepo.ets` | `lib/data/wallpaper.dart` + `lib/ui/wallpaper_view.dart` | 选图 → 拷进 App 私有目录 → kv `wallpaper_path`；**显示几何**走 `domain/wallpaper.dart`（见下一行） |
| `domain/Wallpaper.ets`（`wallpaperGeometry` / `clampFocus` / `parseWallpaperFormat`） | `lib/domain/wallpaper.dart`（+ `lib/ui/wallpaper_view.dart` 渲染） | cover → ×zoom → 归一化焦点 × 可动余量；zoom 1..4、焦点 -1..1；所有页面与「调整背景」用同一个函数（所见即所得） |
| `data/*Repo.ets`（`TimetableRepo`/`TodoRepo`/`KvRepo`…） | `lib/data/sqlite_repo.dart` + `repo.dart` | 同一套 SQL schema（`shared/schema.sql`）；`todo_template`、`virtual_lesson` 也读写 |
| `model/Types.ets`（`VirtualLesson` 虚拟课程课时） | `lib/model/types.dart`（`VirtualLesson`） | 数据层 + 课程管理编辑 + **计划页课时池（选中→点网格排入、块完成联动讲次）** ✅ |
| `domain/TodoGenRules.ets`（**纯规则**：`renderTitle` / `computeDdl` / `nextSessionOfCourse`） | `lib/domain/todo_generator.dart` 的上半部分 | 已进 fixtures（`todo_gen.json` 84 条），三端逐条对拍 |
| `data/Seeder.ets`（`ensureSemester` / `ensureRestWindows` / `migrateData` / `cloneCourses`） | `lib/domain/demo_sandbox.dart → buildFirstRunBundle` + `lib/domain/migrate.dart` + `course_manager.dart` 的「复制到当前学期」 | 首次启动：`我的学期`（本周一、16 周）+ 北大 12 节 + 4 段默认不可排，**不内置课表**；老数据迁移：时长 5 分钟归一 / 考试归 0 / 「其他」→「无」 |
| `data/TodoRepo.ets` 的 `blacklist` / `isBlacklisted` | `lib/data/blacklist.dart`（kv `todo_blacklist`） | 删掉的自动生成待办不再补生成；导入备份清空、进沙箱清空（鸿蒙沙箱是全新库） |
| `view/Motion.ets` 的 `loadTrayOpen` / `persistTrayOpen`（kv `planTrayOpen`） | `lib/data/tray_pref.dart` | 计划页「待安排」托盘展开状态跨冷启动保留 |
| `Index.writeRunReport`（kv `last_run_report`） | `lib/data/run_report.dart` + `HomeShell._writeRunReport` | 冷启动写「启动时间 / 学期 / 当前周 / 课程·规则·节次 / 补生成 / 通知权限 / 提醒发布 / 超预算」，备份页诊断块显示 |
| `domain/Validate.ets` 的作息表 / 时段规则 / 模板 / 考试起止校验 | `lib/domain/validate.dart`（`validateSectionTime(s)` / `spanOfRule` / `validateSessionRule` / `findRuleConflicts` / `validateTemplateTitle` / `validateTemplateDdl` / `validateExamRange` / `examRangeOf`） | 课程管理（节次/规则/模板）与待办编辑（考试起止）保存前拦截，文案逐字同 |
| `domain/TodoGenerator.ets`（读模板/查重/写库，依赖 Context） | `lib/domain/todo_generator.dart` 的下半部分 + `HomeShell._generateMissed` | 下课自动生成待办：`renderTitle`（%C/%c/%D/%d/%W/%T/%N/%R）、6 种 `computeDdl`、`nextSessionOfCourse`、`generateMissedTodos`（去重键 `course|date|template`、只看已下课、备注不带） |
| `domain/*.ets`（`Timetable`/`PlanMath`/`TodoRules`/`Reminders`/`Validate`/`SyncCadence`…） | `lib/domain/*.dart` | 规则逐条搬运，用 `shared/fixtures` 对拍（`./tools/sync-contract.sh`） |

## 三、动效与反馈（逐个对应）

| ArkTS | Dart | 说明 |
|---|---|---|
| `Index.BootLayer` / `bootIn` / `playBootExit` | `lib/ui/boot_screen.dart` ✅ | 启动：打字机 + 步骤清单 + 浓缩成球 + 喷射 + 白球扩张 |
| `TodoInbox` 碎裂（`SHARD_*`） | `todo_page.dart`（`_PendingCardState`）✅ | 确认删除待办：四块碎片飞散旋转 + 本体缩到 0.86 淡出（`DUR_SHARD=320`）→ 高度收起（`DUR_ITEM=240`）→ 才落库；动效关掉时直接删 |
| 列表项 `transition(OPACITY + translate y -10, DUR_ITEM)` | `todo_page.dart`（`_ItemFx`）✅ | 待确认卡 / 待办行进场淡入下滑、退场淡出上滑；「确认」「点○完成」都先播完再落库；关动效瞬切 |
| `PlanDayView` 长按选中 → 拖动、双指缩放 | 两步拖 ✅ + 双指缩放 ✅（`_Block`：长按手势 + 外层 `Listener` 数手指） | 轻点开属性面板；长按 400ms 才拖；两指间距比例 → 改时长 |
| `SettingsPage` toast | `lib/ui/inline_toast.dart`（`InlineToastMixin`） | 鸿蒙端 `showToast` 是**内容顶部一行蓝字**（2.2 秒），不是 SnackBar（SnackBar 会盖住悬浮导航栏） |

## 四、还没对齐的（截至 HANDOFF §125）

1. 双机同屏**第一轮已做完**（§122：课表 / 待办 / 计划 / 设置 / 课程管理 / 备份 / 课程编辑）；
   子页（单周调整、补课、计划块面板、调整背景、规则/模板弹窗）还需要一轮同页对照。
2. **字体度量**：HarmonyOS Sans 与 Android 系统字体行高/字宽不同（窄块换行、小字行高差 2–3px）；
   要完全一致只能内嵌鸿蒙字体（授权/体积问题，没做）。
3. 底部安全区：两端系统导航区高度不同，"距底 10vp"的悬浮导航栏在截图里会差 ~43px（平台差异）。
4. 双指缩放：逻辑有单测 + fixtures，真机多指手测待做（`adb input` 只能单指）。
5. 玻璃浮窗滚动时偶发重影（Impeller + BackdropFilter 瞬态，HANDOFF §111）。
6. 版本号、提醒诊断/日历、长按导入：都是**平台性差异**（HANDOFF §117.2 / §118.3 / §122.6）。
