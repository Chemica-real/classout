#!/usr/bin/env bash
# 领域逻辑离线验证
#
# 真机装不上之前，至少把「纯逻辑」跑一遍：周次掩码、排课计算、模板渲染、ddl 规则。
# 做法：把不依赖鸿蒙 API 的 .ets 源码复制成 .ts（改写 import 路径、砍掉数据库部分），
#      用本地 tsc 编成 CommonJS 后用 node 跑断言。
#
#   ./tools/domain-check/run.sh

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$HERE/../../entry/src/main/ets"
WORK="$HERE/.work"
TS_VERSION="5.6.3"

command -v node >/dev/null || { echo "需要 node" >&2; exit 1; }

rm -rf "$WORK"
mkdir -p "$WORK"

# ---------- 1. 抽取纯逻辑模块 ----------
cp "$SRC/model/Types.ets"      "$WORK/Types.ts"
cp "$SRC/model/WeekMask.ets"   "$WORK/WeekMask.ts"
cp "$SRC/util/DateUtil.ets"    "$WORK/DateUtil.ts"
cp "$SRC/domain/Timetable.ets" "$WORK/Timetable.ts"
cp "$SRC/domain/PlanMath.ets"  "$WORK/PlanMath.ts"
cp "$SRC/domain/Validate.ets"  "$WORK/Validate.ts"
cp "$SRC/domain/PlanLayout.ets" "$WORK/PlanLayout.ts"
cp "$SRC/domain/Briefing.ets"  "$WORK/Briefing.ts"
cp "$SRC/domain/Backup.ets"    "$WORK/Backup.ts"
cp "$SRC/domain/Wallpaper.ets" "$WORK/Wallpaper.ts"
# ⚠️ SeedData 现在是**测试夹具**（tools/domain-check/SeedData.ts），
# 不再是 App 的一部分：App 不再内置任何课表（发布前清掉了个人数据）。
# 夹具里那份真实课表只用来给断言提供"接近真实的输入"，不进 HAP。
cp "$HERE/SeedData.ts"          "$WORK/SeedData.ts"

# TodoGenerator 只保留纯函数部分（模板渲染 / ddl 计算 / 找下一节课）
python3 - "$SRC/domain/TodoGenerator.ets" "$WORK/TodoGenerator.ts" <<'PY'
import sys
src = open(sys.argv[1], encoding='utf-8').read()
cut = src.index('export interface GenerationOutcome')
head = src[:cut]
out = []
for line in head.splitlines():
    s = line.strip()
    if s.startswith('import ') and ("@kit" in s or "Repo'" in s or "/Db'" in s):
        continue
    out.append(line)
open(sys.argv[2], 'w', encoding='utf-8').write('\n'.join(out) + '\n')
PY

# 改写 import 路径为同目录
for f in "$WORK"/*.ts; do
  sed -i "s#'../model/Types'#'./Types'#g; s#'../model/WeekMask'#'./WeekMask'#g; s#'../util/DateUtil'#'./DateUtil'#g" "$f"
done

cp "$HERE/test.ts" "$WORK/test.ts"
cp "$HERE/tsconfig.json" "$WORK/tsconfig.json"

# ---------- 2. 编译 ----------
cd "$WORK"
if [ ! -d "$HERE/node_modules/typescript" ]; then
  echo "==> 安装 typescript@$TS_VERSION（只装一次）"
  npm install --silent --no-fund --no-audit --prefix "$HERE" "typescript@$TS_VERSION"
fi
"$HERE/node_modules/.bin/tsc" -p "$WORK/tsconfig.json"

# ---------- 3. 跑断言 ----------
node "$WORK/dist/test.js"
