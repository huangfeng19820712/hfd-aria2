#!/bin/bash

set -u

FILES_LIST="$1"
THREADS="$2"
CONCURRENT="$3"

ARIA2_RPC="${ARIA2_RPC:-http://127.0.0.1:6800/jsonrpc}"
ARIA2_SECRET="${ARIA2_SECRET:-}"
HF_TOKEN="${HF_TOKEN:-}"

if [[ "${BASH_SOURCE[0]}" = /* ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
else
    SCRIPT_DIR="$(cd "$(dirname "$(pwd)/${BASH_SOURCE[0]}")" && pwd)"
fi

[[ -f "$SCRIPT_DIR/hfd-aria2.env" ]] && source "$SCRIPT_DIR/hfd-aria2.env"

if [[ ! -f "$FILES_LIST" ]]; then
    echo "[ERROR] aria2 input file not found: $FILES_LIST" >&2
    exit 1
fi

if [[ -z "$ARIA2_SECRET" ]]; then
    echo "[ERROR] ARIA2_SECRET is not set." >&2
    echo "        export ARIA2_SECRET='your-secret'" >&2
    exit 1
fi

command -v curl >/dev/null 2>&1 || {
    echo "[ERROR] curl is required." >&2
    exit 1
}

command -v jq >/dev/null 2>&1 || {
    echo "[ERROR] jq is required." >&2
    exit 1
}

###############################################################################
# RPC 请求
###############################################################################

aria2_rpc() {
    local METHOD="$1"
    local PARAMS="$2"

    local REQUEST

    REQUEST="$(
        jq -cn \
            --arg method "$METHOD" \
            --arg secret "$ARIA2_SECRET" \
            --argjson params "$PARAMS" \
            '{
                jsonrpc: "2.0",
                id: "hfd",
                method: $method,
                params: (["token:" + $secret] + $params)
            }'
    )"

    curl -sS \
        -X POST \
        "$ARIA2_RPC" \
        -H "Content-Type: application/json" \
        -d "$REQUEST"
}

###############################################################################
# 检查 aria2
###############################################################################

echo "[INFO] Checking aria2 RPC: $ARIA2_RPC"

VERSION_PARAMS='[]'

VERSION_RESULT="$(aria2_rpc "aria2.getVersion" "$VERSION_PARAMS")"

if echo "$VERSION_RESULT" | jq -e '.error' >/dev/null 2>&1; then
    echo "[ERROR] aria2 RPC failed:"
    echo "$VERSION_RESULT" | jq .
    exit 1
fi

ARIA2_VERSION="$(echo "$VERSION_RESULT" | jq -r '.result.version // empty')"

if [[ -z "$ARIA2_VERSION" ]]; then
    echo "[ERROR] Unable to get aria2 version."
    echo "$VERSION_RESULT"
    exit 1
fi

echo "[INFO] aria2 version: $ARIA2_VERSION"

###############################################################################
# 应用全局选项：split (-x) / max-concurrent-downloads (-j) / Authorization header
# 在添加任何任务之前设置一次；per-task header 仍可覆盖全局 header。
###############################################################################

GLOBAL_OPTS="$(
    jq -cn \
        --argjson threads "${THREADS:-0}" \
        --argjson concurrent "${CONCURRENT:-0}" \
        '{
            split: (if $threads > 0 then $threads else null end),
            "max-concurrent-downloads": (if $concurrent > 0 then $concurrent else null end)
        } | with_entries(select(.value != null))'
)"

if [[ -n "$GLOBAL_OPTS" && "$GLOBAL_OPTS" != "{}" ]]; then
    RESULT="$(aria2_rpc "aria2.changeGlobalOption" "[$GLOBAL_OPTS]")"
    if echo "$RESULT" | jq -e '.error' >/dev/null 2>&1; then
        echo "[WARN] changeGlobalOption (split/concurrent) failed:"
        echo "$RESULT" | jq .
    else
        echo "[INFO] Global options set: split=${THREADS}, max-concurrent-downloads=${CONCURRENT}"
    fi
fi

if [[ -n "$HF_TOKEN" ]]; then
    HEADER_OPTS="$(jq -cn --arg t "$HF_TOKEN" '{header: ["Authorization: Bearer " + $t]}')"
    RESULT="$(aria2_rpc "aria2.changeGlobalOption" "[$HEADER_OPTS]")"
    if echo "$RESULT" | jq -e '.error' >/dev/null 2>&1; then
        echo "[WARN] changeGlobalOption (header) failed:"
        echo "$RESULT" | jq .
    else
        echo "[INFO] Authorization header set globally"
    fi
fi

###############################################################################
# 读取 hfd 生成的 aria2 输入文件
#
# 格式：
#
# URL
#  dir=xxx
#  out=xxx
#  header=xxx
#
# 空行表示一个任务结束。
###############################################################################

URL=""
DIR=""
OUT=""
HEADERS=()
GIDS=()

dbg() { [[ "${HFD_DEBUG:-0}" == "1" ]] && echo "[DEBUG] $*" >&2; }

if [[ "${HFD_DEBUG:-0}" == "1" ]]; then
    echo "[DEBUG] FILES_LIST=$FILES_LIST" >&2
    echo "[DEBUG] cwd=$(pwd)" >&2
    echo "[DEBUG] first 5 lines of file:" >&2
    head -5 "$FILES_LIST" >&2
fi

submit_task() {

    [[ -z "$URL" ]] && return 0

    local OPTIONS
    local PARAMS
    local RESULT
    local GID

    local HEADERS_JSON='[]'
    if (( ${#HEADERS[@]} > 0 )); then
        HEADERS_JSON="$(printf '%s\n' "${HEADERS[@]}" | jq -R . | jq -s .)"
    fi

    OPTIONS="$(
        jq -cn \
            --arg dir "$DIR" \
            --arg out "$OUT" \
            --argjson headers "$HEADERS_JSON" \
            '{
                dir: $dir,
                out: $out,
                continue: "true",
                "auto-file-renaming": "false",
                "allow-overwrite": "true",
                "file-allocation": "none",
                "max-connection-per-server": "8",
                split: "8",
                "min-split-size": "1M",
                header: $headers
            }'
    )"

    dbg "URL=$URL"
    dbg "DIR=$DIR"
    dbg "OUT=$OUT"
    dbg "OPTIONS=$OPTIONS"

    PARAMS="$(
        jq -cn \
            --arg url "$URL" \
            --argjson options "$OPTIONS" \
            '[[ $url ], $options]'
    )"

    RESULT="$(aria2_rpc "aria2.addUri" "$PARAMS")"

    if echo "$RESULT" | jq -e '.error' >/dev/null 2>&1; then
        echo "[ERROR] aria2.addUri failed:"
        echo "$RESULT" | jq .
        return 1
    fi

    GID="$(echo "$RESULT" | jq -r '.result // empty')"

    [[ -n "$GID" ]] && GIDS+=("$GID")

    echo "[INFO] Added: $OUT"
    echo "[INFO] GID:   $GID"

    return 0
}

###############################################################################
# 轮询所有已添加任务，直到 aria2 报告 active+waiting=0，再核对最终状态
###############################################################################

wait_all_tasks() {
    local -a TASK_GIDS=("$@")
    local total=${#TASK_GIDS[@]}
    local completed=0 failed=0 active waiting last_report=0 stats result status

    if (( total == 0 )); then
        echo "[INFO] No tasks to wait for."
        return 0
    fi

    echo "[INFO] Waiting for $total task(s) to finish..."

    while :; do
        stats="$(aria2_rpc "aria2.getGlobalStat" '[]')" || return 1
        active="$(echo "$stats"  | jq -r '.result.numActive  // 0')"
        waiting="$(echo "$stats" | jq -r '.result.numWaiting // 0')"

        if (( SECONDS - last_report >= 10 )); then
            echo "[INFO] aria2: ${active} active, ${waiting} waiting"
            last_report=$SECONDS
        fi

        (( active + waiting == 0 )) && break
        sleep 3
    done

    for gid in "${TASK_GIDS[@]}"; do
        result="$(aria2_rpc "aria2.tellStatus" "$(jq -cn --arg g "$gid" '[$g]')")" || continue
        status="$(echo "$result" | jq -r '.result.status // empty')"
        if [[ "$status" == "complete" ]]; then
            ((completed++))
        else
            ((failed++))
            echo "[WARN] GID $gid ended with status: ${status:-unknown}"
        fi
    done

    echo "[INFO] Final: $completed completed, $failed failed (of $total)"
    (( failed == 0 ))
}

###############################################################################
# 解析 hfd 文件
###############################################################################

STATUS=0

while IFS= read -r LINE || [[ -n "$LINE" ]]; do

    dbg "read LINE=[$LINE]"

    # 空行：提交当前任务
    if [[ -z "$LINE" ]]; then

        if ! submit_task; then
            STATUS=1
        fi

        URL=""
        DIR=""
        OUT=""
        HEADERS=()

        continue
    fi

    if [[ "$LINE" == *"dir="* ]]; then
        DIR="${LINE#*dir=}"
        dbg "matched dir, DIR=$DIR"
    elif [[ "$LINE" == *"out="* ]]; then
        OUT="${LINE#*out=}"
        dbg "matched out, OUT=$OUT"
    elif [[ "$LINE" == *"header="* ]]; then
        HEADERS+=("${LINE#*header=}")
        dbg "matched header"
    else
        if [[ -z "$URL" ]]; then
            URL="$LINE"
            dbg "matched URL, URL=$URL"
        fi
    fi

done < "$FILES_LIST"

# 处理最后没有空行的任务
if [[ -n "$URL" ]]; then
    if ! submit_task; then
        STATUS=1
    fi
fi

# 等待所有任务完成，再决定最终退出码
if [[ "${HFD_WAIT:-0}" == "1" ]] && (( ${#GIDS[@]} > 0 )); then
    if (( STATUS == 0 )); then
        if ! wait_all_tasks "${GIDS[@]}"; then
            STATUS=1
        fi
    else
        wait_all_tasks "${GIDS[@]}" >/dev/null 2>&1 || true
        STATUS=1
    fi
fi

exit "$STATUS"