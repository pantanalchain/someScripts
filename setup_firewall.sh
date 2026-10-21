#!/bin/bash
# 配合 pantanal.sh 的节点防火墙。
#
# 参数是系统类型：ubuntu、debian、fedora、rhel、opensuse、arch、linux、macos、windows。
# 不带参数时按本机识别。
# 入口为 SSH 与 geth P2P 30303。出口放行。
# 8545 与 8790 不对外开放。执行后立即启用防火墙。
#
# 用法: ADMIN_IP=203.0.113.8 ./setup_firewall.sh ubuntu

set -euo pipefail

ADMIN_IP="${ADMIN_IP:-0.0.0.0/0}"
P2P_PORT=30303
OS_ID="${1:-}"

as_root() {
    local uname_s
    uname_s=$(uname -s)
    case "$uname_s" in
        MINGW*|MSYS*|CYGWIN*)
            "$@"
            return
            ;;
    esac
    if [[ "$(id -u)" -eq 0 ]]; then
        "$@"
    elif command -v sudo >/dev/null 2>&1; then
        sudo "$@"
    else
        "$@"
    fi
}

usage() {
    cat <<'EOF'
用法: ADMIN_IP=203.0.113.8 ./setup_firewall.sh <ubuntu|debian|fedora|rhel|opensuse|arch|linux|macos|windows>

不带参数时按本机 /etc/os-release、macOS 或 Windows 识别。

  ubuntu、debian     ufw
  fedora、rhel、opensuse
                     firewalld。rhel 含 CentOS、Rocky、AlmaLinux
  arch、linux        使用本机已有的 firewalld 或 ufw
  macos              应用程序防火墙，允许 geth，并打开远程登录
  windows            Windows 防火墙

入口: 22/tcp，30303/tcp，30303/udp
出口: 放行
未设置 ADMIN_IP 时，22/tcp 对所有地址开放。macOS 远程登录不按地址过滤。
EOF
}

detect_os() {
    local uname_s id like
    uname_s=$(uname -s)
    case "$uname_s" in
        Darwin)
            OS_ID=macos
            return 0
            ;;
        MINGW*|MSYS*|CYGWIN*)
            OS_ID=windows
            return 0
            ;;
        Linux) ;;
        *)
            echo "不支持的系统: $uname_s" >&2
            return 1
            ;;
    esac
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
}

allow_note() {
    echo "=== Pantanal 节点防火墙 (${OS_ID}) ==="
    echo "入口: 22/tcp, ${P2P_PORT}/tcp, ${P2P_PORT}/udp"
    echo "出口: 放行"
    if [[ "$ADMIN_IP" == "0.0.0.0/0" ]]; then
        echo "警告: 未设置 ADMIN_IP，22/tcp 对所有地址开放"
    else
        echo "SSH 仅 $ADMIN_IP"
    fi
}

apply_ufw() {
    if ! command -v ufw >/dev/null 2>&1; then
        if ! command -v apt-get >/dev/null 2>&1; then
            echo "未安装 ufw" >&2
            return 1
        fi
        echo "安装 ufw"
        as_root env DEBIAN_FRONTEND=noninteractive apt-get update -y
        as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y ufw
    fi
    allow_note
    as_root ufw --force reset
    as_root ufw default deny incoming
    as_root ufw default allow outgoing
    if [[ "$ADMIN_IP" == "0.0.0.0/0" ]]; then
        as_root ufw allow 22/tcp comment 'SSH'
    else
        as_root ufw allow from "$ADMIN_IP" to any port 22 proto tcp comment 'SSH'
    fi
    as_root ufw allow "${P2P_PORT}/tcp" comment 'Geth P2P'
    as_root ufw allow "${P2P_PORT}/udp" comment 'Geth discovery'
    as_root ufw --force enable
    echo
    as_root ufw status numbered
}

fw_add() {
    local status
    as_root firewall-cmd --permanent "$@" && status=0 || status=$?
    [[ "$status" -eq 0 || "$status" -eq 11 ]]
}

apply_firewalld() {
    if ! command -v firewall-cmd >/dev/null 2>&1; then
        echo "安装 firewalld"
        if command -v dnf >/dev/null 2>&1; then
            as_root dnf install -y firewalld
        elif command -v yum >/dev/null 2>&1; then
            as_root yum install -y firewalld
        elif command -v zypper >/dev/null 2>&1; then
            as_root zypper --non-interactive install firewalld
        else
            echo "未安装 firewalld" >&2
            return 1
        fi
    fi
    allow_note
    as_root systemctl enable --now firewalld
    fw_add --add-port="${P2P_PORT}/tcp"
    fw_add --add-port="${P2P_PORT}/udp"
    if [[ "$ADMIN_IP" == "0.0.0.0/0" ]]; then
        fw_add --add-service=ssh
    else
        as_root firewall-cmd --permanent --remove-service=ssh >/dev/null 2>&1 || true
        local family=ipv4
        [[ "$ADMIN_IP" == *:* ]] && family=ipv6
        fw_add --add-rich-rule="rule family=${family} source address=${ADMIN_IP} port port=22 protocol=tcp accept"
    fi
    as_root firewall-cmd --reload
    echo
    as_root firewall-cmd --list-ports
    as_root firewall-cmd --list-services
}

apply_auto() {
    if systemctl is-active --quiet firewalld 2>/dev/null; then
        apply_firewalld
    elif command -v ufw >/dev/null 2>&1 && as_root ufw status 2>/dev/null | grep -q 'Status: active'; then
        apply_ufw
    elif command -v firewall-cmd >/dev/null 2>&1; then
        apply_firewalld
    elif command -v ufw >/dev/null 2>&1 || command -v apt-get >/dev/null 2>&1; then
        apply_ufw
    else
        echo "未找到 firewalld 或 ufw" >&2
        return 1
    fi
}

apply_macos() {
    local fw geth
    fw=/usr/libexec/ApplicationFirewall/socketfilterfw
    geth="${PANTANAL_GETH:-}"
    if [[ -z "$geth" ]]; then
        for geth in /opt/homebrew/bin/geth /usr/local/bin/geth "${HOME}/pantanal/bin/geth"; do
            if [[ -x "$geth" ]]; then
                break
            fi
            geth=""
        done
    fi
    echo "=== Pantanal 节点防火墙 (macos) ==="
    echo "入口: 远程登录，geth P2P ${P2P_PORT}"
    echo "出口: 放行"
    as_root "$fw" --setglobalstate on
    as_root "$fw" --setblockall off
    if [[ -n "$geth" && -e "$geth" ]]; then
        as_root "$fw" --add "$geth" || true
        as_root "$fw" --unblockapp "$geth"
        echo "已允许 $geth 接受入站连接"
    else
        echo "未找到 geth，应用程序防火墙未放行节点程序" >&2
        return 1
    fi
    if as_root /usr/sbin/systemsetup -setremotelogin on; then
        echo "远程登录已打开"
    else
        echo "远程登录未打开" >&2
        return 1
    fi
}

apply_windows() {
    local ps_bin ps1
    if command -v powershell.exe >/dev/null 2>&1; then
        ps_bin=powershell.exe
    elif command -v pwsh.exe >/dev/null 2>&1; then
        ps_bin=pwsh.exe
    elif command -v powershell >/dev/null 2>&1; then
        ps_bin=powershell
    else
        echo "未找到 PowerShell" >&2
        return 1
    fi
    allow_note
    ps1=$(mktemp)
    mv "$ps1" "${ps1}.ps1"
    ps1="${ps1}.ps1"
    cat > "$ps1" <<EOF
\$ErrorActionPreference = 'Stop'
Set-NetFirewallProfile -Profile Domain,Public,Private -Enabled True
\$names = @('Pantanal SSH','Pantanal P2P','Pantanal discovery')
\$existing = Get-NetFirewallRule -ErrorAction SilentlyContinue | Where-Object { \$names -contains \$_.DisplayName }
if (\$existing) { \$existing | Remove-NetFirewallRule }
\$ssh = @{
  DisplayName = 'Pantanal SSH'
  Direction = 'Inbound'
  Action = 'Allow'
  Protocol = 'TCP'
  LocalPort = 22
}
if ('${ADMIN_IP}' -ne '0.0.0.0/0') { \$ssh.RemoteAddress = '${ADMIN_IP}' }
New-NetFirewallRule @ssh | Out-Null
New-NetFirewallRule -DisplayName 'Pantanal P2P' -Direction Inbound -Action Allow -Protocol TCP -LocalPort ${P2P_PORT} | Out-Null
New-NetFirewallRule -DisplayName 'Pantanal discovery' -Direction Inbound -Action Allow -Protocol UDP -LocalPort ${P2P_PORT} | Out-Null
Get-NetFirewallRule -ErrorAction SilentlyContinue | Where-Object { \$names -contains \$_.DisplayName } | Format-Table DisplayName,Enabled,Direction,Action -AutoSize
EOF
    if ! "$ps_bin" -NoProfile -ExecutionPolicy Bypass -File "$ps1"; then
        rm -f "$ps1"
        echo "Windows 防火墙需要管理员权限" >&2
        return 1
    fi
    rm -f "$ps1"
}

if [[ "$OS_ID" == "-h" || "$OS_ID" == "--help" || "$OS_ID" == "help" ]]; then
    usage
    exit 0
fi

if [[ -z "$OS_ID" ]]; then
    detect_os
fi

case "$OS_ID" in
    ubuntu|debian) apply_ufw ;;
    fedora|rhel|opensuse) apply_firewalld ;;
    arch|linux) apply_auto ;;
    macos) apply_macos ;;
    windows) apply_windows ;;
    *)
        echo "未知系统: $OS_ID" >&2
        usage >&2
        exit 1
        ;;
esac
