#!/bin/bash
# Pantanal 公链节点安装与管理。
#
# 从本仓库最新 Release 下载对应平台的 geth，并以 --Pantanal 启动。
# --Pantanal 写入 NetworkId 1122、创世块和公网 bootnode，不另放 genesis 文件。
# 公链同步使用 full；默认 gcmode 为 full，归档节点使用 archive。

set -euo pipefail

RELEASE_BASE="https://github.com/pantanalchain/someScripts/releases/latest/download"
P2P_PORT=30303
HTTP_ADDR="127.0.0.1"
HTTP_PORT=8545
HTTP_API="eth,net,web3,admin"

if [[ "$(uname -s)" == Linux || "$(uname -s)" == Darwin ]]; then
    DATADIR="/data/pantanal"
    BIN_DIR="/usr/local/bin"
else
    DATADIR="${HOME}/pantanal/data"
    BIN_DIR="${HOME}/pantanal/bin"
fi

LOG_FILE="${DATADIR}/geth.log"
PID_FILE="${DATADIR}/geth.pid"
GCMODE_FILE="${DATADIR}/gcmode"

log() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

as_root() {
    if [[ "$(id -u)" -eq 0 ]]; then
        "$@"
    else
        sudo "$@"
    fi
}

platform_asset() {
    local os arch
    os=$(uname -s)
    arch=$(uname -m)
    case "$os" in
        Linux) os=linux ;;
        Darwin) os=darwin ;;
        MINGW*|MSYS*|CYGWIN*) os=windows ;;
        *)
            log "不支持的系统: $os"
            return 1
            ;;
    esac
    case "$arch" in
        x86_64|amd64) arch=amd64 ;;
        aarch64|arm64) arch=arm64 ;;
        *)
            log "不支持的架构: $arch"
            return 1
            ;;
    esac
    if [[ "$os" == windows ]]; then
        printf 'geth-%s-%s.zip\n' "$os" "$arch"
    else
        printf 'geth-%s-%s.tar.gz\n' "$os" "$arch"
    fi
}

geth_path() {
    if [[ -x "${BIN_DIR}/geth" ]]; then
        printf '%s\n' "${BIN_DIR}/geth"
    elif [[ -x "${BIN_DIR}/geth.exe" ]]; then
        printf '%s\n' "${BIN_DIR}/geth.exe"
    else
        return 1
    fi
}

ensure_datadir() {
    if [[ "$DATADIR" == /data/* ]]; then
        as_root mkdir -p "$DATADIR"
        as_root chown "$(id -u):$(id -g)" "$DATADIR"
    else
        mkdir -p "$DATADIR"
    fi
}

install_geth() {
    local asset tmp archive bin name dest
    command -v curl >/dev/null 2>&1 || {
        log "需要 curl"
        return 1
    }
    asset=$(platform_asset)
    tmp=$(mktemp -d)
    archive="${tmp}/${asset}"
    log "下载最新 geth: ${RELEASE_BASE}/${asset}"
    curl -fL --retry 3 --retry-delay 2 -o "$archive" "${RELEASE_BASE}/${asset}"
    case "$asset" in
        *.tar.gz)
            tar -xzf "$archive" -C "$tmp"
            ;;
        *.zip)
            if command -v unzip >/dev/null 2>&1; then
                unzip -qo "$archive" -d "$tmp"
            else
                python3 -m zipfile -e "$archive" "$tmp"
            fi
            ;;
    esac
    bin=""
    while IFS= read -r candidate; do
        bin=$candidate
        break
    done < <(find "$tmp" -type f \( -name geth -o -name geth.exe \))
    if [[ -z "$bin" ]]; then
        rm -rf "$tmp"
        log "发布包中没有 geth"
        return 1
    fi
    name=$(basename "$bin")
    dest="${BIN_DIR}/${name}"
    if [[ -w "$BIN_DIR" || ! -e "$BIN_DIR" && -w "$(dirname "$BIN_DIR")" ]]; then
        mkdir -p "$BIN_DIR"
        cp "$bin" "$dest"
        chmod 755 "$dest"
    else
        as_root mkdir -p "$BIN_DIR"
        as_root cp "$bin" "$dest"
        as_root chmod 755 "$dest"
    fi
    rm -rf "$tmp"
    log "已安装 $($dest version | awk 'NR==1{print} NR==2{print}')"
    log "路径: $dest"
}

running_pid() {
    if [[ -f "$PID_FILE" ]]; then
        local pid
        pid=$(cat "$PID_FILE")
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            printf '%s\n' "$pid"
            return 0
        fi
    fi
    return 1
}

stop_geth() {
    local pid
    if ! pid=$(running_pid); then
        log "geth 未运行"
        rm -f "$PID_FILE"
        return 0
    fi
    log "正在停止 geth (PID ${pid})"
    kill "$pid" 2>/dev/null || true
    local i
    for i in 1 2 3 4 5; do
        if ! kill -0 "$pid" 2>/dev/null; then
            rm -f "$PID_FILE"
            log "geth 已停止"
            return 0
        fi
        sleep 1
    done
    kill -9 "$pid" 2>/dev/null || true
    rm -f "$PID_FILE"
    log "geth 已强制停止"
}

start_geth() {
    local gcmode="${1:-full}"
    local geth pid
    case "$gcmode" in
        full|archive) ;;
        *)
            log "gcmode 只能是 full 或 archive"
            return 1
            ;;
    esac
    if ! geth=$(geth_path); then
        install_geth
        geth=$(geth_path)
    fi
    ensure_datadir
    if pid=$(running_pid); then
        log "geth 已在运行 (PID ${pid})"
        return 0
    fi
    printf '%s\n' "$gcmode" > "$GCMODE_FILE"
    log "启动 Pantanal 公链节点 (gcmode ${gcmode})"
    nohup "$geth" \
        --Pantanal \
        --datadir "$DATADIR" \
        --port "$P2P_PORT" \
        --syncmode full \
        --gcmode "$gcmode" \
        --http \
        --http.addr "$HTTP_ADDR" \
        --http.port "$HTTP_PORT" \
        --http.api "$HTTP_API" \
        --maxpeers 100 \
        --verbosity 3 \
        >> "$LOG_FILE" 2>&1 < /dev/null &
    pid=$!
    printf '%s\n' "$pid" > "$PID_FILE"
    disown "$pid" 2>/dev/null || true
    sleep 3
    if kill -0 "$pid" 2>/dev/null; then
        log "geth 已启动 (PID ${pid})"
        log "数据目录: ${DATADIR}"
        log "P2P: ${P2P_PORT}"
        log "HTTP: http://${HTTP_ADDR}:${HTTP_PORT}"
        log "日志: ${LOG_FILE}"
        return 0
    fi
    log "geth 启动失败，查看日志: ${LOG_FILE}"
    return 1
}

install_node() {
    local gcmode="${1:-full}"
    stop_geth || true
    install_geth
    start_geth "$gcmode"
}

show_status() {
    local pid block chain
    log "=== Pantanal geth ==="
    if pid=$(running_pid); then
        log "运行中 (PID ${pid})"
    else
        log "未运行"
    fi
    if [[ -f "$GCMODE_FILE" ]]; then
        log "gcmode: $(cat "$GCMODE_FILE")"
    fi
    chain=$(curl -fsS -m 3 -X POST "http://${HTTP_ADDR}:${HTTP_PORT}" \
        -H 'Content-Type: application/json' \
        -d '{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":1}' 2>/dev/null || true)
    block=$(curl -fsS -m 3 -X POST "http://${HTTP_ADDR}:${HTTP_PORT}" \
        -H 'Content-Type: application/json' \
        -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' 2>/dev/null || true)
    if [[ -n "$chain" ]]; then
        log "chainId: ${chain}"
    fi
    if [[ -n "$block" ]]; then
        log "区块: ${block}"
    fi
    log "数据目录: ${DATADIR}"
    log "日志: ${LOG_FILE}"
}

monitor() {
    local gcmode=full
    if [[ -f "$GCMODE_FILE" ]]; then
        gcmode=$(cat "$GCMODE_FILE")
    fi
    if running_pid >/dev/null; then
        log "geth 运行正常 (PID $(running_pid))"
        return 0
    fi
    log "geth 未运行，正在启动"
    start_geth "$gcmode"
}

show_help() {
    cat <<EOF
Pantanal 公链节点

用法: $(basename "$0") <command>

  install [archive]   下载最新 geth 并启动。archive 使用 --gcmode archive
  start [archive]     启动已安装的节点；没有二进制时先下载
  stop                停止节点
  status              查看进程和链 ID
  monitor             进程退出后按上次的 gcmode 拉起
  help                显示此说明

直接执行本脚本等同于 install。

公链参数由 geth --Pantanal 决定：NetworkId 1122、内置创世块、公网 bootnode。
数据目录为 ${DATADIR}。同步模式为 full。
发布包: ${RELEASE_BASE}/geth-<os>-<arch>.tar.gz 或 .zip
EOF
}

main() {
    local command="${1:-install}"
    local mode="${2:-full}"
    case "$command" in
        install)
            install_node "$mode"
            ;;
        start)
            start_geth "$mode"
            ;;
        stop)
            stop_geth
            ;;
        status)
            show_status
            ;;
        monitor)
            monitor
            ;;
        help|--help|-h)
            show_help
            ;;
        *)
            log "未知命令: $command"
            show_help
            return 1
            ;;
    esac
}

main "$@"
