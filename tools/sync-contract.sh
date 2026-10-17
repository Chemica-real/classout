#!/usr/bin/env bash
# 重新生成 shared/ 里那些"从鸿蒙端派生"的合同文件。
#
#   ./tools/sync-contract.sh
#
# 做两件事：
#   1. shared/schema.sql      ← 从 data/Schema.ets 抽 DDL
#   2. shared/fixtures/*.json ← 从编译后的纯逻辑（.work/dist）生成规则用例
#
# 什么时候跑：改了 Schema.ets 或改了 domain/ 里被 fixture 覆盖的规则之后。
# 跑完记得把 shared/ 的改动和实现一起提交（三端都靠它对齐）。
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

echo "== 1) 先跑一遍 domain-check（顺便确认鸿蒙端断言仍然全绿）=="
"$ROOT/tools/domain-check/run.sh" | tail -3

echo "== 2) 抽 schema.sql =="
python3 - "$ROOT" <<'PY'
import re, sys, os
root = sys.argv[1]
src = open(os.path.join(root, 'entry/src/main/ets/data/Schema.ets'), encoding='utf-8').read()
stmts = re.findall(r'`(CREATE [^`]+)`', src)
assert len(stmts) >= 12, f'只抽到 {len(stmts)} 条 DDL，Schema.ets 结构变了？'
head = '''-- ClassOUT 数据库 schema（SQLite / RDB 通用）
--
-- 这是**三端的唯一权威 DDL**：鸿蒙端 entry/src/main/ets/data/Schema.ets、
-- iOS / Android 端（GRDB / Drift / Room）都必须与它逐列一致。
-- 改表 → 先改这里 → 三端跟着改 → shared/fixtures 里补用例。
--
-- 由 tools/sync-contract.sh 从 Schema.ets 自动抽取，别手改（会被覆盖）。

'''
body = ';\n\n'.join(s.rstrip().rstrip(';') for s in stmts) + ';\n'
open(os.path.join(root, 'shared/schema.sql'), 'w', encoding='utf-8').write(head + body)
print(f'   schema.sql：{len(stmts)} 条 DDL')
PY

echo "== 3) 生成 fixtures =="
node "$ROOT/tools/fixtures/gen.js"

echo "== 完成。shared/ 的改动要跟实现一起提交 =="
