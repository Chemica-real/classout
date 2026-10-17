#!/usr/bin/env python3
"""把一份备份 JSON 转成 Android 版直接能用的 SQLite 库。

用途：**不经过文件选择器**，把真机/同事的备份灌进 Android 版里做对比（UI 对照、
真实数据渲染）。生成的文件用 `adb push` + `run-as` 覆盖 App 的 `files/classout.db`。

用法：
    python3 tools/backup-to-db.py <backup.json> [-o /tmp/classout.db]
    adb shell am force-stop com.chemica.classout
    adb shell "run-as com.chemica.classout sh -c 'cat > files/classout.db'" < /tmp/classout.db

⚠️ 备份里可能有真实课表/姓名：这个工具只读输入、写到 /tmp，不要把它提交进仓库；
   仓库里的示例用 app_flutter/assets/demo_backup.json。
"""
import argparse
import json
import os
import re
import sqlite3
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_SCHEMA = os.path.join(ROOT, 'app_flutter', 'assets', 'schema.sql')


def snake(name: str) -> str:
    return re.sub(r'([A-Z])', lambda m: '_' + m.group(1).lower(), name)


def insert(db, table, rows, skip=()):
    for row in rows or []:
        cols = {}
        for k, v in row.items():
            if k in skip:
                continue
            if isinstance(v, bool):
                v = 1 if v else 0
            cols[snake(k)] = v
        keys = ','.join(cols)
        holders = ','.join('?' * len(cols))
        db.execute(f'INSERT INTO {table} ({keys}) VALUES ({holders})',
                   list(cols.values()))


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument('backup', help='备份 JSON 路径')
    ap.add_argument('-o', '--out', default='/tmp/classout.db')
    ap.add_argument('--schema', default=DEFAULT_SCHEMA)
    args = ap.parse_args()

    data = json.load(open(args.backup, encoding='utf-8'))
    if data.get('app') != 'ClassOUT':
        print('不是 ClassOUT 的备份（app=%r）' % data.get('app'), file=sys.stderr)
        return 2
    if os.path.exists(args.out):
        os.remove(args.out)
    db = sqlite3.connect(args.out)
    db.executescript(open(args.schema, encoding='utf-8').read())

    insert(db, 'semester', data.get('semesters'))
    # 节次时间 / 不可排时段的 id 由库自增（鸿蒙端也不写 id）
    insert(db, 'section_time', data.get('sectionTimes'), skip=('id',))
    insert(db, 'course', data.get('courses'))
    insert(db, 'session_rule', data.get('rules'))
    insert(db, 'session_override', data.get('overrides'))
    insert(db, 'todo_template', data.get('templates'))
    insert(db, 'virtual_lesson', data.get('lessons'))
    insert(db, 'todo', data.get('todos'))
    insert(db, 'rest_window', data.get('restWindows'), skip=('id',))
    insert(db, 'plan_block', data.get('blocks'))
    db.commit()

    for t in ['semester', 'course', 'session_rule', 'section_time', 'todo',
              'todo_template', 'virtual_lesson', 'rest_window', 'plan_block']:
        n = db.execute(f'SELECT COUNT(*) FROM {t}').fetchone()[0]
        print(f'{t}={n}')
    db.close()
    print(f'OK -> {args.out} ({os.path.getsize(args.out)} bytes)')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
