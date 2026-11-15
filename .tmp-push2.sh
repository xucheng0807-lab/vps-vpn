#!/usr/bin/env bash
set -u
cd "/d/Ai_code/dsh code/dsh-vps-vpn" || exit 1
export GH_TOKEN
GH_TOKEN=$(gh auth token 2>/dev/null) || { echo NO_TOKEN; exit 1; }
local_head=$(git rev-parse HEAD)
for i in 1 2 3; do
  git push origin main 2>&1 | tail -2
  remote=$(git ls-remote origin refs/heads/main 2>/dev/null | cut -f1)
  [ "$local_head" = "$remote" ] && { echo PUSH_OK; exit 0; }
  sleep 5
done
echo PUSH_FAILED; exit 1
