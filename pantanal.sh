#!/bin/bash
# Pantanal 公链节点安装与管理。
#
# 直接运行时选择部署模式，并设置手机控制台口令。
# 部署模式：同步节点、归档节点、出块节点、归档出块节点。
# 出块模式可以输入私钥，或读取密钥文件，或跳过账户创建。
# 安装脚本不生成私钥，也不生成账户。
# 跳过时部署模式保持不变。账户稍后由运营者执行 geth account new 生成。
# 提供的私钥写入数据目录 sealer.key，权限仅所有者可读。
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
SEALER=off
SEALER_KEY_FILE=""
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
    RUN_MODE_FILE="${DATADIR}/geth.mode"
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
    SEALER=off
    SEALER_ACCOUNT=now
    SEALER_KEY_FILE="${DATADIR}/sealer.key"
    CONSOLE=local
    CONSOLE_PASSWORD_FILE="${DATADIR}/console.password"
    [[ -f "$NODE_CONF" ]] || return 0
    local key value
    while IFS='=' read -r key value; do
        case "$key" in
            GCMODE) GCMODE=$value ;;
            SEALER) SEALER=$value ;;
            SEALER_ACCOUNT) SEALER_ACCOUNT=$value ;;
            SEALER_KEY_FILE) SEALER_KEY_FILE=$value ;;
            CONSOLE) CONSOLE=$value ;;
            CONSOLE_PASSWORD_FILE) CONSOLE_PASSWORD_FILE=$value ;;
        esac
    done < "$NODE_CONF"
    [[ "$GCMODE" == archive ]] || GCMODE=full
    [[ "$SEALER" == on ]] || SEALER=off
    [[ "$SEALER_ACCOUNT" == later ]] || SEALER_ACCOUNT=now
    [[ -n "$SEALER_KEY_FILE" ]] || SEALER_KEY_FILE="${DATADIR}/sealer.key"
    CONSOLE=local
}

save_node_conf() {
    ensure_datadir
    SEALER_KEY_FILE="${DATADIR}/sealer.key"
    umask 077
    cat > "$NODE_CONF" <<EOF
GCMODE=${GCMODE}
SEALER=${SEALER}
SEALER_ACCOUNT=${SEALER_ACCOUNT}
SEALER_KEY_FILE=${SEALER_KEY_FILE}
CONSOLE=${CONSOLE}
CONSOLE_PASSWORD_FILE=${CONSOLE_PASSWORD_FILE}
EOF
    chmod 600 "$NODE_CONF"
}

apply_deploy_mode() {
    local mode
    mode=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
    case "$mode" in
        full|sync)
            GCMODE=full
            SEALER=off
            ;;
        archive)
            GCMODE=archive
            SEALER=off
            ;;
        seal)
            GCMODE=full
            SEALER=on
            ;;
        archive-seal|archive_seal)
            GCMODE=archive
            SEALER=on
            ;;
        *)
            return 1
            ;;
    esac
}

mode_label() {
    if [[ "$SEALER" == on && "$GCMODE" == archive ]]; then
        printf '归档出块节点'
    elif [[ "$SEALER" == on ]]; then
        printf '出块节点'
    elif [[ "$GCMODE" == archive ]]; then
        printf '归档节点'
    else
        printf '同步节点'
    fi
}

normalize_sealer_hex() {
    local raw="$1"
    raw=$(printf '%s' "$raw" | tr -d '[:space:]')
    raw=${raw#0x}
    raw=${raw#0X}
    [[ "$raw" =~ ^[0-9a-fA-F]{64}$ ]] || return 1
    [[ "$raw" == "0000000000000000000000000000000000000000000000000000000000000000" ]] && return 1
    printf '%s' "$raw"
}

read_sealer_hex() {
    local file="$1" raw
    [[ -n "$file" && -f "$file" && -r "$file" ]] || return 1
    raw=$(head -c 256 < "$file" | tr -d '[:space:]') || return 1
    normalize_sealer_hex "$raw"
}

sealer_key_ok() {
    local mode
    SEALER_KEY_FILE="${DATADIR}/sealer.key"
    [[ -f "$SEALER_KEY_FILE" ]] || return 1
    mode=$(file_mode "$SEALER_KEY_FILE")
    [[ "$mode" == "600" ]] || return 1
    read_sealer_hex "$SEALER_KEY_FILE" >/dev/null
}

write_sealer_hex() {
    local hex
    hex=$(normalize_sealer_hex "$1") || return 1
    ensure_datadir
    SEALER_KEY_FILE="${DATADIR}/sealer.key"
    umask 077
    printf '%s\n' "$hex" > "$SEALER_KEY_FILE"
    chmod 600 "$SEALER_KEY_FILE"
    unset hex
    SEALER_ACCOUNT=now
    log "已写入验证节点私钥，权限仅所有者可读"
}

skip_sealer_account() {
    SEALER_ACCOUNT=later
    log "部署模式保持为$(mode_label)。安装脚本不生成账户。"
    if sealer_key_ok; then
        log "已有密封密钥继续使用"
        return 0
    fi
    log "稍后在本机生成账户: geth account new --datadir ${DATADIR}"
}

install_sealer_key() {
    local hex
    hex=$(read_sealer_hex "$1") || return 1
    write_sealer_hex "$hex"
    unset hex
}

install_sealer_source() {
    local src="$1"
    if [[ -n "$src" && -f "$src" && -r "$src" ]]; then
        install_sealer_key "$src"
        return
    fi
    write_sealer_hex "$src"
}

prompt_sealer_privkey() {
    local first second
    while true; do
        printf '验证节点私钥（64 位十六进制，输入不回显）: ' >/dev/tty
        IFS= read -rs first </dev/tty || return 1
        printf '\n请再次输入: ' >/dev/tty
        IFS= read -rs second </dev/tty || return 1
        printf '\n' >/dev/tty
        if [[ -n "$first" && "$first" == "$second" ]] && write_sealer_hex "$first"; then
            unset first second
            return 0
        fi
        unset first second
        printf '两次输入不一致，或不是 64 位十六进制私钥\n' >/dev/tty
    done
}

prompt_sealer_key() {
    local path
    while true; do
        printf '验证节点私钥文件路径: ' >/dev/tty
        IFS= read -r path </dev/tty || return 1
        if [[ -n "$path" ]] && install_sealer_key "$path"; then
            return 0
        fi
        printf '文件不存在，或内容不是 64 位十六进制私钥\n' >/dev/tty
    done
}

choose_sealer_input() {
    local choice
    choice=$(prompt_choice "验证节点账户" \
        "输入私钥" \
        "使用密钥文件" \
        "跳过创建账户，稍后在 geth 中生成")
    case "$choice" in
        2) prompt_sealer_key ;;
        3) skip_sealer_account ;;
        *) prompt_sealer_privkey ;;
    esac
}

apply_explicit_sealer_key() {
    local env_key="${PANTANAL_SEALER_KEY:-}"
    [[ "$SEALER" == on && -n "$env_key" ]] || return 0
    if install_sealer_source "$env_key"; then
        return 0
    fi
    log "PANTANAL_SEALER_KEY 不是有效的私钥或密钥文件"
    return 1
}

explain_sealer_key() {
    local mode
    if [[ ! -f "$SEALER_KEY_FILE" ]]; then
        log "出块模式需要运营者提供的验证节点私钥。安装脚本不生成私钥。可在终端中输入，把私钥或密钥文件路径放在 PANTANAL_SEALER_KEY，事先写入 ${SEALER_KEY_FILE}，或设置 PANTANAL_SEALER_ACCOUNT=skip 后执行 geth account new --datadir ${DATADIR}。私钥不进入命令行，也不写入 geth.log。"
        return 0
    fi
    mode=$(file_mode "$SEALER_KEY_FILE")
    if [[ "$mode" != "600" ]]; then
        log "密封密钥文件权限必须仅为所有者可读: ${SEALER_KEY_FILE}"
        return 0
    fi
    log "密封密钥内容不是 64 位十六进制私钥: ${SEALER_KEY_FILE}"
}

ensure_sealer_key() {
    local env_key="${PANTANAL_SEALER_KEY:-}" env_account="${PANTANAL_SEALER_ACCOUNT:-}"
    SEALER_KEY_FILE="${DATADIR}/sealer.key"
    if [[ "$SEALER" != on ]]; then
        return 0
    fi
    case "$env_account" in
        skip|later) SEALER_ACCOUNT=later ;;
    esac
    if sealer_key_ok; then
        SEALER_ACCOUNT=now
        return 0
    fi
    if [[ -n "$env_key" ]]; then
        if install_sealer_source "$env_key" && sealer_key_ok; then
            return 0
        fi
        log "PANTANAL_SEALER_KEY 不是有效的私钥或密钥文件"
    fi
    if [[ "$SEALER_ACCOUNT" == later ]]; then
        log "部署模式保持为$(mode_label)。安装脚本不生成账户。"
        log "稍后在本机生成账户: geth account new --datadir ${DATADIR}"
        return 0
    fi
    if [[ -f "$SEALER_KEY_FILE" ]]; then
        explain_sealer_key
    fi
    if have_tty; then
        choose_sealer_input
        return $?
    fi
    explain_sealer_key
    return 1
}

configure_sealer_interactive() {
    local choice
    [[ "$SEALER" == on ]] || return 0
    if sealer_key_ok; then
        choice=$(prompt_choice "本机已有验证节点账户" \
            "继续使用" \
            "输入新的私钥" \
            "更换密钥文件" \
            "跳过创建账户，稍后在 geth 中生成")
        case "$choice" in
            2) prompt_sealer_privkey ;;
            3) prompt_sealer_key ;;
            4) skip_sealer_account ;;
            *) return 0 ;;
        esac
        return $?
    fi
    choose_sealer_input
}

file_mode() {
    if [[ "$OS_FAMILY" == macos ]]; then
        stat -f '%OLp' "$1" 2>/dev/null || true
    else
        stat -c '%a' "$1" 2>/dev/null || true
    fi
}

file_sha() {
    [[ -f "$1" ]] || return 0
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        shasum -a 256 "$1" | awk '{print $1}'
    fi
}

console_password_mode() {
    file_mode "$CONSOLE_PASSWORD_FILE"
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

choose_deploy_mode() {
    local choice
    choice=$(prompt_choice "选择部署模式" \
        "同步节点：只保留当前状态，不出块" \
        "归档节点：保留全部历史状态，不出块" \
        "出块节点：只保留当前状态，用自己的私钥作为验证节点账户" \
        "归档出块节点：保留全部历史状态，用自己的私钥作为验证节点账户")
    case "$choice" in
        2) apply_deploy_mode archive ;;
        3) apply_deploy_mode seal ;;
        4) apply_deploy_mode archive-seal ;;
        *) apply_deploy_mode full ;;
    esac
    log "部署模式: $(mode_label)"
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

write_run_mode() {
    printf '%s %s\n' "$GCMODE" "$SEALER" > "$RUN_MODE_FILE"
}

start_geth() {
    local geth pid
    case "$GCMODE" in
        full|archive) ;;
        *)
            log "gcmode 只能是 full 或 archive"
            return 1
            ;;
    esac
    [[ "$SEALER" == on || "$SEALER" == off ]] || SEALER=off
    if ! ensure_console_password; then
        return 1
    fi
    if ! ensure_sealer_key; then
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
    log "启动 Pantanal 公链节点 (${OS_ID}, $(mode_label))"
    console_args || return 1
    local -a cmd
    cmd=(
        "$geth"
        --Pantanal
        --datadir "$DATADIR"
        --port "$P2P_PORT"
        --syncmode full
        --gcmode "$GCMODE"
        --http
        --http.addr "$HTTP_ADDR"
        --http.port "$HTTP_PORT"
        --http.api "$HTTP_API"
        --maxpeers 100
        --verbosity 3
    )
    if [[ "$SEALER" == on ]] && sealer_key_ok; then
        cmd+=(--pantanal.sealerkey "$SEALER_KEY_FILE")
        log "密封密钥: ${SEALER_KEY_FILE}"
    elif [[ "$SEALER" == on ]]; then
        log "部署模式保持为$(mode_label)。本次不加载密封密钥。"
        log "稍后在本机生成账户: geth account new --datadir ${DATADIR}"
    else
        log "本次不加载密封密钥"
    fi
    if ((${#CONSOLE_ARGS[@]} > 0)); then
        cmd+=("${CONSOLE_ARGS[@]}")
    fi
    nohup "${cmd[@]}" >> "$LOG_FILE" 2>&1 < /dev/null &
    pid=$!
    printf '%s\n' "$pid" > "$PID_FILE"
    disown "$pid" 2>/dev/null || true
    sleep 3
    if kill -0 "$pid" 2>/dev/null; then
        write_run_mode
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
    local mode="${1:-full}"
    load_node_conf
    if ! apply_deploy_mode "$mode"; then
        log "部署模式只能是 full、archive、seal、archive-seal"
        return 1
    fi
    log "部署模式: $(mode_label)"
    if ! apply_explicit_sealer_key; then
        return 1
    fi
    if ! ensure_sealer_key; then
        return 1
    fi
    if ! ensure_console_password; then
        return 1
    fi
    save_node_conf
    sync_geth
    stop_geth
    start_geth
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
    log "部署模式: $(mode_label)"
    log "gcmode: ${GCMODE}"
    if [[ "$SEALER" == on ]]; then
        if sealer_key_ok; then
            log "密封密钥: 已配置"
        elif [[ "$SEALER_ACCOUNT" == later ]]; then
            log "验证节点账户: 稍后在 geth 中生成。部署模式保持为$(mode_label)"
        else
            log "密封密钥: 不可用"
        fi
    else
        log "密封密钥: 不加载"
    fi
    if pid=$(running_pid) && [[ -f "$RUN_MODE_FILE" ]]; then
        local run_gc run_sealer saved_gc saved_sealer
        read -r run_gc run_sealer < "$RUN_MODE_FILE" || true
        saved_gc=$GCMODE
        saved_sealer=$SEALER
        if [[ -n "$run_gc" && -n "$run_sealer" && ( "$run_gc" != "$saved_gc" || "$run_sealer" != "$saved_sealer" ) ]]; then
            local saved_label
            saved_label=$(mode_label)
            GCMODE=$run_gc
            SEALER=$run_sealer
            log "进程仍是上次启动的$(mode_label)。保存的模式是${saved_label}，重启后生效"
            GCMODE=$saved_gc
            SEALER=$saved_sealer
        fi
    fi
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
        stop_geth
        start_geth
        return 0
    fi
    if running_pid >/dev/null; then
        log "geth 运行正常 (PID $(running_pid))"
        return 0
    fi
    log "geth 未运行，正在启动"
    start_geth
}

start_command() {
    local mode="${1:-}"
    load_node_conf
    local prev_gc="$GCMODE" prev_sealer="$SEALER" before_key="" after_key=""
    before_key=$(file_sha "${DATADIR}/sealer.key")
    if [[ -n "$mode" ]]; then
        if ! apply_deploy_mode "$mode"; then
            log "部署模式只能是 full、archive、seal、archive-seal"
            return 1
        fi
        log "部署模式: $(mode_label)"
        if ! apply_explicit_sealer_key; then
            return 1
        fi
        save_node_conf
    fi
    after_key=$(file_sha "${DATADIR}/sealer.key")
    sync_geth
    if [[ "$GETH_UPDATED" == 1 ]] || ! running_pid >/dev/null; then
        if running_pid >/dev/null; then
            stop_geth
        fi
        start_geth
        return 0
    fi
    if [[ -n "$mode" && ( "$prev_gc" != "$GCMODE" || "$prev_sealer" != "$SEALER" || "$before_key" != "$after_key" ) ]]; then
        log "部署模式已变更，正在重启"
        stop_geth
        start_geth
        return 0
    fi
    log "geth 已在运行，且已是最新版本 (PID $(running_pid))"
    apply_firewall
}

guide_install() {
    load_node_conf
    choose_deploy_mode
    configure_sealer_interactive || return 1
    require_console_password
    save_node_conf
    sync_geth
    if [[ "$GETH_UPDATED" == 1 ]]; then
        stop_geth
        start_geth
        return 0
    fi
    local choice
    if running_pid >/dev/null; then
        choice=$(prompt_choice "geth 已是最新版本，并且正在运行。本次选择：$(mode_label)" \
            "保持运行" \
            "按本次选择重启")
        if [[ "$choice" == 2 ]]; then
            stop_geth
            start_geth
        else
            log "已保存部署模式：$(mode_label)。当前进程保持运行，下次启动时生效"
            apply_firewall
        fi
        return 0
    fi
    choice=$(prompt_choice "geth 已准备好" \
        "现在启动" \
        "稍后再启动")
    if [[ "$choice" == 1 ]]; then
        start_geth
    fi
}

guide_start() {
    load_node_conf
    local choice reconfigured=0
    if [[ -f "$NODE_CONF" ]]; then
        choice=$(prompt_choice "启动方式" \
            "使用上次的设置（$(mode_label)）" \
            "重新选择部署模式并设置控制台口令")
        if [[ "$choice" == 2 ]]; then
            choose_deploy_mode
            configure_sealer_interactive || return 1
            require_console_password
            save_node_conf
            reconfigured=1
        fi
    else
        choose_deploy_mode
        configure_sealer_interactive || return 1
        require_console_password
        save_node_conf
        reconfigured=1
    fi
    sync_geth
    if [[ "$GETH_UPDATED" == 1 ]]; then
        stop_geth
        start_geth
        return 0
    fi
    if running_pid >/dev/null; then
        if [[ "$reconfigured" == 0 ]]; then
            log "geth 正在运行 (PID $(running_pid))"
            apply_firewall
            return 0
        fi
        choice=$(prompt_choice "geth 正在运行。本次选择：$(mode_label)" \
            "保持运行" \
            "按本次选择重启")
        if [[ "$choice" == 2 ]]; then
            stop_geth
            start_geth
        else
            log "已保存部署模式：$(mode_label)。当前进程保持运行，下次启动时生效"
            apply_firewall
        fi
        return 0
    fi
    start_geth
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

直接运行会选择部署模式，并设置手机控制台口令。
发现更新的 Release 时覆盖 geth 并重启节点。

用法: $(basename "$0") <command> [mode]

部署模式:
  full            同步节点。只保留当前状态，不出块。这也是默认模式
  archive         归档节点。保留全部历史状态，不出块
  seal            出块节点。只保留当前状态，并加载密封密钥
  archive-seal    归档出块节点。保留全部历史状态，并加载密封密钥
  sync            与 full 相同

  install [mode]      安装并启动。不带 mode 且在终端中运行时进入选择菜单
  start [mode]        启动节点。不带 mode 时沿用上次的部署模式
                      带 mode 且与正在运行的模式不同时，先停止再按新模式启动
                      有新版本时先覆盖再重启
  stop                停止节点
  status              查看进程、部署模式和链 ID
  monitor             巡检。有新版本时覆盖并重启，退出后按上次的部署模式拉起
  help                显示此说明

公链参数由 geth --Pantanal 决定：NetworkId 1122、内置创世块、公网 bootnode。
当前系统 ${OS_ID} (${ARCH})。数据目录 ${DATADIR}，程序目录 ${BIN_DIR}。
同步模式为 full。
发布包: ${RELEASE_BASE}/geth-<os>-<arch>.tar.gz 或 .zip

出块模式的验证节点私钥由运营者自己提供。安装脚本不生成私钥，也不生成账户。
交互运行时可以输入私钥、填写密钥文件路径，或跳过创建账户。输入时不回显，并再输入一次确认。
跳过时部署模式保持不变。账户稍后在本机执行 geth account new --datadir ${DATADIR}。
提供的私钥写入 ${DATADIR}/sealer.key，权限仅所有者可读，并以 --pantanal.sealerkey 加载。
非交互出块可把 PANTANAL_SEALER_KEY 设为这枚私钥或密钥文件路径。
PANTANAL_SEALER_ACCOUNT=skip 表示跳过创建账户。已有合法的 sealer.key 时直接使用。
未跳过且没有可用私钥时，出块模式不启动节点。私钥不进入命令行，也不写入 geth.log。
同步节点和归档节点不加载密封密钥。

部署时必须设置手机控制台口令，至少 8 个字符。
控制台只绑定 127.0.0.1:${CONSOLE_PORT}，不接受外网连接。
口令写入 ${DATADIR}/console.password，权限为仅所有者可读。
非交互安装可事先设置 PANTANAL_CONSOLE_PASSWORD，脚本把它写入口令文件。
非交互安装也可以设置 PANTANAL_MODE 为 full、archive、seal 或 archive-seal。
口令不进入命令行，也不写入 geth.log。
节点启动后执行 ${FIREWALL_URL} ${OS_ID}。
Ubuntu 与 Debian 使用 ufw，Fedora、RHEL 及兼容系统使用 firewalld，macOS 使用应用程序防火墙，Windows 使用 Windows 防火墙。
放行 SSH 与 P2P ${P2P_PORT}。
EOF
}

main() {
    local command="${1:-}"
    case "$command" in
        "")
            if have_tty; then
                interactive_menu
            else
                install_node "${PANTANAL_MODE:-full}"
            fi
            ;;
        install)
            if [[ -z "${2:-}" && $(have_tty && echo yes || true) == yes ]]; then
                interactive_menu
            else
                install_node "${2:-${PANTANAL_MODE:-full}}"
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
