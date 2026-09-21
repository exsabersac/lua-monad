#!/usr/bin/env bash
# 用 Lua 5.3 跑完整测试（Unity / xLua 目标版本）
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
if ! command -v lua5.3 >/dev/null 2>&1; then
  echo "error: lua5.3 not found in PATH" >&2
  exit 127
fi
exec lua5.3 tests/run.lua "$@"
