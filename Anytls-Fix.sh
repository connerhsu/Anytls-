cat > /usr/local/bin/anytls << 'EOF'
#!/bin/bash
# ====================================================
# AnyTLS-Go 极致全能版 (BBR + 每日自动换肤 + 参数修复)
# ====================================================

# --- 颜色与路径定义 ---
RED='\033[31m'; GREEN='\033[32m'; YELLOW='\033[33m'; BLUE='\033[34m'; CYAN='\033[36m'; PLAIN='\033[0m'; BOLD='\033[1m'
REPO_URL="https://raw.githubusercontent.com/connerhsu/Anytls-/refs/heads/main/Anytls-Fix.sh"
INSTALL_DIR="/opt/anytls"; CONFIG_DIR="/etc/anytls"
CONFIG_FILE="${CONFIG_DIR}/server.conf"; VERSION_FILE="${INSTALL_DIR}/version"
SERVICE_FILE="/etc/systemd/system/anytls.service"; TARGET_BIN="/usr/local/bin/anytls"

# --- 1. 环境增强：一键开启 BBR ---
enable_bbr() {
    if ! sysctl net.ipv4.tcp_congestion_control | grep -q "bbr"; then
        echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
        echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
        sysctl -p >/dev/null 2>&1
    fi
}

# --- 2. 随机混淆生成器 (核心加密指纹) ---
generate_padding_json() {
    local stop=$((8 + RANDOM % 10))
    local r1_s=$((100 + RANDOM % 100)); local r1_e=$((300 + RANDOM % 200))
    local r2_s=$((500 + RANDOM % 200)); local r2_e=$((800 + RANDOM % 200))
    echo "[\"stop=${stop}\",\"0=$((10+RANDOM%30))-$((50+RANDOM%40))\",\"1=${r1_s}-${r1_e}\",\"2=${r2_s}-${r2_e},c,$((700+RANDOM%200))-1000,c,$((700+RANDOM%200))-1100\",\"3=$((20+RANDOM%20))-$((40+RANDOM%20))\",\"4=$((250+RANDOM%200))-$((750+RANDOM%200))\",\"5=$((400+RANDOM%300))-$((900+RANDOM%400))\"]"
}

# --- 3. 核心保存与启动修复 (针对 -padding-scheme 优化) ---
save_config() {
    local pad=$(generate_padding_json)
    mkdir -p "$CONFIG_DIR"
    echo "PORT=\"$1\"; PASSWORD=\"$2\"; SNI=\"$3\"; PADDING='$pad'" > "$CONFIG_FILE"

    cat > "$SERVICE_FILE" <<EOF2
[Unit]
Description=AnyTLS-Go Service
After=network.target

[Service]
Type=simple
User=root
# 严格按照 help 里的参数修复：使用 -padding-scheme，移除不支持的 --sni
ExecStart=${INSTALL_DIR}/anytls-server -l 0.0.0.0:$1 -p "$2" -padding-scheme '$pad'
Restart=always
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF2

    systemctl daemon-reload && systemctl enable anytls && systemctl restart anytls
}

# --- 4. 自动化定时任务 (凌晨 3 点自动换肤) ---
setup_cron() {
    apt-get install -y cron || yum install -y crontabs
    systemctl enable --now cron || systemctl enable --now crond
    (crontab -l 2>/dev/null | grep -v "$TARGET_BIN --refresh"; echo "0 3 * * * $TARGET_BIN --refresh > /dev/null 2>&1") | crontab -
}

# --- 5. 核心逻辑：版本更新与依赖 ---
update_core() {
    local repo="anytls/anytls-go"
    local target=$(curl -sL "https://api.github.com/repos/$repo/releases/latest" | grep -o '"tag_name": *"[^"]*"' | head -1 | cut -d'"' -f4)
    local arch=$(uname -m); local kw="amd64"
    [[ "$arch" == "aarch64" ]] && kw="arm64"
    local url=$(curl -sL "https://api.github.com/repos/$repo/releases/tags/$target" | grep -o '"browser_download_url": *"[^"]*"' | grep "linux" | grep "$kw" | head -1 | cut -d'"' -f4)
    wget -qO /tmp/at.zip "$url" && mkdir -p "$INSTALL_DIR"
    unzip -qo /tmp/at.zip -d /tmp/at_tmp
    find /tmp/at_tmp -type f -name "anytls-server" -exec cp -f {} "$INSTALL_DIR/anytls-server" \;
    chmod +x "$INSTALL_DIR/anytls-server" && echo "$target" > "$VERSION_FILE"
    rm -rf /tmp/at.zip /tmp/at_tmp
}

# --- 6. 完整的管理菜单 ---
menu() {
    clear
    local status="${RED}● 停止${PLAIN}"
    systemctl is-active --quiet anytls && status="${GREEN}● 运行中${PLAIN}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${PLAIN}"
    echo -e "      AnyTLS 极致版 (BBR + 每日 3 点换肤)"
    echo -e " 状态: $status    版本: ${YELLOW}$(cat "$VERSION_FILE" 2>/dev/null)${PLAIN}"
    echo -e "----------------------------------------"
    echo -e " 1. ${GREEN}执行安装/重置 (强制刷新随机混淆)${PLAIN}"
    echo -e " 2. 查看配置信息 / 分享链接"
    echo -e " 3. 查看运行日志"
    echo -e " 4. ${YELLOW}立即随机换指纹并重启${PLAIN}"
    echo -e " 9. ${RED}完全卸载${PLAIN}"
    echo -e " 0. 退出"
    read -p " 选择 [0-9]: " num
    case "$num" in
        1)
            apt-get update -y && apt-get install -y curl unzip wget net-tools
            enable_bbr && update_core
            read -p "端口 [8443]: " port; port=${port:-8443}
            read -p "密码 [随机]: " pass; pass=${pass:-$(head /dev/urandom | tr -dc 'a-zA-Z0-9' | head -c 12)}
            read -p "SNI [www.cisco.com]: " sni; sni=${sni:-"www.cisco.com"}
            save_config "$port" "$pass" "$sni" && setup_cron
            echo -e "${GREEN}部署成功！已添加每日 3 点换肤任务。${PLAIN}"; read -p "回车继续..." ;;
        2)
            if [ -f "$CONFIG_FILE" ]; then
                source "$CONFIG_FILE"
                local ip=$(curl -s4m5 https://api.ipify.org)
                echo -e "${GREEN}地址:${PLAIN} $ip:$PORT\n${GREEN}密码:${PLAIN} $PASSWORD\n${GREEN}指纹:${PLAIN} $PADDING"
                echo -e "\n${YELLOW}分享链接:${PLAIN}\nanytls://$PASSWORD@$ip:$PORT?sni=$SNI&insecure=1#AnyTLS_$(date +%s)"
            else echo -e "${RED}未安装！${PLAIN}"; fi; read -p "回车继续..." ;;
        3) journalctl -u anytls -f ;;
        4) source "$CONFIG_FILE" && save_config "$PORT" "$PASSWORD" "$SNI" && echo -e "${GREEN}指纹已刷新${PLAIN}"; sleep 2 ;;
        9) systemctl stop anytls; systemctl disable anytls; rm -rf "$INSTALL_DIR" "$CONFIG_DIR" "$SERVICE_FILE" "$TARGET_BIN"; crontab -l | grep -v "$TARGET_BIN" | crontab -; exit 0 ;;
        *) exit 0 ;;
    esac
}

# 判断运行模式
if [[ "$1" == "--refresh" ]]; then
    source "$CONFIG_FILE" && save_config "$PORT" "$PASSWORD" "$SNI"
else
    menu
fi
EOF

chmod +x /usr/local/bin/anytls
anytls
