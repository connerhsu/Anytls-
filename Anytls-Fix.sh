#!/bin/bash
# ====================================================
# AnyTLS-Go 极致动态版 (针对新版参数修复 + 每日换肤)
# ====================================================

# 颜色定义
RED='\033[31m'; GREEN='\033[32m'; YELLOW='\033[33m'; BLUE='\033[34m'; CYAN='\033[36m'; PLAIN='\033[0m'

# 路径配置
INSTALL_DIR="/opt/anytls"; CONFIG_DIR="/etc/anytls"
CONFIG_FILE="${CONFIG_DIR}/server.conf"; SERVICE_FILE="/etc/systemd/system/anytls.service"
TARGET_BIN="/usr/local/bin/anytls"

# 1. 环境依赖安装 (包含 cron)
install_deps() {
    echo -e "${CYAN}正在安装必要依赖 (curl, unzip, cron)...${PLAIN}"
    if command -v apt-get >/dev/null; then
        apt-get update -y && apt-get install -y curl unzip wget cron
        systemctl enable --now cron
    else
        yum install -y epel-release && yum install -y curl unzip wget crontabs
        systemctl enable --now crond
    fi
}

# 2. 增强型随机混淆生成器
generate_padding_json() {
    local stop=$((8 + RANDOM % 10))
    local r1=$((100 + RANDOM % 100)); local r2=$((500 + RANDOM % 300))
    local r3=$((700 + RANDOM % 300)); local r5=$((400 + RANDOM % 400))
    # 构建符合新版 -padding-scheme 要求的 JSON
    echo "[\"stop=${stop}\",\"0=$((10+RANDOM%30))-$((50+RANDOM%40))\",\"1=${r1}-$((r1+200))\",\"2=${r2}-$((r2+200)),c,${r3}-$((r3+150)),c,${r3}-$((r3+300))\",\"3=$((15+RANDOM%10))-$((30+RANDOM%20))\",\"4=$((250+RANDOM%200))-$((750+RANDOM%200))\",\"5=${r5}-$((r5+500))\"]"
}

# 3. 核心：保存配置并修复 Systemd 参数
save_config() {
    local pad=$(generate_padding_json)
    mkdir -p "$CONFIG_DIR"
    
    # 存储基础配置
    cat > "$CONFIG_FILE" <<EOF
PORT="$1"; PASSWORD="$2"; SNI="$3"; PADDING='$pad'
EOF

    # 关键修复：使用 -padding-scheme 并移除不支持的 --sni
    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=AnyTLS-Go Service
After=network.target

[Service]
Type=simple
User=root
ExecStart=${INSTALL_DIR}/anytls-server -l 0.0.0.0:$1 -p "$2" -padding-scheme '$pad'
Restart=always
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload && systemctl restart anytls
}

# 4. 配置每日凌晨 3 点自动更新指纹
setup_cron() {
    # 避免重复写入
    (crontab -l 2>/dev/null | grep -v "$TARGET_BIN --refresh"; echo "0 3 * * * $TARGET_BIN --refresh > /dev/null 2>&1") | crontab -
    echo -e "${GREEN}Crontab 定时任务已设置：每日凌晨 03:00 自动刷新指纹。${PLAIN}"
}

# 5. 管理菜单
menu() {
    clear
    echo -e "${CYAN}AnyTLS 极致版管理脚本${PLAIN}"
    echo -e "--------------------------------"
    echo -e "1. ${GREEN}安装/重置 (包含定时任务)${PLAIN}"
    echo -e "2. 查看当前配置"
    echo -e "3. 立即手动刷新指纹并重启"
    echo -e "0. 退出"
    read -p "选择 [0-3]: " num
    case "$num" in
        1) 
            install_deps
            # 开启 BBR
            echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
            echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
            sysctl -p >/dev/null 2>&1
            # 获取配置并安装
            read -p "端口 [8443]: " port; port=${port:-8443}
            read -p "密码: " pass; pass=${pass:-$(head /dev/urandom | tr -dc 'a-zA-Z0-9' | head -c 12)}
            save_config "$port" "$pass" "www.cisco.com"
            setup_cron
            echo -e "${GREEN}安装并启动成功！${PLAIN}"
            ;;
        2) 
            source "$CONFIG_FILE"
            echo -e "${CYAN}地址: $(curl -s4 ip.sb):$PORT${PLAIN}"
            echo -e "${CYAN}密码: $PASSWORD${PLAIN}"
            echo -e "${CYAN}当前混淆: $PADDING${PLAIN}"
            ;;
        3) 
            source "$CONFIG_FILE"
            save_config "$PORT" "$PASSWORD" "$SNI"
            echo -e "${GREEN}指纹已手动刷新并重启！${PLAIN}"
            ;;
        *) exit 0 ;;
    esac
}

# 自动处理定时任务调用
if [[ "$1" == "--refresh" ]]; then
    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
        save_config "$PORT" "$PASSWORD" "$SNI"
    fi
    exit 0
fi

# 同步脚本到系统路径以便定时任务调用
cp "$0" "$TARGET_BIN" && chmod +x "$TARGET_BIN"
menu
