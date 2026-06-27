#!/usr/bin/env bash
# qi-test 集成运行器 —— 起「假模型服务器」，跑 集成/*_测.qi（agent 端到端，无真 LLM）。
#
# 跟 跑测试.sh（纯本地单元）分开：集成用例要起 HTTP 服务器、跨进程，不适合塞进单元跑。
#
# 用法：./跑集成.sh           （用 ../target/debug/qi）
set -uo pipefail
cd "$(dirname "$0")"

QI_BIN="${QI_BIN:-../target/debug/qi}"
PORT="${QI_FAKE_PORT:-41877}"
[ -x "$QI_BIN" ] || { echo "找不到 qi 二进制：$QI_BIN" >&2; exit 1; }

TMP="$(mktemp -d)"
SRV_PID=""
# qi-web 捕获 SIGTERM 走优雅关闭、未必退干净 → 用 -9 强杀，并按端口兜底清残留，
# 否则下次连到上一轮游标已前进的僵尸服务器 → 假阴性。
cleanup() {
    [ -n "$SRV_PID" ] && kill -9 "$SRV_PID" 2>/dev/null
    lsof -ti "tcp:${PORT}" 2>/dev/null | xargs kill -9 2>/dev/null
    rm -rf "$TMP"
}
trap cleanup EXIT
# 启动前先清掉占用该端口的任何残留服务器
lsof -ti "tcp:${PORT}" 2>/dev/null | xargs kill -9 2>/dev/null

export QI_FAKE_PORT="${PORT}"
export QI_LLM_KEY="dummy"                       # harness 要个非空 key
# 脚本：round1 调查天气工具，round2 给最终答复（注意别含 | 或换行）
export QI_FAKE_SCRIPT=$'工具|查天气|{"city":"Tokyo"}\n文本|东京现在18度，晴。'

echo "▶ 编译并启动 假模型服务器（127.0.0.1:${PORT}）"
"$QI_BIN" compile 工具/假模型服务器.qi -o "$TMP/server" >/dev/null 2>"$TMP/err" || {
    echo "  ✗ 服务器编译失败"; sed 's/^/    /' "$TMP/err"; exit 1; }
"$TMP/server" >"$TMP/srv.log" 2>&1 &
SRV_PID=$!

# 等服务器就绪（轮询端口，最多 ~5s）
ready=0
for _ in $(seq 1 50); do
    if curl -s -o /dev/null --max-time 1 "http://127.0.0.1:${PORT}/"; then
        ready=1; break
    fi
    sleep 0.1
done
[ "$ready" = 1 ] || { echo "  ✗ 服务器未就绪"; cat "$TMP/srv.log"; exit 1; }

total=0; fail=0
for f in 集成/*.qi; do
    [ -e "$f" ] || continue
    total=$((total + 1))
    name="$(basename "$f" .qi)"
    echo "▶ $name"
    if ! "$QI_BIN" compile "$f" -o "$TMP/suite" >/dev/null 2>"$TMP/err"; then
        echo "  ✗ COMPILE FAIL"; sed 's/^/    /' "$TMP/err"; fail=$((fail + 1)); echo ""; continue
    fi
    if "$TMP/suite"; then echo "  ✓ SUITE PASS"; else echo "  ✗ SUITE FAIL"; fail=$((fail + 1)); fi
    echo ""
done

echo "════════════════════════════"
echo "集成套件: $((total - fail))/$total 通过"
[ "$fail" -gt 0 ] && exit 1
exit 0
