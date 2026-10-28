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

[[ -f "$SCRIPT_DIR/hfd-aria2-lib.sh" ]] && source "$SCRIPT_DIR/hfd-aria2-lib.sh"
[[ -f "$SCRIPT_DIR/hfd-aria2.env" ]] && load_env_file "$SCRIPT_DIR/hfd-aria2.env"

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

# 分段参数：SPLIT 控制每文件分几段，MAXCONN 控制每服务器连接数。
# MAXCONN 必须 >= SPLIT，否则 aria2 会用单连接顺序请求同一 URL 的多个 Range，
# 对带签名参数的重定向目标（如 HF 的 Xet CDN）会导致后续分段失效。
SPLIT="${ARIA2_SPLIT:-${THREADS:-4}}"
MAXCONN="${ARIA2_MAX_CONN:-$SPLIT}"
if (( MAXCONN < SPLIT )); then
    MAXCONN=$SPLIT
fi

if [[ "${HFD_DEBUG:-0}" == "1" ]]; then
    echo "[DEBUG] FILES_LIST=$FILES_LIST" >&2
    echo "[DEBUG] cwd=$(pwd)" >&2
    echo "[DEBUG] first 5 lines of file:" >&2
    head -5 "$FILES_LIST" >&2
fi

###############################################################################
# 移除与目标文件冲突的残留任务。
# aria2 对同一 dir+out 只允许一个任务在跑；旧任务残留会让新任务直接 abort
# (ERROR 16 Download aborted)，所以添加前先清掉同路径的 active/waiting 任务。
###############################################################################

remove_conflicting_tasks() {
    local TARGET_DIR="$1"
    local TARGET_OUT="$2"
    local TARGET_PATH="${TARGET_DIR%/}/${TARGET_OUT}"

    local LIST
    LIST="$(aria2_rpc "aria2.tellActive" '[]')"
    LIST="$LIST $(aria2_rpc "aria2.tellWaiting" '[]')"

    local OLD_GID
    for OLD_GID in $(echo "$LIST" | jq -r --arg target "$TARGET_PATH" '
        (.result // [])[]?
        | select(any(.files[]?; .path == $target))
        | .gid' 2>/dev/null); do
        [[ -z "$OLD_GID" ]] && continue
        echo "[INFO] Removing conflicting task: $OLD_GID ($TARGET_PATH)"
        aria2_rpc "aria2.remove" "$(jq -cn --arg g "$OLD_GID" '[$g]')" >/dev/null
    done
}

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
            --argjson split "$SPLIT" \
            --argjson maxconn "$MAXCONN" \
            --argjson headers "$HEADERS_JSON" \
            '{
                dir: $dir,
                out: $out,
                continue: "true",
                "auto-file-renaming": "false",
                "allow-overwrite": "true",
                "file-allocation": "none",
                "max-connection-per-server": $maxconn,
                split: $split,
                "min-split-size": "1M",
                "max-redirect": "10",
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

    remove_conflicting_tasks "$DIR" "$OUT"

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

    case "$LINE" in
        " dir="*|"dir="*)
            DIR="${LINE#*dir=}"
            dbg "matched dir, DIR=$DIR"
            ;;

        " out="*|"out="*)
            OUT="${LINE#*out=}"
            dbg "matched out, OUT=$OUT"
            ;;

        " header="*|"header="*)
            HEADERS+=("${LINE#*header=}")
            dbg "matched header"
            ;;

        *)
            if [[ -z "$URL" ]]; then
                URL="$LINE"
                dbg "matched URL, URL=$URL"
            fi
            ;;
    esac

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