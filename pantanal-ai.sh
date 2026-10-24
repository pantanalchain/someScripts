#!/bin/bash
# Pantanal AI 服务安装与管理。
#
# 在 pantanal.sh 使用的同一数据目录上安装 Gateway 与 Node Agent。
# Gateway 监听 127.0.0.1:8787，Node Agent 监听 127.0.0.1:8788。
# 上游 Key、主密钥、nodeSecret、keystore 口令和私钥只写在仅所有者可读的文件中。
# 启动参数只包含这些文件的路径。
# 发现更新的 Release 时覆盖已安装的程序，并重启 AI 服务。
# 8787 与 8788 不对外开放。
# 公网 IP 的 80 端口把 /v1/ 与 /healthz 转到 127.0.0.1:8787。
# 配置了域名且已有 TLS 证书时，443 做同样的转发。

set -euo pipefail

RELEASE_BASE="https://github.com/pantanalchain/someScripts/releases/latest/download"
RELEASE_API="https://api.github.com/repos/pantanalchain/someScripts/releases/latest"
GATEWAY_PORT=8787
AGENT_PORT=8788
RPC_URL="http://127.0.0.1:8545"
AI_NAMES=(pantanal-gateway pantanal-node-agent pantanal-settlement-proposer pantanal-consensus-agent pantanal-aivc-agent)

PROVIDER=""
MODELS=""
TIER=""
PROFILE_ID=""
LABEL=""
PUBLIC_IP=""
PUBLIC_HOST=""
AI_UPDATED=0

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
    AI_DIR="${DATADIR}/ai"
    AI_CONF="${DATADIR}/ai.conf"
    SEALER_KEY_FILE="${DATADIR}/sealer.key"
    GATEWAY_SECRET_FILE="${AI_DIR}/gateway.secret"
    NODE_SECRET_FILE="${AI_DIR}/node.secret"
    PASS_FILE="${AI_DIR}/keystore.pass"
    UPSTREAM_FILE="${AI_DIR}/upstream.key"
    SESSION_FILE="${AI_DIR}/session-agent.key"
    GATEWAY_PID="${AI_DIR}/gateway.pid"
    AGENT_PID="${AI_DIR}/agent.pid"
    GATEWAY_LOG="${AI_DIR}/gateway.log"
    AGENT_LOG="${AI_DIR}/agent.log"
    STAMP_FILE="${AI_DIR}/release.stamp"
    RUN_STAMP="${AI_DIR}/running.stamp"
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
    local first second min="$2"
    while true; do
        printf '%s' "$1" >/dev/tty
        IFS= read -rs first </dev/tty || return 1
        printf '\n请再次输入: ' >/dev/tty
        IFS= read -rs second </dev/tty || return 1
        printf '\n' >/dev/tty
        if [[ ${#first} -ge $min && "$first" == "$second" ]]; then
            printf '%s' "$first"
            return 0
        fi
        printf '两次输入不一致，或少于 %d 个字符\n' "$min" >/dev/tty
    done
}

prompt_default() {
    local reply
    printf '%s [%s]: ' "$1" "$2" >/dev/tty
    IFS= read -r reply </dev/tty || return 1
    if [[ -n "$reply" ]]; then
        printf '%s' "$reply"
    else
        printf '%s' "$2"
    fi
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

ensure_datadir() {
    if [[ "$DATADIR" == /data/* ]]; then
        as_root mkdir -p "$DATADIR" "$AI_DIR"
        as_root chown "$(id -u):$(id -g)" "$DATADIR" "$AI_DIR"
    else
        mkdir -p "$DATADIR" "$AI_DIR"
    fi
}

clear_secret_env() {
    unset PANTANAL_UPSTREAM_KEY PANTANAL_KEYSTORE_PASS PANTANAL_GATEWAY_SECRET \
        PANTANAL_WORKER_KEY PANTANAL_PROPOSER_KEY PANTANAL_SESSION_AGENT_KEY \
        PANTANAL_SETTLEMENT_KEY || true
}

load_ai_conf() {
    PROVIDER=""
    MODELS=""
    TIER=""
    PROFILE_ID=""
    LABEL=""
    PUBLIC_IP=""
    PUBLIC_HOST=""
    [[ -f "$AI_CONF" ]] || return 0
    local key value
    while IFS='=' read -r key value; do
        case "$key" in
            PROVIDER) PROVIDER=$value ;;
            MODELS) MODELS=$value ;;
            TIER) TIER=$value ;;
            PROFILE_ID) PROFILE_ID=$value ;;
            LABEL) LABEL=$value ;;
            PUBLIC_IP) PUBLIC_IP=$value ;;
            PUBLIC_HOST) PUBLIC_HOST=$value ;;
        esac
    done < "$AI_CONF"
}

save_ai_conf() {
    ensure_datadir
    umask 077
    cat > "$AI_CONF" <<EOF
PROVIDER=${PROVIDER}
MODELS=${MODELS}
TIER=${TIER}
PROFILE_ID=${PROFILE_ID}
LABEL=${LABEL}
PUBLIC_IP=${PUBLIC_IP}
PUBLIC_HOST=${PUBLIC_HOST}
EOF
    chmod 600 "$AI_CONF"
}

apply_provider_defaults() {
    if [[ -n "${PANTANAL_AI_PROVIDER:-}" ]]; then
        PROVIDER=$PANTANAL_AI_PROVIDER
    fi
    if [[ -n "${PANTANAL_AI_MODELS:-}" ]]; then
        MODELS=$PANTANAL_AI_MODELS
    fi
    if [[ -n "${PANTANAL_AI_TIER:-}" ]]; then
        TIER=$PANTANAL_AI_TIER
    fi
    if [[ -n "${PANTANAL_AI_PROFILE:-}" ]]; then
        PROFILE_ID=$PANTANAL_AI_PROFILE
    fi
    if [[ -n "${PANTANAL_AI_LABEL:-}" ]]; then
        LABEL=$PANTANAL_AI_LABEL
    fi
    [[ -n "$PROVIDER" ]] || PROVIDER=openai
    if [[ -z "$MODELS" ]]; then
        if [[ "$PROVIDER" == deepseek ]]; then
            MODELS=deepseek-chat
        else
            MODELS=gpt-4o-mini
        fi
    fi
    [[ -n "$TIER" ]] || TIER=default
}

fill_empty_defaults() {
    [[ -n "$PROVIDER" ]] || PROVIDER=openai
    if [[ -z "$MODELS" ]]; then
        if [[ "$PROVIDER" == deepseek ]]; then
            MODELS=deepseek-chat
        else
            MODELS=gpt-4o-mini
        fi
    fi
    [[ -n "$TIER" ]] || TIER=default
}

choose_provider() {
    local choice
    choice=$(prompt_choice "上游提供商" \
        "OpenAI，默认模型 gpt-4o-mini" \
        "DeepSeek，默认模型 deepseek-chat" \
        "自行填写提供商和模型")
    case "$choice" in
        2)
            PROVIDER=deepseek
            MODELS=$(prompt_default "模型，多个用逗号分隔" "deepseek-chat")
            ;;
        3)
            PROVIDER=$(prompt_default "提供商名称" "openai")
            MODELS=$(prompt_default "模型，多个用逗号分隔" "gpt-4o-mini")
            ;;
        *)
            PROVIDER=openai
            MODELS=$(prompt_default "模型，多个用逗号分隔" "gpt-4o-mini")
            ;;
    esac
    TIER=$(prompt_default "档位" "default")
    printf 'profile 编号（留空则按提供商或档位生成）: ' >/dev/tty
    IFS= read -r PROFILE_ID </dev/tty || return 1
    printf '显示名称（可留空）: ' >/dev/tty
    IFS= read -r LABEL </dev/tty || return 1
    [[ -n "$PROVIDER" && -n "$MODELS" ]]
}

write_secret_file() {
    local dest="$1" value="$2"
    ensure_datadir
    (
        umask 077
        printf '%s\n' "$value" > "$dest"
    )
    chmod 600 "$dest"
}

secret_ok() {
    local file="$1" min="$2" mode secret
    [[ -f "$file" ]] || return 1
    mode=$(file_mode "$file")
    if [[ "$mode" != "600" ]]; then
        chmod 600 "$file" 2>/dev/null || return 1
    fi
    IFS= read -r secret < "$file" || return 1
    [[ ${#secret} -ge $min ]]
}

ensure_secret_file() {
    local file="$1" min="$2" title="$3" env_value="$4" interactive="$5" generated="${6:-}"
    if secret_ok "$file" "$min"; then
        if [[ "$interactive" == interactive ]]; then
            local choice
            choice=$(prompt_choice "$title" "继续使用" "更换")
            if [[ "$choice" != 2 ]]; then
                return 0
            fi
        else
            return 0
        fi
    elif [[ "$interactive" != interactive && -n "$env_value" ]]; then
        write_secret_file "$file" "$env_value"
        return 0
    fi
    if [[ "$interactive" == interactive ]]; then
        local secret
        secret=$(prompt_secret "${title}（至少 ${min} 个字符，输入不回显）: " "$min") || return 1
        write_secret_file "$file" "$secret"
        unset secret
        return 0
    fi
    if [[ -n "$generated" ]]; then
        local secret
        secret=$(generate_secret) || return 1
        write_secret_file "$file" "$secret"
        unset secret
        log "已生成本机 Gateway 主密钥"
        return 0
    fi
    if [[ -n "$env_value" ]]; then
        write_secret_file "$file" "$env_value"
        return 0
    fi
    log "${title}还没有配置。在终端中输入，或事先写入 ${file}，或提供对应的环境变量。"
    return 1
}

generate_secret() {
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -hex 32
        return
    fi
    command -v python3 >/dev/null 2>&1 || {
        log "需要 openssl 或 python3 来生成主密钥"
        return 1
    }
    python3 - <<'PY'
import secrets
print(secrets.token_hex(32))
PY
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

sealer_key_ok() {
    local mode raw
    [[ -f "$SEALER_KEY_FILE" ]] || return 1
    mode=$(file_mode "$SEALER_KEY_FILE")
    [[ "$mode" == "600" ]] || return 1
    raw=$(head -c 256 < "$SEALER_KEY_FILE" | tr -d '[:space:]') || return 1
    normalize_sealer_hex "$raw" >/dev/null
}

ensure_sealer() {
    if sealer_key_ok; then
        return 0
    fi
    log "AI 服务使用本机密封密钥 ${SEALER_KEY_FILE} 作为 Worker 私钥和结算提议者私钥。"
    log "先用 pantanal.sh 以出块模式写入该文件。文件必须仅所有者可读，内容为 64 位十六进制私钥。"
    return 1
}

valid_public_ip() {
    local ip="$1" a b c d
    [[ "$ip" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
    a=${BASH_REMATCH[1]}
    b=${BASH_REMATCH[2]}
    c=${BASH_REMATCH[3]}
    d=${BASH_REMATCH[4]}
    [[ $((10#$a)) -le 255 && $((10#$b)) -le 255 && $((10#$c)) -le 255 && $((10#$d)) -le 255 ]] || return 1
    case "$ip" in
        10.*|127.*|0.*|169.254.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[0-1].*) return 1 ;;
    esac
}

normalize_host() {
    local host="$1"
    host=${host#https://}
    host=${host#http://}
    host=${host%%/*}
    host=${host%:*}
    printf '%s' "$host"
}

valid_host() {
    local host="$1"
    [[ "$host" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] || return 1
    [[ "$host" == *.* ]] || return 1
    valid_public_ip "$host" && return 1
    return 0
}

detect_public_ip() {
    local ip url
    for url in https://api.ipify.org https://ifconfig.me/ip; do
        ip=$(curl -4 -fsS -m 5 "$url" 2>/dev/null || true)
        ip=$(printf '%s' "$ip" | tr -d '[:space:]')
        if valid_public_ip "$ip"; then
            printf '%s\n' "$ip"
            return 0
        fi
    done
    return 1
}

choose_public() {
    local detected=""
    detected=$(detect_public_ip || true)
    if [[ -z "$PUBLIC_IP" ]]; then
        PUBLIC_IP=$detected
    fi
    if [[ -n "$PUBLIC_IP" ]]; then
        PUBLIC_IP=$(prompt_default "公网 IP" "$PUBLIC_IP")
    else
        printf '公网 IP: ' >/dev/tty
        IFS= read -r PUBLIC_IP </dev/tty || return 1
    fi
    PUBLIC_IP=$(printf '%s' "$PUBLIC_IP" | tr -d '[:space:]')
    valid_public_ip "$PUBLIC_IP" || {
        log "不是可用的公网 IPv4: ${PUBLIC_IP}"
        return 1
    }
    printf '域名（留空则只使用公网 IP 的 80 端口）: ' >/dev/tty
    IFS= read -r PUBLIC_HOST </dev/tty || return 1
    PUBLIC_HOST=$(normalize_host "$PUBLIC_HOST")
    if [[ -n "$PUBLIC_HOST" ]] && ! valid_host "$PUBLIC_HOST"; then
        log "域名无效: ${PUBLIC_HOST}"
        return 1
    fi
}

apply_public_env() {
    if [[ -n "${PANTANAL_PUBLIC_IP:-}" ]]; then
        PUBLIC_IP=$(printf '%s' "$PANTANAL_PUBLIC_IP" | tr -d '[:space:]')
    fi
    if [[ -n "${PANTANAL_PUBLIC_HOST:-}" ]]; then
        PUBLIC_HOST=$(normalize_host "$PANTANAL_PUBLIC_HOST")
    fi
}

configure_ai() {
    local interactive="${1:-}"
    load_ai_conf
    if [[ "$interactive" == interactive ]]; then
        choose_provider || return 1
    else
        apply_provider_defaults
    fi
    ensure_secret_file "$UPSTREAM_FILE" 8 "上游 Key" "${PANTANAL_UPSTREAM_KEY:-}" "$interactive" || return 1
    ensure_secret_file "$PASS_FILE" 8 "keystore 口令" "${PANTANAL_KEYSTORE_PASS:-}" "$interactive" || return 1
    if [[ "$interactive" == interactive ]] && ! secret_ok "$GATEWAY_SECRET_FILE" 16; then
        local choice secret
        choice=$(prompt_choice "Gateway 主密钥" "生成本机主密钥" "输入已有主密钥")
        if [[ "$choice" == 2 ]]; then
            secret=$(prompt_secret "Gateway 主密钥（至少 16 个字符，输入不回显）: " 16) || return 1
            write_secret_file "$GATEWAY_SECRET_FILE" "$secret"
            unset secret
        else
            secret=$(generate_secret) || return 1
            write_secret_file "$GATEWAY_SECRET_FILE" "$secret"
            unset secret
            log "已生成本机 Gateway 主密钥"
        fi
    else
        ensure_secret_file "$GATEWAY_SECRET_FILE" 16 "Gateway 主密钥" "${PANTANAL_GATEWAY_SECRET:-}" "$interactive" generate || return 1
    fi
    ensure_sealer || return 1
    if [[ "$interactive" == interactive ]]; then
        choose_public || return 1
    else
        apply_public_env
    fi
    save_ai_conf
    clear_secret_env
    log "上游提供商: ${PROVIDER}"
    log "模型: ${MODELS}"
}

require_python() {
    command -v python3 >/dev/null 2>&1 || {
        log "需要 python3 来派生节点密钥"
        return 1
    }
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
    printf 'pantanal-ai-%s-%s.%s\n' "$os" "$ARCH" "$ext"
}

ai_bin() {
    local name="$1"
    if [[ -x "${BIN_DIR}/${name}" ]]; then
        printf '%s\n' "${BIN_DIR}/${name}"
    elif [[ -x "${BIN_DIR}/${name}.exe" ]]; then
        printf '%s\n' "${BIN_DIR}/${name}.exe"
    else
        return 1
    fi
}

ai_installed() {
    local name
    for name in "${AI_NAMES[@]}"; do
        ai_bin "$name" >/dev/null || return 1
    done
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

place_bin() {
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
    log "已安装 ${dest}"
}

download_release() {
    local asset="$1" archive
    command -v curl >/dev/null 2>&1 || {
        log "需要 curl"
        return 1
    }
    DL_DIR=$(mktemp -d)
    archive="${DL_DIR}/${asset}"
    log "下载最新 AI 程序: ${RELEASE_BASE}/${asset}"
    curl -fL --retry 3 --retry-delay 2 -o "$archive" "${RELEASE_BASE}/${asset}"
    case "$asset" in
        *.tar.gz) tar -xzf "$archive" -C "$DL_DIR" ;;
        *.zip)
            if command -v unzip >/dev/null 2>&1; then
                unzip -qo "$archive" -d "$DL_DIR"
            else
                require_python
                python3 -m zipfile -e "$archive" "$DL_DIR"
            fi
            ;;
    esac
}

sync_ai() {
    local asset meta name found
    AI_UPDATED=0
    asset=$(platform_asset)
    meta=$(remote_asset_meta "$asset" || true)
    if ai_installed && [[ -n "$meta" && -f "$STAMP_FILE" ]]; then
        if [[ "$(awk '{print $1, $2}' "$STAMP_FILE")" == "$meta" ]]; then
            log "AI 程序已是最新版本"
            return 0
        fi
    fi
    if ai_installed && [[ -z "$meta" ]]; then
        log "无法查询最新 Release，继续使用已安装的 AI 程序"
        return 0
    fi
    download_release "$asset"
    for name in "${AI_NAMES[@]}"; do
        found=""
        while IFS= read -r candidate; do
            found=$candidate
            break
        done < <(find "$DL_DIR" -type f \( -name "$name" -o -name "${name}.exe" \))
        if [[ -z "$found" ]]; then
            rm -rf "$DL_DIR"
            DL_DIR=""
            log "发布包中没有 ${name}"
            return 1
        fi
        place_bin "$found"
    done
    ensure_datadir
    if [[ -n "$meta" ]]; then
        printf '%s\n' "$meta" > "$STAMP_FILE"
    fi
    rm -rf "$DL_DIR"
    DL_DIR=""
    AI_UPDATED=1
}

running_pid() {
    local pidfile="$1" pid
    [[ -f "$pidfile" ]] || return 1
    pid=$(cat "$pidfile")
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
        printf '%s\n' "$pid"
        return 0
    fi
    return 1
}

ai_running() {
    running_pid "$GATEWAY_PID" >/dev/null && running_pid "$AGENT_PID" >/dev/null
}

stop_pid_file() {
    local pidfile="$1" label="$2" pid
    if ! pid=$(running_pid "$pidfile"); then
        rm -f "$pidfile"
        return 0
    fi
    log "正在停止 ${label} (PID ${pid})"
    kill "$pid" 2>/dev/null || true
    local i
    for i in 1 2 3 4 5; do
        if ! kill -0 "$pid" 2>/dev/null; then
            rm -f "$pidfile"
            log "${label} 已停止"
            return 0
        fi
        sleep 1
    done
    kill -9 "$pid" 2>/dev/null || true
    rm -f "$pidfile"
    log "${label} 已强制停止"
}

stop_ai() {
    stop_pid_file "$AGENT_PID" "Node Agent"
    stop_pid_file "$GATEWAY_PID" "Gateway"
    stop_pid_file "${AI_DIR}/proposer.pid" "settlement proposer"
    stop_pid_file "${AI_DIR}/consensus.pid" "consensus agent"
}

worker_address() {
    local bin
    clear_secret_env
    bin=$(ai_bin pantanal-node-agent)
    "$bin" -cmd address -worker-key-file "$SEALER_KEY_FILE"
}

write_node_secret() {
    local addr master
    require_python
    addr=$(worker_address)
    [[ "$addr" =~ ^0x[0-9a-fA-F]{40}$ ]] || {
        log "无法从密封密钥得到节点地址"
        return 1
    }
    NODE_ADDRESS=$addr
    master=$(tr -d '[:space:]' < "$GATEWAY_SECRET_FILE")
    ensure_datadir
    (
        umask 077
        PANTANAL_AI_MASTER="$master" python3 - "$addr" > "$NODE_SECRET_FILE" <<'PY'
import hmac, hashlib, os, sys, binascii
master = os.environ.get("PANTANAL_AI_MASTER", "")
addr = sys.argv[1]
if addr[:2].lower() == "0x":
    addr = addr[2:]
if len(master) == 0 or len(addr) != 40:
    raise SystemExit(1)
print(hmac.new(master.encode(), b"pantanal-node-v1" + binascii.unhexlify(addr), hashlib.sha256).hexdigest())
PY
    )
    unset master
    chmod 600 "$NODE_SECRET_FILE"
    secret_ok "$NODE_SECRET_FILE" 64
}

store_profile() {
    local bin
    clear_secret_env
    bin=$(ai_bin pantanal-node-agent)
    if [[ -n "$PROFILE_ID" && -n "$LABEL" ]]; then
        "$bin" -cmd profile-set -key-file "$UPSTREAM_FILE" -passphrase-file "$PASS_FILE" \
            -provider "$PROVIDER" -models "$MODELS" -tier "$TIER" \
            -profile-id "$PROFILE_ID" -label "$LABEL"
    elif [[ -n "$PROFILE_ID" ]]; then
        "$bin" -cmd profile-set -key-file "$UPSTREAM_FILE" -passphrase-file "$PASS_FILE" \
            -provider "$PROVIDER" -models "$MODELS" -tier "$TIER" \
            -profile-id "$PROFILE_ID"
    elif [[ -n "$LABEL" ]]; then
        "$bin" -cmd profile-set -key-file "$UPSTREAM_FILE" -passphrase-file "$PASS_FILE" \
            -provider "$PROVIDER" -models "$MODELS" -tier "$TIER" \
            -label "$LABEL"
    else
        "$bin" -cmd profile-set -key-file "$UPSTREAM_FILE" -passphrase-file "$PASS_FILE" \
            -provider "$PROVIDER" -models "$MODELS" -tier "$TIER"
    fi
}

runtime_stamp() {
    printf '%s %s %s %s %s\n' \
        "$(file_sha "$AI_CONF")" \
        "$(file_sha "$SEALER_KEY_FILE")" \
        "$(file_sha "$GATEWAY_SECRET_FILE")" \
        "$(file_sha "$UPSTREAM_FILE")" \
        "$(file_sha "$PASS_FILE")"
}

config_changed() {
    [[ -f "$RUN_STAMP" ]] || return 0
    [[ "$(runtime_stamp)" == "$(cat "$RUN_STAMP")" ]] && return 1
    return 0
}

start_processes() {
    local gateway agent
    clear_secret_env
    gateway=$(ai_bin pantanal-gateway)
    agent=$(ai_bin pantanal-node-agent)
    ensure_datadir
    log "启动 Gateway 127.0.0.1:${GATEWAY_PORT}"
    PANTANAL_ALLOW_LOOPBACK=1 \
    PANTANAL_WORKER_ENDPOINTS="${NODE_ADDRESS}=http://127.0.0.1:${AGENT_PORT}" \
    PANTANAL_COMPANION_DIR="$AI_DIR" \
        nohup "$gateway" -cmd serve \
            -listen "127.0.0.1:${GATEWAY_PORT}" \
            -rpc "$RPC_URL" \
            -gateway-secret-file "$GATEWAY_SECRET_FILE" \
            -proposer-key-file "$SEALER_KEY_FILE" \
            -session-agent-file "$SESSION_FILE" \
            >> "$GATEWAY_LOG" 2>&1 < /dev/null &
    printf '%s\n' "$!" > "$GATEWAY_PID"
    disown "$!" 2>/dev/null || true

    log "启动 Node Agent 127.0.0.1:${AGENT_PORT}"
    nohup "$agent" -cmd serve \
        -listen "127.0.0.1:${AGENT_PORT}" \
        -rpc "$RPC_URL" \
        -provider "$PROVIDER" \
        -gateway-secret-file "$NODE_SECRET_FILE" \
        -worker-key-file "$SEALER_KEY_FILE" \
        -passphrase-file "$PASS_FILE" \
        >> "$AGENT_LOG" 2>&1 < /dev/null &
    printf '%s\n' "$!" > "$AGENT_PID"
    disown "$!" 2>/dev/null || true
}

wait_healthy() {
    local ok port code i
    command -v curl >/dev/null 2>&1 || {
        log "需要 curl 来检查 /healthz"
        return 1
    }
    for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30; do
        ok=1
        for port in "$GATEWAY_PORT" "$AGENT_PORT"; do
            code=$(curl -sS -m 2 -o /dev/null -w '%{http_code}' "http://127.0.0.1:${port}/healthz" || true)
            if [[ "$code" != 200 ]]; then
                ok=0
            fi
        done
        if [[ "$ok" == 1 ]]; then
            return 0
        fi
        sleep 1
    done
    log "Gateway 或 Node Agent 的 /healthz 没有返回 200"
    log "Gateway 日志: ${GATEWAY_LOG}"
    log "Node Agent 日志: ${AGENT_LOG}"
    if [[ -f "$GATEWAY_LOG" ]]; then
        tail -n 20 "$GATEWAY_LOG" >&2 || true
    fi
    if [[ -f "$AGENT_LOG" ]]; then
        tail -n 20 "$AGENT_LOG" >&2 || true
    fi
    return 1
}

nginx_site_path() {
    if [[ -d /etc/nginx/sites-available ]]; then
        printf '%s\n' /etc/nginx/sites-available/pantanal-ai
    elif [[ -d /etc/nginx/conf.d ]]; then
        printf '%s\n' /etc/nginx/conf.d/pantanal-ai.conf
    else
        return 1
    fi
}

nginx_bin() {
    if command -v nginx >/dev/null 2>&1; then
        command -v nginx
        return 0
    fi
    if [[ -x /usr/sbin/nginx ]]; then
        printf '%s\n' /usr/sbin/nginx
        return 0
    fi
    return 1
}

ensure_nginx() {
    if nginx_bin >/dev/null; then
        return 0
    fi
    log "安装 nginx"
    case "$OS_ID" in
        ubuntu|debian)
            as_root env DEBIAN_FRONTEND=noninteractive apt-get update -y
            as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y nginx
            ;;
        fedora)
            as_root dnf install -y nginx
            ;;
        rhel)
            if command -v dnf >/dev/null 2>&1; then
                as_root dnf install -y nginx
            else
                as_root yum install -y nginx
            fi
            ;;
        opensuse)
            as_root zypper --non-interactive install nginx
            ;;
        arch)
            as_root pacman -S --noconfirm nginx
            ;;
        *)
            log "需要 nginx 才能把 80 端口的 /v1/ 转到 Gateway"
            return 1
            ;;
    esac
    nginx_bin >/dev/null
}

tls_for_host() {
    TLS_CERT=""
    TLS_KEY=""
    [[ -n "$PUBLIC_HOST" ]] || return 1
    if [[ -n "${PANTANAL_TLS_CERT:-}" && -n "${PANTANAL_TLS_KEY:-}" ]] && as_root test -r "$PANTANAL_TLS_CERT" && as_root test -r "$PANTANAL_TLS_KEY"; then
        TLS_CERT=$PANTANAL_TLS_CERT
        TLS_KEY=$PANTANAL_TLS_KEY
        return 0
    fi
    local live="/etc/letsencrypt/live/${PUBLIC_HOST}"
    if as_root test -r "${live}/fullchain.pem" && as_root test -r "${live}/privkey.pem"; then
        TLS_CERT="${live}/fullchain.pem"
        TLS_KEY="${live}/privkey.pem"
        return 0
    fi
    return 1
}

write_nginx_site() {
    local dest="$1" tmp names
    tmp=$(mktemp)
    if [[ -n "${TLS_CERT}" ]]; then
        names=$PUBLIC_IP
    elif [[ -n "$PUBLIC_HOST" ]]; then
        names="${PUBLIC_IP} ${PUBLIC_HOST}"
    else
        names=$PUBLIC_IP
    fi
    cat > "$tmp" <<EOF
# Public front for the Pantanal gateway. TCP 8787 stays on 127.0.0.1.
server {
    listen 80;
    listen [::]:80;
    server_name ${names};

    location /v1/ {
        proxy_pass http://127.0.0.1:${GATEWAY_PORT};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        client_max_body_size 20m;
    }

    location = /healthz {
        proxy_pass http://127.0.0.1:${GATEWAY_PORT}/healthz;
    }
}
EOF
    if [[ -n "${TLS_CERT}" ]]; then
        as_root mkdir -p /var/www/certbot
        cat >> "$tmp" <<EOF

server {
    listen 80;
    listen [::]:80;
    server_name ${PUBLIC_HOST};

    location ^~ /.well-known/acme-challenge/ {
        root /var/www/certbot;
        default_type text/plain;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    server_name ${PUBLIC_HOST};

    ssl_certificate     ${TLS_CERT};
    ssl_certificate_key ${TLS_KEY};
    ssl_protocols       TLSv1.2 TLSv1.3;

    client_max_body_size 20m;

    location /v1/ {
        proxy_pass http://127.0.0.1:${GATEWAY_PORT};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }

    location = /healthz {
        proxy_pass http://127.0.0.1:${GATEWAY_PORT}/healthz;
        proxy_set_header Host \$host;
    }
}
EOF
    fi
    as_root cp "$tmp" "$dest"
    as_root chmod 644 "$dest"
    rm -f "$tmp"
    if [[ -d /etc/nginx/sites-enabled && "$dest" == /etc/nginx/sites-available/pantanal-ai ]]; then
        as_root ln -sfn "$dest" /etc/nginx/sites-enabled/pantanal-ai
    fi
}

allow_public_web() {
    local https="${1:-}"
    if command -v ufw >/dev/null 2>&1 && as_root ufw status 2>/dev/null | grep -q 'Status: active'; then
        as_root ufw allow 80/tcp comment 'Pantanal AI' >/dev/null
        if [[ "$https" == https ]]; then
            as_root ufw allow 443/tcp comment 'Pantanal AI' >/dev/null
        fi
        log "防火墙已放行 80/tcp"
        [[ "$https" == https ]] && log "防火墙已放行 443/tcp"
        return 0
    fi
    if command -v firewall-cmd >/dev/null 2>&1 && as_root firewall-cmd --state >/dev/null 2>&1; then
        as_root firewall-cmd --permanent --add-service=http >/dev/null
        if [[ "$https" == https ]]; then
            as_root firewall-cmd --permanent --add-service=https >/dev/null
        fi
        as_root firewall-cmd --reload >/dev/null
        log "防火墙已放行 HTTP"
        [[ "$https" == https ]] && log "防火墙已放行 HTTPS"
        return 0
    fi
    log "本机防火墙未拦截入站时，80 端口由 nginx 提供 /v1/ 与 /healthz"
}

publish_public() {
    local dest had_tls=""
    if [[ "$OS_FAMILY" != linux ]]; then
        log "公网入口需要 Linux 上的 nginx，把 80 端口的 /v1/ 与 /healthz 转到 127.0.0.1:${GATEWAY_PORT}"
        return 1
    fi
    apply_public_env
    if [[ -z "$PUBLIC_IP" ]]; then
        PUBLIC_IP=$(detect_public_ip || true)
    fi
    PUBLIC_IP=$(printf '%s' "$PUBLIC_IP" | tr -d '[:space:]')
    PUBLIC_HOST=$(normalize_host "$PUBLIC_HOST")
    valid_public_ip "$PUBLIC_IP" || {
        log "没有可用的公网 IPv4。设置 PANTANAL_PUBLIC_IP 后重新启动。"
        return 1
    }
    if [[ -n "$PUBLIC_HOST" ]] && ! valid_host "$PUBLIC_HOST"; then
        log "域名无效: ${PUBLIC_HOST}"
        return 1
    fi
    ensure_nginx || return 1
    dest=$(nginx_site_path) || {
        log "未找到 nginx 配置目录"
        return 1
    }
    TLS_CERT=""
    TLS_KEY=""
    if tls_for_host; then
        had_tls=https
    elif [[ -n "$PUBLIC_HOST" ]]; then
        log "域名 ${PUBLIC_HOST} 还没有 TLS 证书，80 端口转发 /v1/ 与 /healthz"
    fi
    if [[ -f "$dest" ]]; then
        as_root cp "$dest" "${dest}.bak"
    fi
    write_nginx_site "$dest"
    if ! as_root nginx -t; then
        if [[ -f "${dest}.bak" ]]; then
            as_root cp "${dest}.bak" "$dest"
        else
            as_root rm -f "$dest" /etc/nginx/sites-enabled/pantanal-ai
        fi
        log "nginx 配置无效，未重新加载"
        return 1
    fi
    if command -v systemctl >/dev/null 2>&1; then
        as_root systemctl enable nginx >/dev/null 2>&1 || true
        as_root systemctl reload nginx || as_root systemctl restart nginx
    else
        as_root nginx -s reload
    fi
    allow_public_web "$had_tls"
    save_ai_conf
    log "公网入口: http://${PUBLIC_IP}/v1/"
    log "健康检查: http://${PUBLIC_IP}/healthz"
    if [[ -n "$PUBLIC_HOST" && -n "$had_tls" ]]; then
        log "域名入口: https://${PUBLIC_HOST}/v1/"
        log "域名健康检查: https://${PUBLIC_HOST}/healthz"
    elif [[ -n "$PUBLIC_HOST" ]]; then
        log "域名入口: http://${PUBLIC_HOST}/v1/"
        log "域名健康检查: http://${PUBLIC_HOST}/healthz"
    fi
}

launch_ai() {
    write_node_secret || return 1
    log "节点地址: ${NODE_ADDRESS}"
    store_profile
    if [[ "$AI_UPDATED" != 1 ]] && ! config_changed && ai_running; then
        log "AI 服务已在运行 (Gateway PID $(running_pid "$GATEWAY_PID"), Node Agent PID $(running_pid "$AGENT_PID"))"
        publish_public
        return
    fi
    if ai_running || running_pid "$GATEWAY_PID" >/dev/null || running_pid "$AGENT_PID" >/dev/null; then
        stop_ai
    fi
    start_processes
    wait_healthy || return 1
    runtime_stamp > "$RUN_STAMP"
    log "AI 服务已启动"
    log "Gateway: http://127.0.0.1:${GATEWAY_PORT}"
    log "Node Agent: http://127.0.0.1:${AGENT_PORT}"
    log "RPC: ${RPC_URL}"
    log "日志: ${GATEWAY_LOG} ${AGENT_LOG}"
    publish_public
}

install_ai() {
    local interactive="${1:-}"
    configure_ai "$interactive" || return 1
    sync_ai
    launch_ai
}

start_command() {
    load_ai_conf
    fill_empty_defaults
    secret_ok "$UPSTREAM_FILE" 8 || {
        log "还没有上游 Key。先执行安装。"
        return 1
    }
    secret_ok "$PASS_FILE" 8 || {
        log "还没有 keystore 口令。先执行安装。"
        return 1
    }
    secret_ok "$GATEWAY_SECRET_FILE" 16 || {
        log "还没有 Gateway 主密钥。先执行安装。"
        return 1
    }
    ensure_sealer || return 1
    clear_secret_env
    sync_ai
    launch_ai
}

health_code() {
    local port="$1"
    curl -sS -m 2 -o /dev/null -w '%{http_code}' "http://127.0.0.1:${port}/healthz" 2>/dev/null || true
}

show_status() {
    local pid code
    load_ai_conf
    log "=== Pantanal AI ==="
    log "系统: ${OS_ID} ${ARCH}"
    if pid=$(running_pid "$GATEWAY_PID"); then
        log "Gateway 运行中 (PID ${pid})"
    else
        log "Gateway 未运行"
    fi
    if pid=$(running_pid "$AGENT_PID"); then
        log "Node Agent 运行中 (PID ${pid})"
    else
        log "Node Agent 未运行"
    fi
    if command -v curl >/dev/null 2>&1; then
        code=$(health_code "$GATEWAY_PORT")
        log "Gateway /healthz: ${code:-无响应}"
        code=$(health_code "$AGENT_PORT")
        log "Node Agent /healthz: ${code:-无响应}"
    fi
    log "上游提供商: ${PROVIDER:-未配置}"
    log "模型: ${MODELS:-未配置}"
    log "档位: ${TIER:-未配置}"
    if secret_ok "$GATEWAY_SECRET_FILE" 16; then
        log "Gateway 主密钥: 已配置"
    else
        log "Gateway 主密钥: 不可用"
    fi
    if secret_ok "$UPSTREAM_FILE" 8; then
        log "上游 Key: 已配置"
    else
        log "上游 Key: 不可用"
    fi
    if sealer_key_ok && ai_installed; then
        if NODE_ADDRESS=$(worker_address 2>/dev/null); then
            log "节点地址: ${NODE_ADDRESS}"
        fi
    elif sealer_key_ok; then
        log "密封密钥: 已配置"
    else
        log "密封密钥: 不可用"
    fi
    if [[ -n "$PUBLIC_IP" ]]; then
        log "公网入口: http://${PUBLIC_IP}/v1/"
    else
        log "公网入口: 未配置"
    fi
    if [[ -n "$PUBLIC_HOST" ]]; then
        log "域名: ${PUBLIC_HOST}"
    fi
    log "数据目录: ${DATADIR}"
    log "Gateway 日志: ${GATEWAY_LOG}"
    log "Node Agent 日志: ${AGENT_LOG}"
}

monitor() {
    load_ai_conf
    fill_empty_defaults
    secret_ok "$UPSTREAM_FILE" 8 || {
        log "还没有上游 Key，巡检不启动 AI 服务"
        return 1
    }
    secret_ok "$PASS_FILE" 8 || {
        log "还没有 keystore 口令，巡检不启动 AI 服务"
        return 1
    }
    secret_ok "$GATEWAY_SECRET_FILE" 16 || {
        log "还没有 Gateway 主密钥，巡检不启动 AI 服务"
        return 1
    }
    ensure_sealer || return 1
    clear_secret_env
    sync_ai
    if [[ "$AI_UPDATED" == 1 ]]; then
        log "已覆盖新版本，正在重启"
        stop_ai
    fi
    launch_ai
}

guide_start() {
    load_ai_conf
    fill_empty_defaults
    if [[ ! -f "$AI_CONF" ]]; then
        install_ai interactive
        return
    fi
    local choice
    choice=$(prompt_choice "启动方式" \
        "使用上次的设置（${PROVIDER} / ${MODELS}）" \
        "重新选择提供商并更新密钥")
    if [[ "$choice" == 2 ]]; then
        install_ai interactive
        return
    fi
    start_command
}

interactive_menu() {
    local choice
    while true; do
        choice=$(prompt_choice "Pantanal AI 服务" \
            "安装或更新并启动" \
            "启动已安装的 AI 服务" \
            "停止" \
            "查看状态" \
            "退出")
        case "$choice" in
            1) install_ai interactive || true ;;
            2) guide_start || true ;;
            3) stop_ai || true ;;
            4) show_status || true ;;
            5) return 0 ;;
        esac
        printf '\n' >/dev/tty
    done
}

show_help() {
    cat <<EOF
Pantanal AI 服务

在节点数据目录上安装 Gateway 与 Node Agent，并启动。
发现更新的 Release 时覆盖程序并重启。8787 与 8788 只监听本机。
公网 IP 的 80 端口转发 /v1/ 与 /healthz。域名有 TLS 证书时，443 做同样的转发。

用法: $(basename "$0") <command>

  install             安装并启动。终端中运行且不带其他参数时进入选择菜单
  start               沿用已保存的提供商、模型和密钥启动
  stop                停止 Gateway、Node Agent 和结算伴随进程
  status              查看进程、/healthz 和密钥文件是否可用
  monitor             巡检。有新版本时覆盖并重启，退出后按已保存的配置拉起
  help                显示此说明

当前系统 ${OS_ID} (${ARCH})。数据目录 ${DATADIR}，程序目录 ${BIN_DIR}。
Gateway: 127.0.0.1:${GATEWAY_PORT}
Node Agent: 127.0.0.1:${AGENT_PORT}
RPC: ${RPC_URL}
发布包: ${RELEASE_BASE}/pantanal-ai-<os>-<arch>.tar.gz 或 .zip

密封密钥使用 ${SEALER_KEY_FILE}。安装脚本不生成该私钥。
没有可用密封密钥时不启动。该文件同时作为 Worker 私钥和结算提议者私钥。

上游 Key 写入 ${UPSTREAM_FILE}。
keystore 口令写入 ${PASS_FILE}。
Gateway 主密钥写入 ${GATEWAY_SECRET_FILE}。节点进程使用由主密钥和密封密钥地址派生的 nodeSecret。
会话代理私钥由 Gateway 写入 ${SESSION_FILE}。
这些文件权限均为仅所有者可读。内容不进入命令行，也不写入日志。
已有合法文件时直接使用，环境变量不会覆盖它。

非交互安装可事先设置：
  PANTANAL_UPSTREAM_KEY     上游 Key，至少 8 个字符
  PANTANAL_KEYSTORE_PASS    keystore 口令，至少 8 个字符
  PANTANAL_GATEWAY_SECRET   已有主密钥，至少 16 个字符。未设置且文件不存在时生成本机主密钥
  PANTANAL_AI_PROVIDER      上游提供商，默认 openai
  PANTANAL_AI_MODELS        逗号分隔的模型。OpenAI 默认 gpt-4o-mini，DeepSeek 默认 deepseek-chat
  PANTANAL_AI_TIER          档位，默认 default
  PANTANAL_AI_PROFILE       profile 编号。留空时按提供商或档位生成
  PANTANAL_AI_LABEL         显示名称
  PANTANAL_PUBLIC_IP        公网 IPv4。未设置时向公网查询本机地址
  PANTANAL_PUBLIC_HOST      域名。留空时只发布公网 IP 的 80 端口
  PANTANAL_TLS_CERT         域名证书。未设置时使用 /etc/letsencrypt/live/<域名>/
  PANTANAL_TLS_KEY          域名私钥
EOF
}

main() {
    local command="${1:-}"
    case "$command" in
        "")
            if have_tty; then
                interactive_menu
            else
                install_ai
            fi
            ;;
        install)
            if [[ -z "${2:-}" ]] && have_tty; then
                interactive_menu
            else
                install_ai
            fi
            ;;
        start)
            start_command
            ;;
        stop)
            stop_ai
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
