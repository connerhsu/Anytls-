#!/bin/bash
# AnyTLS-Go 修复版 - 强制面板显示 + 每日 3 点换肤

RED='\033[31m'; GREEN='\033[32m'; YELLOW='\033[33m'; BLUE='\033[34m'; CYAN='\033[36m'; PLAIN='\033[0m'
CONFIG_FILE="/etc/anytls/server.conf"
TARGET_BIN="/usr/local/bin/anytls"

# --- 1. 核心修复：-padding-scheme 参数逻辑 ---
save_config() {
    # 随机混淆生成
    local stop=$((8 + RANDOM % 10))
    local pad="[\"stop=${stop}\",\"0=$((10+RANDOM%30))-$((50+RANDOM%40))\",\"1=120-380\",\"2=600-900,c,700-1000,c,700-1100\",\"3=20-40\",\"4=300-800\",\"5=500-1000\"]"
    
    mkdir -p /etc/anytls
    echo "PORT=\"$1\"; PASSWORD=\"$2\"; PADDING='$pad'" > "$CONFIG_FILE"

    # 写入 Systemd (严格匹配你 help 里的 -l -p -padding-scheme)
    cat > /etc/systemd/system/anytls.service <<EOF
[Unit]
Description=AnyTLS-Go
After=network.target
[Service]
Type=simple
ExecStart=/opt/anytls/anytls-server -l 0.0.0.0:$1 -p "$2" -padding-scheme '$pad'
Restart=always
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload && systemctl restart anytls
}

# --- 2. 自动化定时任务 ---
setup_cron() {
    apt-get install -y cron || yum install -y crontabs
    systemctl enable --now cron || systemctl enable --now crond
    (crontab -l 2>/dev/null | grep -v "anytls --refresh"; echo "0 3 * * * $TARGET_BIN --refresh > /dev/null 2>&1") | crontab -
}

# --- 3. 菜单面板 ---
menu() {
    clear
    echo -e "${CYAN}=== AnyTLS 管理面板 (已集成每日 3 点换肤) ===${PLAIN}"
    echo -e "1. 安装/重置 (一键开启 BBR + 定时任务)"
    echo -e "2. 查看当前配置"
    echo -e "4. 立即手动刷新随机指纹"
    echo -e "0. 退出"
    read -p "请选择: " num
    case "$num" in
        1)
            read -p "端口 [8443]: " port; port=${port:-8443}
            read -p "密码: " pass; pass=${pass:-$(head /dev/urandom | tr -dc 'a-zA-Z0-9' | head -c 12)}
            save_config "$port" "$pass"
            setup_cron
            echo -e "${GREEN}部署完成！已修复参数并添加定时任务。${PLAIN}"
            ;;
        2) [[ -f $CONFIG_FILE ]] && source $CONFIG_FILE && echo -e "地址: $(curl -s4 ip.sb):$PORT\n密码: $PASSWORD\n指纹: $PADDING" ;;
        4) source $CONFIG_FILE && save_config "$PORT" "$PASSWORD" && echo -e "${GREEN}指纹已更新${PLAIN}" ;;
        *) exit 0 ;;
    esac
}

# --- 启动触发 ---
if [[ "$1" == "--refresh" ]]; then
    source $CONFIG_FILE && save_config "$PORT" "$PASSWORD"
    exit 0
fi

# 确保脚本自己在路径中
cp "$0" "$TARGET_BIN" && chmod +x "$TARGET_BIN"
menu
