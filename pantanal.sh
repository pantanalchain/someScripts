#!/bin/bash

# Pantanal 验证节点统一管理脚本
# 功能：启动、监控、解锁、状态查询等

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_NAME=$(basename "$0")

# 日志文件
GETH_LOG="/tmp/geth.log"
MONITOR_LOG="/tmp/geth_monitor.log"
UNLOCK_LOG="/tmp/geth_auto_unlock.log"
GETH_PID_FILE="/tmp/geth.pid"
PASSWORD_FILE="/root/.pantanal_password"

# 日志函数
log() {
    local log_file="$1"
    shift
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$log_file"
}

log_info() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

# 检查 geth 是否正在运行
check_geth_running() {
    if pgrep -f "geth.*Pantanal" > /dev/null; then
        return 0
    else
        return 1
    fi
}

# 获取账户地址
get_account() {
    local account=$(cd /root/pantanal && ./build/bin/geth --Pantanal account list 2>/dev/null | grep "Account #0" | sed -n 's/.*{\(.*\)}.*/\1/p')
    
    if [ -z "$account" ]; then
        local keystore_file=$(ls -t ~/.ethereum/Pantanal/keystore/ 2>/dev/null | head -1)
        if [ -n "$keystore_file" ]; then
            account=$(echo "$keystore_file" | sed -n 's/.*--\(.*\)$/\1/p')
        fi
    fi
    
    echo "$account"
}

# 获取密码（仅从密码文件）
get_password() {
    if [ -f "$PASSWORD_FILE" ]; then
        cat "$PASSWORD_FILE"
        return 0
    fi
    
    return 1
}

# 编译 geth
compile_geth() {
    log_info "正在重新编译 geth..."
    if [ ! -d "/root/pantanal" ]; then
        log_info "✗ 错误: 未找到 /root/pantanal 目录"
        log_info "请先克隆代码: git clone https://github.com/pantanalchain/pantanal.git /root/pantanal"
        return 1
    fi
    
    cd /root/pantanal
    if ! make geth; then
        log_info "✗ 编译失败"
        return 1
    fi
    
    export PATH=$PATH:/root/pantanal/build/bin
    log_info "✓ geth 编译完成"
    return 0
}

# 检查并创建账户
check_account() {
    if [ ! -d "$HOME/.ethereum/Pantanal/keystore" ] || [ -z "$(ls -A $HOME/.ethereum/Pantanal/keystore 2>/dev/null)" ]; then
        log_info ""
        log_info "⚠ 未找到账户"
        log_info "请选择："
        log_info "  1) 导入已有私钥"
        log_info "  2) 创建新账户"
        log_info "  3) 退出"
        read -p "请输入选项 [1-3]: " CHOICE
        
        case $CHOICE in
            1)
                log_info ""
                log_info "=== 导入私钥 ==="
                log_info "⚠ 注意：私钥输入不会显示在屏幕上"
                read -s -p "请输入私钥（不带 0x 前缀）：" PRIVATE_KEY
                echo ""
                
                if [ -z "$PRIVATE_KEY" ]; then
                    log_info "✗ 私钥不能为空"
                    return 1
                fi
                
                echo "$PRIVATE_KEY" > /tmp/privkey_temp.txt
                log_info ""
                log_info "请设置账户密码："
                geth --Pantanal account import /tmp/privkey_temp.txt
                shred -u /tmp/privkey_temp.txt
                log_info "✓ 账户导入成功"
                ;;
            2)
                log_info ""
                log_info "=== 创建新账户 ==="
                geth --Pantanal account new
                log_info "✓ 账户创建成功"
                log_info "⚠ 请妥善保管好私钥和密码！"
                ;;
            3)
                log_info "退出"
                exit 0
                ;;
            *)
                log_info "✗ 无效选项"
                return 1
                ;;
        esac
        
        log_info ""
        log_info "账户已准备就绪，继续启动节点..."
        sleep 2
    fi
    return 0
}

# 启动 geth（仅启动，不处理解锁和挖矿）
start_geth_only() {
    log_info "启动 Pantanal 节点..."
    
    # 检查 geth 二进制文件
    if [ ! -f "/root/pantanal/build/bin/geth" ]; then
        log_info "错误: 未找到 geth 二进制文件，正在编译..."
        if ! compile_geth; then
            return 1
        fi
    fi
    
    # 检查账户
    if [ ! -d "$HOME/.ethereum/Pantanal/keystore" ] || [ -z "$(ls -A $HOME/.ethereum/Pantanal/keystore 2>/dev/null)" ]; then
        log_info "错误: 未找到账户"
        return 1
    fi
    
    cd /root/pantanal
    
    # 获取账户地址用于自动解锁
    local account=$(get_account)
    local unlock_param=""
    if [ -n "$account" ] && [ -f "$PASSWORD_FILE" ]; then
        # 使用密码文件路径，geth 会自动读取
        unlock_param="--unlock 0x$account --password $PASSWORD_FILE"
    fi
    
    # 使用 setsid 确保 geth 完全独立运行
    setsid ./build/bin/geth \
        --Pantanal \
        --port 30303 \
        --http \
        --http.addr 0.0.0.0 \
        --http.port 8545 \
        --http.api "eth,net,web3,admin,clique,miner,personal,txpool,debug,trace" \
        --http.corsdomain "*" \
        --http.vhosts "*" \
        --allow-insecure-unlock \
        $unlock_param \
        --ws \
        --ws.addr 0.0.0.0 \
        --ws.port 8545 \
        --ws.api "eth,net,web3,admin,clique,miner,personal,txpool,debug,trace" \
        --ws.origins "*" \
        --maxpeers=100 \
        --syncmode full \
        --gcmode archive \
        --verbosity 3 \
        > "$GETH_LOG" 2>&1 < /dev/null &
    
    local geth_pid=$!
    disown $geth_pid 2>/dev/null || true
    echo $geth_pid > "$GETH_PID_FILE"
    
    # 等待启动
    sleep 5
    
    if check_geth_running; then
        log_info "✓ Geth 已启动 (PID: $geth_pid)"
        return 0
    else
        log_info "✗ geth 启动失败，查看日志: tail -f $GETH_LOG"
        return 1
    fi
}

# 解锁账户并启动挖矿
unlock_and_mine() {
    if ! check_geth_running; then
        log "$UNLOCK_LOG" "错误: geth 未运行，无法解锁"
        return 1
    fi
    
    local account=$(get_account)
    if [ -z "$account" ]; then
        log "$UNLOCK_LOG" "错误: 无法获取账户地址"
        return 1
    fi
    
    local password=$(get_password)
    if [ -z "$password" ]; then
        log "$UNLOCK_LOG" "错误: 未找到密码文件"
        log "$UNLOCK_LOG" "请设置密码文件: echo 'your_password' > $PASSWORD_FILE && chmod 600 $PASSWORD_FILE"
        return 1
    fi
    
    log "$UNLOCK_LOG" "正在解锁账户 0x$account 并启动挖矿..."
    
    # 等待 RPC 接口就绪
    sleep 3
    
    # 检查是否已经解锁
    local unlocked=$(curl -s -X POST http://127.0.0.1:8545 \
        -H "Content-Type: application/json" \
        -d "{\"jsonrpc\":\"2.0\",\"method\":\"eth_accounts\",\"params\":[],\"id\":1}" | grep -o "\"0x$account\"" || echo "")
    
    local unlock_success=0
    if [ -z "$unlocked" ]; then
        # 解锁账户
        local unlock_result=$(cd /root/pantanal && ./build/bin/geth attach http://127.0.0.1:8545 <<EOF 2>&1
personal.unlockAccount("0x$account", "$password", 0)
exit
EOF
)
        
        if echo "$unlock_result" | grep -q "true"; then
            log "$UNLOCK_LOG" "✓ 账户解锁成功"
            unlock_success=1
        else
            log "$UNLOCK_LOG" "✗ 账户解锁失败: $unlock_result"
            return 1
        fi
    else
        log "$UNLOCK_LOG" "账户已解锁，检查挖矿状态..."
        unlock_success=1
    fi
    
    # 检查挖矿状态
    local mining_status=$(curl -s -X POST http://127.0.0.1:8545 \
        -H "Content-Type: application/json" \
        -d '{"jsonrpc":"2.0","method":"eth_mining","params":[],"id":1}' 2>/dev/null | grep -o '"result":[^,}]*' | cut -d: -f2 | tr -d ' ')
    
    if [ "$mining_status" = "true" ]; then
        log "$UNLOCK_LOG" "✓ 挖矿已在运行"
        return 0
    fi
    
    # 启动挖矿
    log "$UNLOCK_LOG" "正在启动挖矿..."
    cd /root/pantanal && ./build/bin/geth attach http://127.0.0.1:8545 <<EOF 2>&1
miner.start()
exit
EOF
    
    # 等待挖矿启动
    sleep 3
    
    # 验证挖矿是否启动（多次检查，确保准确性）
    local check_count=0
    local max_checks=5
    while [ $check_count -lt $max_checks ]; do
        mining_status=$(curl -s -X POST http://127.0.0.1:8545 \
            -H "Content-Type: application/json" \
            -d '{"jsonrpc":"2.0","method":"eth_mining","params":[],"id":1}' 2>/dev/null | grep -o '"result":[^,}]*' | cut -d: -f2 | tr -d ' ')
        
        if [ "$mining_status" = "true" ]; then
            log "$UNLOCK_LOG" "✓ 挖矿启动成功"
            return 0
        fi
        
        check_count=$((check_count + 1))
        if [ $check_count -lt $max_checks ]; then
            sleep 1
        fi
    done
    
    # 如果多次检查都失败，尝试通过 geth attach 直接检查
    local direct_check=$(cd /root/pantanal && ./build/bin/geth attach http://127.0.0.1:8545 <<EOF 2>&1 | grep -i "true\|false" | head -1
eth.mining
exit
EOF
)
    
    if echo "$direct_check" | grep -qi "true"; then
        log "$UNLOCK_LOG" "✓ 挖矿启动成功（通过直接检查确认）"
        return 0
    else
        log "$UNLOCK_LOG" "⚠ 挖矿可能未启动"
        # 如果解锁成功，返回2表示解锁成功但挖矿失败
        if [ "$unlock_success" = "1" ]; then
            return 2
        else
            return 1
        fi
    fi
}

# 完整启动流程（编译、检查账户、启动、解锁挖矿）
start_full() {
    log_info "=== Pantanal 验证节点启动脚本 ==="
    
    # 1. 编译
    if ! compile_geth; then
        return 1
    fi
    
    # 2. 检查账户
    if ! check_account; then
        return 1
    fi
    
    # 3. 获取账户地址
    local account=$(get_account)
    if [ -z "$account" ]; then
        log_info "✗ 无法获取账户地址"
        return 1
    fi
    log_info "✓ 账户地址: 0x$account"
    
    # 4. 停止已运行的 geth
    if check_geth_running; then
        log_info "⚠ 检测到 geth 正在运行，正在停止..."
        pkill -f "geth.*Pantanal"
        sleep 3
    fi
    
    # 5. 检查密码文件，如果不存在则创建
    if [ ! -f "$PASSWORD_FILE" ] && [ -t 0 ]; then
        log_info ""
        log_info "⚠ 未找到密码文件，需要创建密码文件以支持自动解锁和挖矿"
        log_info "请输入账户密码（账户地址: 0x$account）："
        read -s password_input
        echo ""
        
        if [ -z "$password_input" ]; then
            log_info "✗ 密码不能为空"
            log_info "请稍后手动创建密码文件: echo 'your_password' > $PASSWORD_FILE && chmod 600 $PASSWORD_FILE"
        else
            echo "$password_input" > "$PASSWORD_FILE"
            chmod 600 "$PASSWORD_FILE"
            log_info "✓ 密码文件已创建: $PASSWORD_FILE"
        fi
    fi
    
    # 6. 启动 geth
    if ! start_geth_only; then
        return 1
    fi
    
    # 7. 解锁并启动挖矿
    unlock_and_mine
    local unlock_result=$?
    
    if [ $unlock_result -eq 0 ]; then
        # 完全成功（解锁+挖矿）
        log_info "✓ 账户已解锁，挖矿已启动"
    elif [ $unlock_result -eq 2 ]; then
        # 解锁成功但挖矿失败
        log_info "✓ 账户已解锁，但挖矿启动失败"
        log_info "  可以稍后手动启动挖矿: ./pantanal.sh unlock"
    else
        # 解锁失败
        log_info "⚠ geth 已启动，但解锁失败"
        log_info ""
        log_info "提示：请配置密码文件以支持自动解锁和挖矿："
        log_info "  echo 'your_password' > $PASSWORD_FILE && chmod 600 $PASSWORD_FILE"
        log_info ""
        log_info "或者手动解锁: ./pantanal.sh unlock"
    fi
    
    log_info ""
    log_info "=== 验证节点已启动 ==="
    log_info "HTTP JSON-RPC:     http://0.0.0.0:8545"
    log_info "WebSocket:         ws://0.0.0.0:8545"
    log_info "P2P Port:          30303"
    log_info ""
    log_info "日志文件: $GETH_LOG"
    log_info "查看日志: tail -f $GETH_LOG"
    log_info "停止节点: $SCRIPT_NAME stop"
    log_info "连接到控制台: geth --Pantanal attach"
}

# 监控模式（检查并自动启动、解锁、挖矿）
monitor() {
    if check_geth_running; then
        local current_pid=$(pgrep -f "geth.*Pantanal" | head -1)
        if [ -n "$current_pid" ]; then
            echo $current_pid > "$GETH_PID_FILE"
        fi
        log "$MONITOR_LOG" "✓ Geth 运行正常 (PID: $current_pid)"
        
        # 检查是否需要解锁和挖矿
        local account=$(get_account)
        if [ -n "$account" ]; then
            # 检查挖矿状态
            local mining_status=$(curl -s -X POST http://127.0.0.1:8545 \
                -H "Content-Type: application/json" \
                -d '{"jsonrpc":"2.0","method":"eth_mining","params":[],"id":1}' 2>/dev/null | grep -o '"result":[^,}]*' | cut -d: -f2 | tr -d ' ')
            
            if [ "$mining_status" != "true" ]; then
                log "$MONITOR_LOG" "⚠ 挖矿未运行，尝试解锁并启动挖矿..."
                if unlock_and_mine; then
                    log "$MONITOR_LOG" "✓ 解锁并启动挖矿成功"
                else
                    log "$MONITOR_LOG" "✗ 解锁或启动挖矿失败（需要配置密码文件）"
                    log "$MONITOR_LOG" "   配置方法: echo 'your_password' > $PASSWORD_FILE && chmod 600 $PASSWORD_FILE"
                fi
            else
                log "$MONITOR_LOG" "✓ 挖矿运行正常"
            fi
        fi
    else
        log "$MONITOR_LOG" "⚠ Geth 未运行，正在启动..."
        if start_geth_only; then
            log "$MONITOR_LOG" "✓ Geth 启动成功"
            
            # 等待 geth 完全启动
            sleep 5
            
            # 尝试解锁并启动挖矿
            log "$MONITOR_LOG" "正在尝试解锁账户并启动挖矿..."
            if unlock_and_mine; then
                log "$MONITOR_LOG" "✓ 解锁并启动挖矿成功"
            else
                log "$MONITOR_LOG" "✗ 解锁或启动挖矿失败（需要配置密码文件）"
                log "$MONITOR_LOG" "   配置方法: echo 'your_password' > $PASSWORD_FILE && chmod 600 $PASSWORD_FILE"
            fi
        else
            log "$MONITOR_LOG" "✗ Geth 启动失败"
        fi
    fi
}

# 显示状态
show_status() {
    log_info "=== Pantanal Geth 状态 ==="
    
    if check_geth_running; then
        local pid=$(pgrep -f "geth.*Pantanal" | head -1)
        log_info "✓ Geth 正在运行 (PID: $pid)"
        
        # 检查挖矿状态
        local mining=$(curl -s -X POST http://127.0.0.1:8545 \
            -H "Content-Type: application/json" \
            -d '{"jsonrpc":"2.0","method":"eth_mining","params":[],"id":1}' 2>/dev/null | grep -o '"result":[^,}]*' | cut -d: -f2 | tr -d ' ')
        
        if [ "$mining" = "true" ]; then
            log_info "✓ 挖矿: 运行中"
        else
            log_info "⚠ 挖矿: 未运行"
        fi
        
        # 获取区块高度
        local block=$(curl -s -X POST http://127.0.0.1:8545 \
            -H "Content-Type: application/json" \
            -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' 2>/dev/null | grep -o '"result":"[^"]*"' | cut -d'"' -f4)
        
        if [ -n "$block" ]; then
            local block_num=$((16#${block#0x}))
            log_info "当前区块: $block_num"
        fi
        
        local account=$(get_account)
        if [ -n "$account" ]; then
            log_info "账户地址: 0x$account"
        fi
    else
        log_info "✗ Geth 未运行"
    fi
    
    log_info ""
    log_info "日志文件:"
    log_info "  - Geth: $GETH_LOG"
    log_info "  - 监控: $MONITOR_LOG"
    log_info "  - 解锁: $UNLOCK_LOG"
}

# 停止 geth
stop_geth() {
    if check_geth_running; then
        log_info "正在停止 geth..."
        pkill -f "geth.*Pantanal"
        sleep 2
        if check_geth_running; then
            log_info "✗ 停止失败，尝试强制停止..."
            pkill -9 -f "geth.*Pantanal"
        else
            log_info "✓ Geth 已停止"
        fi
    else
        log_info "Geth 未运行"
    fi
}

# 显示帮助信息
show_help() {
    cat <<EOF
Pantanal 验证节点统一管理脚本

用法: $SCRIPT_NAME <command> [options]

命令:
  start       完整启动（编译、检查账户、启动geth、解锁挖矿）
  monitor     监控模式（检查geth是否运行，未运行则自动启动并解锁挖矿）
  unlock      解锁账户并启动挖矿（需要geth已运行）
  status      显示geth运行状态
  stop        停止geth
  help        显示此帮助信息

示例:
  $SCRIPT_NAME start          # 完整启动节点
  $SCRIPT_NAME monitor        # 监控模式（通常用于cron）
  $SCRIPT_NAME unlock         # 解锁账户并启动挖矿
  $SCRIPT_NAME status         # 查看状态
  $SCRIPT_NAME stop           # 停止节点

密码文件配置:
  echo "your_password" > $PASSWORD_FILE
  chmod 600 $PASSWORD_FILE

Cron 监控设置:
  * * * * * $SCRIPT_NAME monitor >> $MONITOR_LOG 2>&1

EOF
}

# 主函数
main() {
    local command="${1:-help}"
    
    case "$command" in
        start)
            start_full
            ;;
        monitor)
            monitor
            ;;
        unlock)
            unlock_and_mine
            ;;
        status)
            show_status
            ;;
        stop)
            stop_geth
            ;;
        help|--help|-h)
            show_help
            ;;
        *)
            log_info "未知命令: $command"
            echo ""
            show_help
            exit 1
            ;;
    esac
}

# 执行主函数
main "$@"

