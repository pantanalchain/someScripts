#!/bin/bash
# Pantanal 公链节点安装与管理。
#
# 直接运行时选择状态模式，并设置手机控制台口令。
# 发现更新的 Release 时覆盖已安装的 geth，并重启节点。
# --Pantanal 写入 NetworkId 1122、创世块和公网 bootnode。同步模式为 full。
# 按本机系统选择目录、发布包和防火墙：Ubuntu、Debian、Fedora、RHEL、macOS、Windows。

set -euo pipefail

RELEASE_BASE="https://github.com/pantanalchain/someScripts/releases/latest/download"
RELEASE_API="https://api.github.com/repos/pantanalchain/someScripts/releases/latest"
FIREWALL_URL="https://pantanalchain.github.io/someScripts/setup_firewall.sh"
P2P_PORT=30303
HTTP_ADDR="127.0.0.1"
HTTP_PORT=8545
HTTP_API="eth,net,web3,admin"
CONSOLE_PORT=8790

GETH_UPDATED=0
GCMODE=full
CONSOLE=local
CONSOLE_PASSWORD_FILE=""

log() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

as_root() {
    if [[ "${OS_FAMILY:-}" == windows ]]; then
        "$@"
        return
    fi
    if [[ "$(id -u)" -eq 0 ]]; then
        "$@"
    elif command -v sudo >/dev/null 2>&1; then
        sudo "$@"
    else
        "$@"
    fi
}

detect_platform() {
    local uname_s uname_m id like
    uname_s=$(uname -s)
    uname_m=$(uname -m)
    case "$uname_m" in
        x86_64|amd64) ARCH=amd64 ;;
        aarch64|arm64) ARCH=arm64 ;;
        *)
            log "不支持的架构: $uname_m"
            return 1
            ;;
    esac
    case "$uname_s" in
        Darwin)
            OS_FAMILY=macos
            OS_ID=macos
            ;;
        MINGW*|MSYS*|CYGWIN*)
            OS_FAMILY=windows
            OS_ID=windows
            ;;
        Linux)
            OS_FAMILY=linux
            id=linux
            like=""
            if [[ -r /etc/os-release ]]; then
                id=$(awk -F= '$1=="ID"{gsub(/"/,"",$2); print $2; exit}' /etc/os-release)
                like=$(awk -F= '$1=="ID_LIKE"{gsub(/"/,"",$2); print $2; exit}' /etc/os-release)
            fi
            case "$id" in
                ubuntu) OS_ID=ubuntu ;;
                debian|linuxmint|pop|elementary|kali|raspbian) OS_ID=debian ;;
                fedora) OS_ID=fedora ;;
                rhel|centos|rocky|almalinux|ol|amzn) OS_ID=rhel ;;
                opensuse*|sles|sled) OS_ID=opensuse ;;
                arch|manjaro|endeavouros) OS_ID=arch ;;
                *)
                    case " $like " in
                        *" ubuntu "*|*" debian "*) OS_ID=debian ;;
                        *" fedora "*|*" rhel "*) OS_ID=rhel ;;
                        *" suse "*|*" opensuse "*) OS_ID=opensuse ;;
                        *" arch "*) OS_ID=arch ;;
                        *) OS_ID=linux ;;
                    esac
                    ;;
            esac
            ;;
        *)
            log "不支持的系统: $uname_s"
            return 1
            ;;
    esac
    case "$OS_FAMILY" in
        linux)
            DATADIR="/data/pantanal"
            BIN_DIR="/usr/local/bin"
            ;;
        macos)
            DATADIR="${HOME}/pantanal/data"
            if [[ -d /opt/homebrew/bin ]]; then
                BIN_DIR="/opt/homebrew/bin"
            else
                BIN_DIR="/usr/local/bin"
            fi
            ;;
        windows)
            DATADIR="${HOME}/pantanal/data"
            BIN_DIR="${HOME}/pantanal/bin"
            ;;
    esac
    LOG_FILE="${DATADIR}/geth.log"
    PID_FILE="${DATADIR}/geth.pid"
    STAMP_FILE="${DATADIR}/geth.release"
    NODE_CONF="${DATADIR}/node.conf"
    log "系统: ${OS_ID} ${ARCH}"
}

have_tty() {
    [[ -r /dev/tty && -w /dev/tty ]]
}

prompt_choice() {
    local title="$1"
    shift
    local i=1 opt reply count=$#
    printf '%s\n' "$title" >/dev/tty
    for opt in "$@"; do
        printf '  %d) %s\n' "$i" "$opt" >/dev/tty
        i=$((i + 1))
    done
    while true; do
        printf '请选择 [1-%d]: ' "$count" >/dev/tty
        IFS= read -r reply </dev/tty || return 1
        if [[ "$reply" =~ ^[0-9]+$ ]] && ((reply >= 1 && reply <= count)); then
            printf '%s\n' "$reply"
            return 0
        fi
        printf '请输入 1 到 %d 之间的数字\n' "$count" >/dev/tty
    done
}

prompt_secret() {
    local first second
    while true; do
        printf '%s' "$1" >/dev/tty
        IFS= read -rs first </dev/tty || return 1
        printf '\n请再次输入: ' >/dev/tty
        IFS= read -rs second </dev/tty || return 1
        printf '\n' >/dev/tty
        if [[ ${#first} -ge 8 && "$first" == "$second" ]]; then
            printf '%s' "$first"
            return 0
        fi
        printf '两次输入不一致，或口令少于 8 个字符\n' >/dev/tty
    done
}

platform_asset() {
    local os ext
    case "$OS_FAMILY" in
        linux) os=linux; ext=tar.gz ;;
        macos) os=darwin; ext=tar.gz ;;
        windows) os=windows; ext=zip ;;
        *)
            log "不支持的系统: ${OS_FAMILY}"
            return 1
            ;;
    esac
    printf 'geth-%s-%s.%s\n' "$os" "$ARCH" "$ext"
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

binary_commit() {
    "$1" version 2>/dev/null | awk -F': ' '/^Git Commit:/{print $2; exit}'
}

binary_version() {
    "$1" version 2>/dev/null | awk -F': ' '/^Version:/{print $2; exit}'
}

ensure_datadir() {
    if [[ "$DATADIR" == /data/* ]]; then
        as_root mkdir -p "$DATADIR"
        as_root chown "$(id -u):$(id -g)" "$DATADIR"
    else
        mkdir -p "$DATADIR"
    fi
}

load_node_conf() {
    GCMODE=full
    CONSOLE=local
    CONSOLE_PASSWORD_FILE="${DATADIR}/console.password"
    [[ -f "$NODE_CONF" ]] || return 0
    local key value
    while IFS='=' read -r key value; do
        case "$key" in
            GCMODE) GCMODE=$value ;;
            CONSOLE) CONSOLE=$value ;;
            CONSOLE_PASSWORD_FILE) CONSOLE_PASSWORD_FILE=$value ;;
        esac
    done < "$NODE_CONF"
    [[ "$GCMODE" == archive ]] || GCMODE=full
    CONSOLE=local
}

save_node_conf() {
    ensure_datadir
    umask 077
    cat > "$NODE_CONF" <<EOF
GCMODE=${GCMODE}
CONSOLE=${CONSOLE}
CONSOLE_PASSWORD_FILE=${CONSOLE_PASSWORD_FILE}
EOF
    chmod 600 "$NODE_CONF"
}

console_password_mode() {
    if [[ "$OS_FAMILY" == macos ]]; then
        stat -f '%OLp' "$CONSOLE_PASSWORD_FILE" 2>/dev/null || true
    else
        stat -c '%a' "$CONSOLE_PASSWORD_FILE" 2>/dev/null || true
    fi
}

console_password_ok() {
    local mode secret
    [[ -f "$CONSOLE_PASSWORD_FILE" ]] || return 1
    mode=$(console_password_mode)
    [[ "$mode" == "600" ]] || return 1
    IFS= read -r secret < "$CONSOLE_PASSWORD_FILE" || return 1
    [[ ${#secret} -ge 8 ]]
}

write_console_password() {
    local secret="$1"
    ensure_datadir
    CONSOLE_PASSWORD_FILE="${DATADIR}/console.password"
    umask 077
    printf '%s\n' "$secret" > "$CONSOLE_PASSWORD_FILE"
    chmod 600 "$CONSOLE_PASSWORD_FILE"
}

save_console_password() {
    local secret
    secret=$(prompt_secret "手机控制台口令（至少 8 位）: ") || return 1
    [[ ${#secret} -ge 8 ]] || return 1
    write_console_password "$secret"
}

ensure_console_password() {
    CONSOLE=local
    CONSOLE_PASSWORD_FILE="${DATADIR}/console.password"
    if console_password_ok; then
        return 0
    fi
    local env_secret="${PANTANAL_CONSOLE_PASSWORD:-}"
    if [[ ${#env_secret} -ge 8 ]]; then
        write_console_password "$env_secret"
        return 0
    fi
    if have_tty; then
        save_console_password || return 1
        return 0
    fi
    log "部署节点必须设置手机控制台口令。在终端中输入，或提供至少 8 位的 PANTANAL_CONSOLE_PASSWORD。口令写入 ${CONSOLE_PASSWORD_FILE}，不进入命令行。"
    return 1
}

choose_gcmode() {
    local choice
    choice=$(prompt_choice "选择状态保留方式" \
        "full：普通全节点，只保留当前状态" \
        "archive：归档节点，保留全部历史状态")
    if [[ "$choice" == 2 ]]; then
        GCMODE=archive
    else
        GCMODE=full
    fi
    log "状态模式: ${GCMODE}"
}

require_console_password() {
    CONSOLE=local
    CONSOLE_PASSWORD_FILE="${DATADIR}/console.password"
    save_console_password
    log "手机控制台: 127.0.0.1:${CONSOLE_PORT}"
}

remote_asset_meta() {
    local asset="$1"
    curl -fsSL --retry 3 --retry-delay 2 --max-time 30 "$RELEASE_API" | awk -v asset="$asset" '
        index($0, "\"name\": \"" asset "\"") { hit = 1 }
        hit && /"size":/ {
            size = $2
            gsub(/[^0-9]/, "", size)
        }
        hit && /"updated_at":/ {
            updated = $2
            gsub(/[",]/, "", updated)
            print size, updated
            exit
        }
    '
}

download_release() {
    local asset="$1"
    command -v curl >/dev/null 2>&1 || {
        log "需要 curl"
        return 1
    }
    DL_DIR=$(mktemp -d)
    local archive="${DL_DIR}/${asset}" bin=""
    log "下载最新 geth: ${RELEASE_BASE}/${asset}"
    curl -fL --retry 3 --retry-delay 2 -o "$archive" "${RELEASE_BASE}/${asset}"
    case "$asset" in
        *.tar.gz) tar -xzf "$archive" -C "$DL_DIR" ;;
        *.zip)
            if command -v unzip >/dev/null 2>&1; then
                unzip -qo "$archive" -d "$DL_DIR"
            else
                python3 -m zipfile -e "$archive" "$DL_DIR"
            fi
            ;;
    esac
    while IFS= read -r candidate; do
        bin=$candidate
        break
    done < <(find "$DL_DIR" -type f \( -name geth -o -name geth.exe \))
    if [[ -z "$bin" ]]; then
        rm -rf "$DL_DIR"
        DL_DIR=""
        log "发布包中没有 geth"
        return 1
    fi
    DL_BIN=$bin
}

place_geth() {
    local bin="$1" name dest
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
    log "已安装 $(binary_version "$dest") $(binary_commit "$dest")"
    log "路径: $dest"
}

write_stamp() {
    local meta="$1" commit="$2"
    ensure_datadir
    printf '%s %s\n' "$meta" "$commit" > "$STAMP_FILE"
}

sync_geth() {
    local asset meta installed="" old_commit="" new_commit="" new_version=""
    GETH_UPDATED=0
    asset=$(platform_asset)
    meta=$(remote_asset_meta "$asset" || true)
    if installed=$(geth_path 2>/dev/null); then
        old_commit=$(binary_commit "$installed" || true)
    fi
    if [[ -n "$installed" && -n "$meta" && -f "$STAMP_FILE" ]]; then
        if [[ "$(awk '{print $1, $2}' "$STAMP_FILE")" == "$meta" ]]; then
            log "geth 已是最新版本 $(binary_version "$installed")"
            return 0
        fi
    fi
    if [[ -n "$installed" && -z "$meta" ]]; then
        log "无法查询最新 Release，继续使用已安装的 geth"
        return 0
    fi
    download_release "$asset"
    new_commit=$(binary_commit "$DL_BIN" || true)
    new_version=$(binary_version "$DL_BIN" || true)
    if [[ -n "$installed" && -n "$old_commit" && "$old_commit" == "$new_commit" ]]; then
        log "发布包与当前 geth 相同 (${new_version})"
        [[ -n "$meta" ]] && write_stamp "$meta" "$new_commit"
        rm -rf "$DL_DIR"
        DL_DIR=""
        return 0
    fi
    if [[ -n "$installed" ]]; then
        log "发现新版本，覆盖安装并重启 geth"
        log "当前 $(binary_version "$installed") ${old_commit}"
        log "最新 ${new_version} ${new_commit}"
        stop_geth
    else
        log "安装 geth ${new_version} ${new_commit}"
    fi
    place_geth "$DL_BIN"
    [[ -n "$meta" ]] && write_stamp "$meta" "$new_commit"
    rm -rf "$DL_DIR"
    DL_DIR=""
    GETH_UPDATED=1
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

console_args() {
    CONSOLE_ARGS=()
    if ! console_password_ok; then
        log "手机控制台口令文件不可用。文件必须仅所有者可读，口令至少 8 个字符。"
        return 1
    fi
    CONSOLE_ARGS+=(--pantanal.console.port "$CONSOLE_PORT")
    CONSOLE_ARGS+=(--pantanal.console.addr "127.0.0.1")
    CONSOLE_ARGS+=(--pantanal.console.passwordfile "$CONSOLE_PASSWORD_FILE")
    log "手机控制台: 127.0.0.1:${CONSOLE_PORT}"
}

start_geth() {
    local gcmode="${1:-$GCMODE}"
    local geth pid
    case "$gcmode" in
        full|archive) ;;
        *)
            log "gcmode 只能是 full 或 archive"
            return 1
            ;;
    esac
    GCMODE=$gcmode
    if ! ensure_console_password; then
        return 1
    fi
    if ! geth=$(geth_path); then
        sync_geth
        geth=$(geth_path)
    fi
    ensure_datadir
    save_node_conf
    if pid=$(running_pid); then
        log "geth 已在运行 (PID ${pid})"
        apply_firewall
        return 0
    fi
    log "启动 Pantanal 公链节点 (${OS_ID}, gcmode ${gcmode})"
    console_args || return 1
    local -a cmd
    cmd=(
        "$geth"
        --Pantanal
        --datadir "$DATADIR"
        --port "$P2P_PORT"
        --syncmode full
        --gcmode "$gcmode"
        --http
        --http.addr "$HTTP_ADDR"
        --http.port "$HTTP_PORT"
        --http.api "$HTTP_API"
        --maxpeers 100
        --verbosity 3
    )
    if ((${#CONSOLE_ARGS[@]} > 0)); then
        cmd+=("${CONSOLE_ARGS[@]}")
    fi
    nohup "${cmd[@]}" >> "$LOG_FILE" 2>&1 < /dev/null &
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
        apply_firewall
        return 0
    fi
    log "geth 启动失败，查看日志: ${LOG_FILE}"
    return 1
}

apply_firewall() {
    local script status geth
    command -v curl >/dev/null 2>&1 || {
        log "需要 curl 才能配置防火墙"
        return 1
    }
    if geth=$(geth_path 2>/dev/null); then
        export PANTANAL_GETH="$geth"
    fi
    script=$(mktemp)
    log "配置节点防火墙 (${OS_ID}): ${FIREWALL_URL}"
    if ! curl -fsSL --retry 3 --retry-delay 2 --max-time 30 -o "$script" "$FIREWALL_URL"; then
        rm -f "$script"
        log "下载防火墙脚本失败"
        return 1
    fi
    bash "$script" "$OS_ID" && status=0 || status=$?
    rm -f "$script"
    return "$status"
}

install_node() {
    local gcmode="${1:-full}"
    load_node_conf
    GCMODE=$gcmode
    if ! ensure_console_password; then
        return 1
    fi
    save_node_conf
    sync_geth
    stop_geth
    start_geth "$gcmode"
}

show_status() {
    local pid block chain
    load_node_conf
    log "=== Pantanal geth ==="
    log "系统: ${OS_ID} ${ARCH}"
    if pid=$(running_pid); then
        log "运行中 (PID ${pid})"
    else
        log "未运行"
    fi
    log "gcmode: ${GCMODE}"
    log "手机控制台: ${CONSOLE}"
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
    load_node_conf
    sync_geth
    if [[ "$GETH_UPDATED" == 1 ]]; then
        log "已覆盖新版本，正在重启"
        start_geth "$GCMODE"
        return 0
    fi
    if running_pid >/dev/null; then
        log "geth 运行正常 (PID $(running_pid))"
        return 0
    fi
    log "geth 未运行，正在启动"
    start_geth "$GCMODE"
}

start_command() {
    local mode="${1:-}"
    load_node_conf
    if [[ -n "$mode" ]]; then
        GCMODE=$mode
        save_node_conf
    fi
    sync_geth
    if [[ "$GETH_UPDATED" == 1 ]] || ! running_pid >/dev/null; then
        start_geth "$GCMODE"
        return 0
    fi
    log "geth 已在运行，且已是最新版本 (PID $(running_pid))"
    apply_firewall
}

guide_install() {
    load_node_conf
    choose_gcmode
    require_console_password
    save_node_conf
    sync_geth
    if [[ "$GETH_UPDATED" == 1 ]]; then
        start_geth "$GCMODE"
        return 0
    fi
    local choice
    if running_pid >/dev/null; then
        choice=$(prompt_choice "geth 已是最新版本，并且正在运行" \
            "保持运行" \
            "按本次选择重启")
        if [[ "$choice" == 2 ]]; then
            stop_geth
            start_geth "$GCMODE"
        else
            apply_firewall
        fi
        return 0
    fi
    choice=$(prompt_choice "geth 已准备好" \
        "现在启动" \
        "稍后再启动")
    if [[ "$choice" == 1 ]]; then
        start_geth "$GCMODE"
    fi
}

guide_start() {
    load_node_conf
    local choice
    if [[ -f "$NODE_CONF" ]]; then
        choice=$(prompt_choice "启动方式" \
            "使用上次的设置（gcmode ${GCMODE}）" \
            "重新选择状态模式并设置控制台口令")
        if [[ "$choice" == 2 ]]; then
            choose_gcmode
            require_console_password
            save_node_conf
        fi
    else
        choose_gcmode
        require_console_password
        save_node_conf
    fi
    sync_geth
    if [[ "$GETH_UPDATED" == 1 ]]; then
        start_geth "$GCMODE"
        return 0
    fi
    if running_pid >/dev/null; then
        choice=$(prompt_choice "geth 正在运行" \
            "保持运行" \
            "按本次选择重启")
        if [[ "$choice" == 2 ]]; then
            stop_geth
            start_geth "$GCMODE"
        else
            apply_firewall
        fi
        return 0
    fi
    start_geth "$GCMODE"
}

interactive_menu() {
    local choice
    while true; do
        choice=$(prompt_choice "Pantanal 公链节点" \
            "安装或更新并启动" \
            "启动已安装的节点" \
            "停止" \
            "查看状态" \
            "退出")
        case "$choice" in
            1) guide_install ;;
            2) guide_start ;;
            3) stop_geth ;;
            4) show_status ;;
            5) return 0 ;;
        esac
        printf '\n' >/dev/tty
    done
}

show_help() {
    cat <<EOF
Pantanal 公链节点

直接运行会选择状态模式，并设置手机控制台口令。
发现更新的 Release 时覆盖 geth 并重启节点。

用法: $(basename "$0") <command>

  install [archive]   非交互安装。不带参数且在终端中运行时进入选择菜单
  start [archive]     启动节点。有新版本时先覆盖再重启
  stop                停止节点
  status              查看进程和链 ID
  monitor             巡检。有新版本时覆盖并重启，退出后按上次的设置拉起
  help                显示此说明

公链参数由 geth --Pantanal 决定：NetworkId 1122、内置创世块、公网 bootnode。
当前系统 ${OS_ID} (${ARCH})。数据目录 ${DATADIR}，程序目录 ${BIN_DIR}。
同步模式为 full。
发布包: ${RELEASE_BASE}/geth-<os>-<arch>.tar.gz 或 .zip

部署时必须设置手机控制台口令，至少 8 个字符。
控制台只绑定 127.0.0.1:${CONSOLE_PORT}，不接受外网连接。
口令写入 ${DATADIR}/console.password，权限为仅所有者可读。
非交互安装可事先设置 PANTANAL_CONSOLE_PASSWORD，脚本把它写入口令文件。
口令不进入命令行，也不写入 geth.log。
节点启动后执行 ${FIREWALL_URL} ${OS_ID}。
Ubuntu 与 Debian 使用 ufw，Fedora、RHEL 及兼容系统使用 firewalld，macOS 使用应用程序防火墙，Windows 使用 Windows 防火墙。
放行 SSH 与 P2P ${P2P_PORT}。
EOF
}

main() {
    local command="${1:-}"
    local mode="${2:-full}"
    case "$command" in
        "")
            if have_tty; then
                interactive_menu
            else
                install_node full
            fi
            ;;
        install)
            if [[ -z "${2:-}" && $(have_tty && echo yes || true) == yes ]]; then
                interactive_menu
            else
                install_node "$mode"
            fi
            ;;
        start)
            start_command "${2:-}"
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

detect_platform || exit 1
main "$@"
