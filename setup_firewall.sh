#!/bin/bash
# 配合 pantanal.sh 的节点防火墙。
#
# pantanal.sh 的对外端口只有 P2P 30303：
#   TCP 接受其他节点连入，UDP 为发现协议（v4 与 v5 共用这一端口）。
# 节点还会主动连出到其他节点的 30303，并通过 HTTPS 下载 geth。
# HTTP RPC 固定为 127.0.0.1:8545。
# 手机控制台固定为 127.0.0.1:8790，防火墙拒绝该端口的外网入站。
#
# 用法: ADMIN_IP=203.0.113.8 ./setup_firewall.sh

set -euo pipefail

ADMIN_IP="${ADMIN_IP:-0.0.0.0/0}"
P2P_PORT=30303
CONSOLE_PORT=8790
RPC_PORT=8545

as_root() {
    if [[ "$(id -u)" -eq 0 ]]; then
        "$@"
    else
        sudo "$@"
    fi
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" || "${1:-}" == "help" ]]; then
    cat <<'EOF'
用法: ADMIN_IP=203.0.113.8 ./setup_firewall.sh

入口: 22/tcp，30303/tcp，30303/udp
出口: 放行。节点要连其他节点的 30303，并访问 HTTPS 下载 geth。
8545 与 8790 只允许本机回环访问，外网入站被拒绝。

未设置 ADMIN_IP 时，22/tcp 对所有地址开放。
EOF
    exit 0
fi

if ! command -v ufw >/dev/null 2>&1; then
    echo "未安装 ufw" >&2
    exit 1
fi

echo "=== Pantanal 节点防火墙 ==="
echo "入口: 22/tcp, ${P2P_PORT}/tcp, ${P2P_PORT}/udp"
echo "拒绝外网: ${RPC_PORT}/tcp, ${CONSOLE_PORT}/tcp"
echo "出口: 放行"
if [[ "$ADMIN_IP" == "0.0.0.0/0" ]]; then
    echo "警告: 未设置 ADMIN_IP，22/tcp 对所有地址开放"
else
    echo "SSH 仅 $ADMIN_IP"
fi
echo
read -r -p "将清空现有 ufw 规则并启用，确认? (y/n): " CONFIRM

if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
    echo "已取消，未修改防火墙"
    exit 0
fi

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
as_root ufw deny "${RPC_PORT}/tcp" comment 'RPC localhost only'
as_root ufw deny "${CONSOLE_PORT}/tcp" comment 'Phone console localhost only'

as_root ufw --force enable
echo
as_root ufw status numbered
