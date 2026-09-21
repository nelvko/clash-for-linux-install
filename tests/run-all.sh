#!/usr/bin/env bash
# 全量回归入口：顺序执行本目录全部测试（排除自身）。
# 用法：bash tests/run-all.sh [测试名 …]
# 示例：bash tests/run-all.sh                 # 全量
#       bash tests/run-all.sh update-ux sub-ux  # 按名筛选子集
set -u

TESTS_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
pass=0
fail=0
failed=()

for t in "$TESTS_DIR"/*.sh; do
    name=$(basename -- "$t" .sh)
    [ "$name" != run-all ] || continue
    if [ "$#" -gt 0 ]; then
        matched=0
        for filter in "$@"; do
            [ "$name" = "$filter" ] && matched=1
        done
        [ "$matched" -eq 1 ] || continue
    fi
    printf '%-28s' "$name"
    if output=$(bash "$t" 2>&1); then
        printf 'PASS\n'
        pass=$((pass + 1))
    else
        printf 'FAIL\n'
        printf '%s\n' "$output" | sed 's/^/    /'
        fail=$((fail + 1))
        failed+=("$name")
    fi
done

printf -- '----\nPASS: %d  FAIL: %d\n' "$pass" "$fail"
if [ "$fail" -gt 0 ]; then
    printf 'FAILED: %s\n' "${failed[*]}"
    exit 1
fi
