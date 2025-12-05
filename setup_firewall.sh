#!/bin/bash

# Pantanal 节点防火墙配置脚本
# 使用前请根据实际情况修改 ADMIN_IP

echo "=== Pantanal 节点防火墙配置 ==="

# 设置管理员 IP（修改为你的实际 IP）
ADMIN_IP="0.0.0.0/0"  # 改为你的 IP，例如：123.45.67.89

# 重置 UFW（可选，小心使用）
# sudo ufw --force reset

# 设置默认策略
sudo ufw default deny incoming
sudo ufw default allow outgoing

echo "1. 配置 SSH 访问..."
if [ "$ADMIN_IP" = "0.0.0.0/0" ]; then
    echo "⚠️  警告：SSH 将开放给所有 IP，建议修改脚本中的 ADMIN_IP 变量"
    sudo ufw allow 22/tcp
else
    echo "✓ SSH 限制为 $ADMIN_IP"
    sudo ufw allow from $ADMIN_IP to any port 22
fi

echo "2. 配置 HTTP/HTTPS（公网访问）..."
sudo ufw allow 80/tcp comment 'HTTP'
sudo ufw allow 443/tcp comment 'HTTPS'

echo "3. 配置 Geth P2P（公网访问）..."
sudo ufw allow 30303/tcp comment 'Geth P2P TCP'
sudo ufw allow 30303/udp comment 'Geth P2P UDP'

echo "4. 配置 RPC 端口（仅本地）..."
# 8545 不对外开放，只通过 Nginx 443 访问
echo "   8545 端口不对外开放（通过 Nginx 443 访问）"

echo ""
echo "=== 防火墙规则预览 ==="
sudo ufw show added

echo ""
read -p "是否启用防火墙？(y/n): " CONFIRM

if [ "$CONFIRM" = "y" ] || [ "$CONFIRM" = "Y" ]; then
    sudo ufw --force enable
    echo ""
    echo "✓ 防火墙已启用"
    echo ""
    sudo ufw status numbered
else
    echo "✗ 已取消，防火墙未启用"
fi

echo ""
echo "=== 配置完成 ==="
echo "如需修改规则："
echo "  查看规则：sudo ufw status numbered"
echo "  删除规则：sudo ufw delete <编号>"
echo "  添加规则：sudo ufw allow <端口>/tcp"
echo "  禁用防火墙：sudo ufw disable"

