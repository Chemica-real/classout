#!/usr/bin/env bash
# 一次推到两个远端（Gitee 是国内主仓，GitHub 负责 iOS/Android/Pages 的 CI 与 Release）。
#
#   ./tools/push-all.sh            # 推 master + 所有 tag
#   ./tools/push-all.sh --tags-only
#
# 为什么要有它：两边都要推是容易忘的（忘了 GitHub 就不会跑 CI，忘了 Gitee 国内就看不到）。
# ⚠️ Gitee 那边要用 GIT_SSH_COMMAND="ssh -F /dev/null"：本机的 ~/.ssh/config 里有
#    与 gitee.com 冲突的配置（见 HANDOFF §23.5 附近）。GitHub 直接用默认配置即可。
set -euo pipefail

GITEE_PUSH() { GIT_SSH_COMMAND="ssh -F /dev/null" git push "$@"; }

TAGS_ONLY=0
[ "${1:-}" = "--tags-only" ] && TAGS_ONLY=1

if [ "$TAGS_ONLY" -eq 0 ]; then
  echo "==> Gitee: master"
  GITEE_PUSH origin master
  echo "==> GitHub: master（会触发 iOS/Android/Pages 的 CI）"
  git push github master
fi

echo "==> tags → Gitee / GitHub"
GITEE_PUSH origin --tags
git push github --tags

echo
echo "==> 当前状态"
for r in origin github; do
  printf '  %-7s master=%s  tags=%s\n' "$r" \
    "$(git ls-remote "$r" refs/heads/master | cut -c1-8)" \
    "$(git ls-remote --tags "$r" | grep -c 'refs/tags/[^^{]*$')"
done
