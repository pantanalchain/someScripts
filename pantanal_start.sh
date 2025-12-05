#!/bin/bash

# Pantanal 验证节点日常启动脚本
# 适用于已经安装和配置好的环境

set -e

echo "=== Pantanal 验证节点启动脚本 ==="

# 1. 重新编译 geth
echo "正在重新编译 geth..."
if [ ! -d "/root/pantanal" ]; then
    echo "✗ 错误: 未找到 /root/pantanal 目录"
    echo "请先克隆代码: git clone https://github.com/pantanalchain/pantanal.git /root/pantanal"
    exit 1
fi

cd /root/pantanal
make geth

if [ $? -ne 0 ]; then
    echo "✗ 编译失败"
    exit 1
fi

export PATH=$PATH:/root/pantanal/build/bin
echo "✓ geth 编译完成"

# 2. 检查账户是否存在
if [ ! -d "$HOME/.ethereum/Pantanal/keystore" ] || [ -z "$(ls -A $HOME/.ethereum/Pantanal/keystore)" ]; then
    echo ""
    echo "⚠ 未找到账户"
    echo "请选择："
    echo "  1) 导入已有私钥"
    echo "  2) 创建新账户"
    echo "  3) 退出"
    read -p "请输入选项 [1-3]: " CHOICE
    
    case $CHOICE in
        1)
            echo ""
            echo "=== 导入私钥 ==="
            echo "⚠ 注意：私钥输入不会显示在屏幕上"
            echo "请输入私钥（不带 0x 前缀）："
            read -s PRIVATE_KEY
            
            if [ -z "$PRIVATE_KEY" ]; then
                echo "✗ 私钥不能为空"
                exit 1
            fi
            
            # 写入临时文件
            echo "$PRIVATE_KEY" > /tmp/privkey_temp.txt
            
            echo ""
            echo "请设置账户密码："
            geth --Pantanal account import /tmp/privkey_temp.txt
            
            # 安全删除临时文件
            shred -u /tmp/privkey_temp.txt
            echo "✓ 账户导入成功"
            ;;
        2)
            echo ""
            echo "=== 创建新账户 ==="
            geth --Pantanal account new
            echo "✓ 账户创建成功"
            echo "⚠ 请妥善保管好私钥和密码！"
            ;;
        3)
            echo "退出"
            exit 0
            ;;
        *)
            echo "✗ 无效选项"
            exit 1
            ;;
    esac
    
    echo ""
    echo "账户已准备就绪，继续启动节点..."
    sleep 2
fi

# 3. 获取账户地址（在停止 geth 之前）
echo "获取账户地址..."
ACCOUNT=$(cd /root/pantanal && ./build/bin/geth --Pantanal account list 2>/dev/null | grep "Account #0" | sed -n 's/.*{\(.*\)}.*/\1/p')

if [ -z "$ACCOUNT" ]; then
    echo "⚠ 无法直接获取账户，尝试从 keystore 读取..."
    KEYSTORE_FILE=$(ls -t ~/.ethereum/Pantanal/keystore/ 2>/dev/null | head -1)
    if [ -n "$KEYSTORE_FILE" ]; then
        ACCOUNT=$(echo "$KEYSTORE_FILE" | sed -n 's/.*--\(.*\)$/\1/p')
        echo "✓ 从 keystore 获取到账户: 0x$ACCOUNT"
    fi
fi

if [ -z "$ACCOUNT" ]; then
    echo "✗ 无法获取账户地址"
    echo "请检查账户是否存在: ls ~/.ethereum/Pantanal/keystore/"
    exit 1
fi

echo "✓ 账户地址: 0x$ACCOUNT"

# 4. 停止已运行的 geth 进程
if pgrep -f "geth.*Pantanal" > /dev/null; then
    echo "⚠ 检测到 geth 正在运行，正在停止..."
    pkill -f "geth.*Pantanal"
    sleep 3
fi

# 5. 启动 geth
echo "启动 Pantanal 节点..."
cd /root/pantanal

nohup ./build/bin/geth \
    --Pantanal \
    --port 30303 \
    --http \
    --http.addr 0.0.0.0 \
    --http.port 8545 \
    --http.api "eth,net,web3,admin,clique,miner,personal,txpool,debug" \
    --http.corsdomain "*" \
    --http.vhosts "node1.pantanalchain.com,localhost,127.0.0.1" \
    --allow-insecure-unlock \
    --ws \
    --ws.addr 0.0.0.0 \
    --ws.port 8545 \
    --ws.api "eth,net,web3,admin,clique,miner,personal,txpool,debug" \
    --ws.origins "*" \
    --maxpeers=100 \
    --syncmode full \
    --gcmode archive \
    --verbosity 3 \
    > /tmp/geth.log 2>&1 &

GETH_PID=$!
echo "✓ Geth 已启动 (PID: $GETH_PID)"

# 6. 等待 geth 启动
echo "等待 geth 初始化..."
sleep 5

# 7. 检查是否启动成功
if ! pgrep -f "geth.*Pantanal" > /dev/null; then
    echo "✗ geth 启动失败，查看日志: tail -f /tmp/geth.log"
    exit 1
fi

# 8. 解锁账户并启动挖矿
echo ""
echo "请输入账户密码以启动验证节点（账户地址: 0x$ACCOUNT）："
read -s PASSWORD

if [ -z "$PASSWORD" ]; then
    echo "✗ 密码不能为空"
    exit 1
fi

echo ""
echo "正在解锁账户并启动挖矿..."

# 等待 geth RPC 接口完全就绪
sleep 3

# 通过 HTTP 连接解锁账户并启动挖矿
cd /root/pantanal && ./build/bin/geth attach http://127.0.0.1:8545 <<EOF
personal.unlockAccount("0x$ACCOUNT", "$PASSWORD", 0)
miner.start()
console.log("✓ 账户已解锁")
console.log("✓ 挖矿已启动")
console.log("当前区块:", eth.blockNumber)
exit
EOF

# 验证挖矿是否启动
sleep 2
MINING_STATUS=$(curl -s -X POST http://127.0.0.1:8545 \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"eth_mining","params":[],"id":1}' | grep -o '"result":[^,]*' | cut -d: -f2)

if [ "$MINING_STATUS" = "true" ]; then
    echo "✓ 挖矿已成功启动"
else
    echo "⚠ 挖矿可能未启动，请检查日志: tail -f /tmp/geth.log"
fi

echo ""
echo "=== 验证节点已启动 ==="
echo "HTTP JSON-RPC:     http://0.0.0.0:8545"
echo "WebSocket:         ws://0.0.0.0:8545 (共用 HTTP 端口)"
echo "公网访问(HTTPS):   https://node1.pantanalchain.com"
echo "公网访问(WSS):     wss://node1.pantanalchain.com"
echo "P2P Port:          30303"
echo ""
echo "日志文件: /tmp/geth.log"
echo "查看日志: tail -f /tmp/geth.log"
echo "停止节点: pkill -f 'geth.*Pantanal'"
echo ""
echo "连接到控制台: geth --Pantanal attach"

