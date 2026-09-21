#!/usr/bin/env bash
# ci_tools.sh — 测试 + 周边工具一键（性能基准 / doctor / alloc / profile）
# 在仓库根或任意目录：
#   ./scripts/ci_tools.sh
#   ALLOW_BENCH_REGRESSION=1 ./scripts/ci_tools.sh   # bench --ci 回归时 soft-fail
#   PROFILE=1 ./scripts/ci_tools.sh                  # profile 用较大 N（默认 smoke N=1）
# 顺序：test_lua53 → flow_doctor --ci → bench_compare --ci → alloc_hotspot smoke → profile_flow
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if ! command -v lua5.3 >/dev/null 2>&1; then
  echo "error: lua5.3 not found in PATH" >&2
  exit 127
fi

echo "==> [1/5] test_lua53.sh"
./scripts/test_lua53.sh

echo ""
echo "==> [2/5] flow_doctor --ci"
lua5.3 tools/flow_doctor.lua --ci

echo ""
echo "==> [3/5] bench_compare --ci"
set +e
lua5.3 tools/bench_compare.lua --ci
bench_rc=$?
set -e
if [[ "$bench_rc" -ne 0 ]]; then
  if [[ "${ALLOW_BENCH_REGRESSION:-0}" == "1" ]]; then
    echo "[ci_tools] WARN: bench_compare exit=$bench_rc (ALLOW_BENCH_REGRESSION=1 → soft-fail)" >&2
  else
    echo "[ci_tools] FAIL: bench_compare exit=$bench_rc (set ALLOW_BENCH_REGRESSION=1 to soft-fail)" >&2
    exit "$bench_rc"
  fi
fi

echo ""
echo "==> [4/5] alloc_hotspot smoke (N=100)"
lua5.3 tools/alloc_hotspot.lua 100 >/dev/null

echo ""
if [[ "${PROFILE:-0}" == "1" ]]; then
  echo "==> [5/5] profile_flow (PROFILE=1, N=20)"
  lua5.3 tools/profile_flow.lua 20 >/dev/null
else
  echo "==> [5/5] profile_flow smoke (--smoke, N=1)"
  lua5.3 tools/profile_flow.lua --smoke >/dev/null
fi

echo ""
echo "ci_tools: OK"
