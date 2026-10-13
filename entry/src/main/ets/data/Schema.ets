/** ClassOUT 数据库 schema（SQLite / relationalStore） */

export const DB_NAME: string = 'classout.db';

export const SCHEMA_SQL: string[] = [
  `CREATE TABLE IF NOT EXISTS semester (
     id INTEGER PRIMARY KEY AUTOINCREMENT,
     name TEXT NOT NULL,
     start_date TEXT NOT NULL,
     total_weeks INTEGER NOT NULL,
     first_day_of_week INTEGER NOT NULL DEFAULT 1,
     show_weekend INTEGER NOT NULL DEFAULT 1
   )`,

  `CREATE TABLE IF NOT EXISTS section_time (
     semester_id INTEGER NOT NULL,
     section INTEGER NOT NULL,
     start_min INTEGER NOT NULL,
     end_min INTEGER NOT NULL,
     flexible INTEGER NOT NULL DEFAULT 0,
     PRIMARY KEY (semester_id, section)
   )`,

  `CREATE TABLE IF NOT EXISTS course (
     id INTEGER PRIMARY KEY AUTOINCREMENT,
     semester_id INTEGER NOT NULL,
     name TEXT NOT NULL,
     short_name TEXT NOT NULL DEFAULT '',
     teacher TEXT NOT NULL DEFAULT '',
     location TEXT NOT NULL DEFAULT '',
     color_index INTEGER NOT NULL DEFAULT 0,
     auto_todo_enabled INTEGER NOT NULL DEFAULT 1,
     is_virtual INTEGER NOT NULL DEFAULT 0,
     note TEXT NOT NULL DEFAULT ''
   )`,

  `CREATE TABLE IF NOT EXISTS session_rule (
     id INTEGER PRIMARY KEY AUTOINCREMENT,
     course_id INTEGER NOT NULL,
     weekday INTEGER NOT NULL,
     start_section INTEGER NOT NULL,
     end_section INTEGER NOT NULL,
     weeks_mask TEXT NOT NULL,
     location TEXT NOT NULL DEFAULT '',
     is_quiz INTEGER NOT NULL DEFAULT 0
   )`,

  `CREATE TABLE IF NOT EXISTS session_override (
     id INTEGER PRIMARY KEY AUTOINCREMENT,
     course_id INTEGER NOT NULL,
     date TEXT NOT NULL,
     kind TEXT NOT NULL,
     new_date TEXT NOT NULL DEFAULT '',
     new_start_section INTEGER NOT NULL DEFAULT 0,
     new_end_section INTEGER NOT NULL DEFAULT 0,
     new_location TEXT NOT NULL DEFAULT ''
   )`,

  `CREATE TABLE IF NOT EXISTS todo_template (
     id INTEGER PRIMARY KEY AUTOINCREMENT,
     course_id INTEGER NOT NULL,
     sort_order INTEGER NOT NULL DEFAULT 0,
     enabled INTEGER NOT NULL DEFAULT 1,
     title_template TEXT NOT NULL,
     ddl_rule TEXT NOT NULL DEFAULT 'next_session',
     ddl_param TEXT NOT NULL DEFAULT '',
     estimate_min INTEGER NOT NULL DEFAULT 60,
     category TEXT NOT NULL DEFAULT 'homework',
     submit_channel TEXT NOT NULL DEFAULT '',
     note TEXT NOT NULL DEFAULT ''
   )`,

  `CREATE TABLE IF NOT EXISTS todo (
     id INTEGER PRIMARY KEY AUTOINCREMENT,
     title TEXT NOT NULL,
     course_id INTEGER NOT NULL DEFAULT 0,
     category TEXT NOT NULL DEFAULT 'homework',
     priority INTEGER NOT NULL DEFAULT 1,
     ddl TEXT NOT NULL DEFAULT '',
     estimate_min INTEGER NOT NULL DEFAULT 60,
     status TEXT NOT NULL DEFAULT 'active',
     source TEXT NOT NULL DEFAULT 'manual',
     generation_key TEXT NOT NULL DEFAULT '',
     note TEXT NOT NULL DEFAULT '',
     submit_channel TEXT NOT NULL DEFAULT '',
     repeat_rule TEXT NOT NULL DEFAULT '',
     photos TEXT NOT NULL DEFAULT '',
     created_at INTEGER NOT NULL DEFAULT 0,
     confirmed_at INTEGER NOT NULL DEFAULT 0,
     done_at INTEGER NOT NULL DEFAULT 0
   )`,

  `CREATE TABLE IF NOT EXISTS todo_blacklist (
     generation_key TEXT PRIMARY KEY,
     deleted_at INTEGER NOT NULL DEFAULT 0
   )`,

  `CREATE TABLE IF NOT EXISTS plan_block (
     id INTEGER PRIMARY KEY AUTOINCREMENT,
     todo_id INTEGER NOT NULL DEFAULT 0,
     lesson_id INTEGER NOT NULL DEFAULT 0,
     date TEXT NOT NULL,
     start_min INTEGER NOT NULL,
     end_min INTEGER NOT NULL,
     done INTEGER NOT NULL DEFAULT 0
   )`,

  /** 虚拟课程的课时：不定时上课，一讲一讲等着被排进计划 */
  `CREATE TABLE IF NOT EXISTS virtual_lesson (
     id INTEGER PRIMARY KEY AUTOINCREMENT,
     course_id INTEGER NOT NULL,
     seq INTEGER NOT NULL,
     title TEXT NOT NULL DEFAULT '',
     done INTEGER NOT NULL DEFAULT 0,
     done_at INTEGER NOT NULL DEFAULT 0
   )`,

  `CREATE TABLE IF NOT EXISTS rest_window (
     id INTEGER PRIMARY KEY AUTOINCREMENT,
     weekday INTEGER NOT NULL DEFAULT 0,
     start_min INTEGER NOT NULL,
     end_min INTEGER NOT NULL,
     label TEXT NOT NULL DEFAULT ''
   )`,

  `CREATE TABLE IF NOT EXISTS kv (
     k TEXT PRIMARY KEY,
     v TEXT NOT NULL DEFAULT ''
   )`,

  `CREATE INDEX IF NOT EXISTS idx_rule_course ON session_rule(course_id)`,
  `CREATE INDEX IF NOT EXISTS idx_override_date ON session_override(date)`,
  `CREATE INDEX IF NOT EXISTS idx_todo_status ON todo(status)`,
  `CREATE INDEX IF NOT EXISTS idx_todo_genkey ON todo(generation_key)`,
  `CREATE INDEX IF NOT EXISTS idx_block_date ON plan_block(date)`,
  `CREATE INDEX IF NOT EXISTS idx_lesson_course ON virtual_lesson(course_id)`,
  `CREATE INDEX IF NOT EXISTS idx_template_course ON todo_template(course_id)`
];
