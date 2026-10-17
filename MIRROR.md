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
| `view/TodoInbox.ets` | `lib/ui/todo_page.dart` | 四段列表、卡片、底部双按钮托盘 |
| `view/TodoInbox.ets` → `EditorPanel()` | `lib/ui/todo_editor.dart` | 右侧 84% 抽屉（标题 + ✕ + 可滚表单） |
| `view/PlanDayView.ets`（`DayBarFloat` / `ColHeadRow` / `HourLines` / `RestBands` / `ClassBlock` / `PlanBlockView` / `DdlMarkers` / `TodoPool`） | `lib/ui/plan_page.dart` | 日/三日、时间轴、课表灰带、斜纹不可排带、计划块、截止标记、待安排托盘；**日期条与托盘都是悬浮浮层**（`topInset` / `tabBarInset`） |
| `view/SettingsPage.ets`（`WallpaperCard`/`MottoCard`/`MotionCard`/`ReminderCard`/…） | `lib/ui/settings_page.dart` | 10 张玻璃卡 |
| `view/PlanDayView.ets` → `BlockEditor()` | `lib/ui/block_editor.dart` | 计划块属性面板：右侧抽屉（日期 ‹›/开始时间 ±/时长 ±/截止/备注/其他块/对半分/标记完成/移除） |
| `domain/Guide.ets` + `view/GuideBar.ets` + `data/GuideRepo.ets` | `lib/domain/guide.dart` + `lib/ui/guide_bar.dart` | 新手演练：步骤脚本（7 步，各自标签页）+ 引导条 + 沙箱（真实数据存 kv `sandbox_backup` → 换演练数据 → 退出还原）；首次启动询问 `guide_prompted` |
| `view/CourseManager.ets` | `lib/ui/course_manager.dart` | 课程管理浮层：学期区块（列表 / 设为当前 / 新建学期，可复制课表）、节次摘要、课程卡、课程编辑抽屉（颜色/开关/时段规则/待办模板/删除课程）、备份与恢复、诊断信息、清空本学期课程（二次确认） |
| `view/ChipButton.ets` | `_Choice`/`_Chip`/`_ChipButton`（各页面内） | 选中 = `#2E6BE6` 底 + 白字 |
| `data/Prefs.ets`（`MOTTO_*`、`mottoUnits`、`clampMottoUnits`、`cleanMotto`） | `lib/domain/motto.dart` | 标语：按显示宽度 32（汉字 2 / 半角 1） |
| `domain/Privacy.ets` | `lib/domain/privacy.dart` + `lib/ui/privacy_page.dart` | 隐私说明（上架材料）：9 节正文、更新日期；设置页「关于 → 隐私说明」打开 |
| `data/Prefs.ets`（`NOTE_EXPANDED_*`） | `lib/data/note_pref.dart` | 备注展开状态：kv `note_expanded`，待办编辑窗与计划块面板共用 |
| `data/BackupRepo.ets`（导出/恢复/诊断） | `lib/data/backup_export.dart` + `backup.dart` | 备份 JSON 序列化（布尔写 1/0）、写文件、诊断摘要；恢复走「设置 → 导入备份」 |
| `data/WallpaperRepo.ets` | `lib/data/wallpaper.dart` | 选图 → 拷进 App 私有目录 → kv `wallpaper_path` |
| `data/*Repo.ets`（`TimetableRepo`/`TodoRepo`/`KvRepo`…） | `lib/data/sqlite_repo.dart` + `repo.dart` | 同一套 SQL schema（`shared/schema.sql`）；`todo_template`、`virtual_lesson` 也读写 |
| `model/Types.ets`（`VirtualLesson` 虚拟课程课时） | `lib/model/types.dart`（`VirtualLesson`） | 数据层 + 课程管理编辑 + **计划页课时池（选中→点网格排入、块完成联动讲次）** ✅ |
| `domain/TodoGenRules.ets`（**纯规则**：`renderTitle` / `computeDdl` / `nextSessionOfCourse`） | `lib/domain/todo_generator.dart` 的上半部分 | 已进 fixtures（`todo_gen.json` 84 条），三端逐条对拍 |
| `domain/TodoGenerator.ets`（读模板/查重/写库，依赖 Context） | `lib/domain/todo_generator.dart` 的下半部分 + `HomeShell._generateMissed` | 下课自动生成待办：`renderTitle`（%C/%c/%D/%d/%W/%T/%N/%R）、6 种 `computeDdl`、`nextSessionOfCourse`、`generateMissedTodos`（去重键 `course|date|template`、只看已下课、备注不带） |
| `domain/*.ets`（`Timetable`/`PlanMath`/`TodoRules`/`Reminders`/`Validate`/`SyncCadence`…） | `lib/domain/*.dart` | 规则逐条搬运，用 `shared/fixtures` 对拍（`./tools/sync-contract.sh`） |

## 三、动效与反馈（逐个对应）

| ArkTS | Dart | 说明 |
|---|---|---|
| `Index.BootLayer` / `bootIn` / `playBootExit` | `lib/ui/boot_screen.dart` ✅ | 启动：打字机 + 步骤清单 + 浓缩成球 + 喷射 + 白球扩张 |
| `TodoInbox` 碎裂（`SHARD_*`） | 待做 | 确认待办时的碎片动画 |
| `PlanDayView` 长按选中 → 拖动、双指缩放 | 两步拖 ✅ + 双指缩放 ✅（`_Block`：长按手势 + 外层 `Listener` 数手指） | 轻点开属性面板；长按 400ms 才拖；两指间距比例 → 改时长 |
| `SettingsPage` toast | `SnackBar` | 鸿蒙端 `showToast`，这边统一 SnackBar |

## 四、还缺的（按 HANDOFF §52.3 的优先级）

1. 课程管理：课程/时段/模板 ✅、学期管理（新建/复制/设为当前）✅、备份导出 ✅
2. 计划页：待安排货架展开、按列截止标记 + 浮层、长按选中两步模型、双指缩放
3. 单周调整（停课/换教室/调课/补课/撤销）、课程管理与模板、备份导出
4. 启动加载页、页头/导航栏真正做成悬浮层
