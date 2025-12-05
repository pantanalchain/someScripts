#!/bin/bash

# Pantanal 验证节点日常启动脚本
# 适用于已经安装和配置好的环境

set -e

echo "=== Pantanal 验证节点启动脚本 ==="

# 1. 检查 geth 是否已安装
if ! command -v geth &> /dev/null; then
    if [ -f "/root/pantanal/build/bin/geth" ]; then
        export PATH=$PATH:/root/pantanal/build/bin
        echo "✓ 使用本地编译的 geth"
    else
        echo "✗ 错误: 未找到 geth，请先运行初始化脚本"
        exit 1
    fi
fi

# 2. 检查账户是否存在
if [ ! -d "$HOME/.ethereum/Pantanal/keystore" ] || [ -z "$(ls -A $HOME/.ethereum/Pantanal/keystore)" ]; then
    echo "✗ 错误: 未找到账户，请先导入账户"
    echo "运行: geth --Pantanal account import /path/to/private_key"
    exit 1
fi

# 3. 停止已运行的 geth 进程
if pgrep -f "geth.*Pantanal" > /dev/null; then
    echo "⚠ 检测到 geth 正在运行，正在停止..."
    pkill -f "geth.*Pantanal"
    sleep 3
fi

# 4. 启动 geth
echo "启动 Pantanal 节点..."
cd /root/pantanal

nohup ./build/bin/geth \
    --Pantanal \
    --port 30303 \
    --http \
    --http.addr 0.0.0.0 \
    --http.port 8545 \
    --http.api "eth,net,web3,admin,clique,miner,personal" \
    --http.corsdomain "*" \
    --maxpeers=100 \
    --syncmode full \
    --verbosity 3 \
    > /tmp/geth.log 2>&1 &

GETH_PID=$!
echo "✓ Geth 已启动 (PID: $GETH_PID)"

# 5. 等待 geth 启动
echo "等待 geth 初始化..."
sleep 5

# 6. 检查是否启动成功
if ! pgrep -f "geth.*Pantanal" > /dev/null; then
    echo "✗ geth 启动失败，查看日志: tail -f /tmp/geth.log"
    exit 1
fi

# 7. 解锁账户并启动挖矿
echo ""
echo "请输入账户密码以启动验证节点："
read -s PASSWORD

ACCOUNT=$(geth --Pantanal account list 2>/dev/null | grep "Account #0" | sed -n 's/.*{\(.*\)}.*/\1/p')

if [ -z "$ACCOUNT" ]; then
    echo "✗ 无法获取账户地址"
    exit 1
fi

echo "账户地址: 0x$ACCOUNT"
echo "正在解锁账户并启动挖矿..."

geth --Pantanal attach <<EOF
personal.unlockAccount("0x$ACCOUNT", "$PASSWORD", 0)
miner.start()
admin.nodeInfo.enode
exit
EOF

echo ""
echo "=== 验证节点已启动 ==="
echo "日志文件: /tmp/geth.log"
echo "查看日志: tail -f /tmp/geth.log"
echo "停止节点: pkill -f 'geth.*Pantanal'"
echo ""
echo "连接到控制台: geth --Pantanal attach"

