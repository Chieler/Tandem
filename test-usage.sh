#!/bin/bash
set -eu
root=$(cd "$(dirname "$0")" && pwd)
out=$(CNTCTR_USAGE_CLAUDE_DIR="$root/fixtures/usage/claude" CNTCTR_USAGE_CODEX_DIR="$root/fixtures/usage/codex" CNTCTR_USAGE_CWD=/fixture/project "${BIN:-$root/cntctr}" usage --since 500000)
printf '%s\n' "$out"
printf '%s\n' "$out" | grep -Eq 'claude-fixture +10 +20 +30 +40'
printf '%s\n' "$out" | grep -Eq 'codex-fixture +100 +30 +0 +20 +30.0%'
printf '%s\n' "$out" | grep -q 'agy: not counted'
