# 备份 JSON 格式 v1（跨平台数据通道）

ClassOUT 的「管理课程 → 备份与恢复 → 导出备份」产出**纯 JSON**，不含任何平台相关的二进制。
这意味着：**鸿蒙版导出的文件，iOS/Android 版必须能直接导入**，反之亦然。
这也是最省事的跨平台验收方式（比逐个字段抄界面可靠得多）。

## 顶层

```json
{
  "app": "ClassOUT",
  "version": 1,
  "exportedAt": "2026-10-16",
  "semesters": [...],
  "sectionTimes": [...],
  "courses": [...],
  "rules": [...],
  "overrides": [...],
  "templates": [...],
  "todos": [...],
  "lessons": [...],
  "blocks": [...],
  "restWindows": [...]
}
```

- `app` 固定 `"ClassOUT"`；导入时校验，不认识就报错，别猜。
- `version` 是**格式版本**，不是 App 版本。当前 `1`。
- `exportedAt` 是 `YYYY-MM-DD`（仅展示用，不参与导入逻辑）。
- 数组里的 `id` 是**导出那一刻的自增主键**，导入时要重建映射（见下）。

## 各实体的字段

| 数组 | 字段 |
|---|---|
| `semesters` | `id, name, startDate, totalWeeks, firstDayOfWeek, showWeekend` |
| `sectionTimes` | `semesterId, section, startMin, endMin, flexible` |
| `courses` | `id, semesterId, name, shortName, teacher, location, colorIndex, autoTodoEnabled, isVirtual, note` |
| `rules` | `id, courseId, weekday, startSection, endSection, weeksMask, location, isQuiz` |
| `overrides` | `id, courseId, date, kind, newDate, newStartSection, newEndSection, newLocation` |
| `templates` | `id, courseId, sortOrder, enabled, titleTemplate, ddlRule, ddlParam, estimateMin, category, submitChannel, note` |
| `todos` | `id, title, courseId, category, priority, ddl, endAt, estimateMin, status, source, generationKey, note, submitChannel, repeatRule, photos, createdAt, confirmedAt, doneAt` |
| `lessons` | `id, courseId, seq, title, done, doneAt` |
| `blocks` | `id, todoId, lessonId, date, startMin, endMin, done` |
| `restWindows` | `id, weekday, startMin, endMin, label` |

（`todo_blacklist` 与 `virtual_lesson` 目前只在库里，不进备份；要进就先在这里加。）

## 导入规则（三端必须一致）

1. **整份替换**：导入 = 清空现有数据再写入（不是合并）。鸿蒙端现状如此。
2. **外键重映射**：先按出现顺序给 `semesters/courses/todos` 分配新自增 id，
   再把 `semesterId / courseId / todoId` 按旧→新映射改写。
3. **不认识的多余字段**：忽略，不要报错（前向兼容）。
4. **缺字段**：按 schema 的 `DEFAULT` 补（见 `schema.sql`），不要崩。
5. **`version` 比本端新**：直接拒绝并提示"备份来自更新版本"。

## 什么时候升到 v2

只有当**删除/重命名字段**或**改变语义**时才升版本。加字段不升版本（规则 3/4 已覆盖）。
升到 v2 时三端要同时支持读 v1（老备份不能变砖）。
