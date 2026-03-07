#!/bin/bash
# ====================================================
# AnyTLS-Go 极致动态版 (Connor 定制：每日自动随机指纹)
# ====================================================

# --- 颜色定义 ---
RED='\033[31m'; GREEN='\033[32m'; YELLOW='\033[33m'; BLUE='\033[34m'; CYAN='\033[36m'; PLAIN='\033[0m'; BOLD='\033[1m'

# --- 路径配置 ---
INSTALL_DIR="/opt/anytls"; CONFIG_DIR="/etc/anytls"
CONFIG_FILE="${CONFIG_DIR}/server.conf"; VERSION_FILE="${INSTALL_DIR}/version"
SERVICE_FILE="/etc/systemd/system/anytls.service"; TARGET_BIN="/usr/local/bin/anytls"

# --- 1. 环境增强：开启 BBR ---
enable_bbr() {
    echo -e "${CYAN}检查 BBR 状态...${PLAIN}"
    if ! sysctl net.ipv4.tcp_congestion_control | grep -q "bbr"; then
        echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
        echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
        sysctl -p >/dev/null 2>&1
        echo -e "${GREEN}BBR 已开启。${PLAIN}"
    fi
}

# --- 2. 增强型随机混淆生成器 ---
generate_padding_json() {
    local stop=$((8 + RANDOM % 10))
    local r0_s=$((10 + RANDOM % 40));  local r0_e=$((50 + RANDOM % 50))
    local r1_s=$((100 + RANDOM % 100)); local r1_e=$((300 + RANDOM % 200))
    local r2_1s=$((500 + RANDOM % 200)); local r2_1e=$((800 + RANDOM % 200))
    local r2_2s=$((700 + RANDOM % 200)); local r2_2e=$((1000 + RANDOM % 300))
    local r3_s=$((10 + RANDOM % 20));  local r3_e=$((30 + RANDOM % 30))
    local r4_s=$((200 + RANDOM % 200)); local r4_e=$((700 + RANDOM % 300))
    local r5_s=$((400 + RANDOM % 300)); local r5_e=$((900 + RANDOM % 400))

    # 构建符合 Anytls-Go 要求的 JSON 字符串
    echo "[\"stop=${stop}\",\"0=${r0_s}-${r0_e}\",\"1=${r1_s}-${r1_e}\",\"2=${r2_1s}-${r2_1e},c,${r2_2s}-${r2_1e},c,${r2_2s}-${r2_2e}\",\"3=${r3_s}-${r3_e}\",\"4=${r4_s}-${r4_e}\",\"5=${r5_s}-${r5_e}\"]"
}

# --- 3. 核心：保存配置与 Systemd 修复 ---
save_config() {
    local pad=$(generate_padding_json)
    mkdir -p "$CONFIG_DIR"
    
    # 存储当前配置
    cat > "$CONFIG_FILE" <<EOF
PORT="$1"; PASSWORD="$2"; SNI="$3"; PADDING='$pad'
EOF

    # 修复点：改用 -padding-scheme，移除不支持的 --sni
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

    systemctl daemon-reload && systemctl enable anytls && systemctl restart anytls
}

# --- 4. 定时任务 (Crontab) 设置 ---
setup_cron() {
    echo -e "${CYAN}配置每日凌晨 3 点自动更新指纹...${PLAIN}"
    # 确保 cron 服务已安装并运行
    if command -v apt-get >/dev/null; then
        apt-get install -y cron && systemctl enable --now cron
    elif command -v yum >/dev/null; then
        yum install -y crontabs && systemctl enable --now crond
    fi
    
    # 写入定时任务：每天凌晨 3:00 执行一次刷新逻辑
    (crontab -l 2>/dev/null | grep -v "$TARGET_BIN --refresh"; echo "0 3 * * * $TARGET_BIN --refresh > /dev/null 2>&1") | crontab -
    echo -e "${GREEN}定时任务已添加：每日凌晨 03:00 自动随机换肤。${PLAIN}"
}

# --- 5. 环境依赖安装 ---
install_deps() {
    local missing=()
    for dep in curl unzip wget net-tools cron; do
        ! command -v "$dep" &>/dev/null && missing+=("$dep")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        if command -v apt-get >/dev/null; then
            apt-get update -y && apt-get install -y "${missing[@]}"
        else
            yum install -y epel-release && yum install -y "${missing[@]}"
        fi
    fi
}

# --- 6. 菜单与安装逻辑 ---
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

first_install() {
    install_deps
    enable_bbr
    update_core
    clear
    echo -e "${BOLD}=== AnyTLS 极速安装 ===${PLAIN}"
    read -p "端口 [8443]: " port; port=${port:-8443}
    read -p "密码 [随机]: " pass; pass=${pass:-$(head /dev/urandom | tr -dc 'a-zA-Z0-9' | head -c 12)}
    read -p "伪装域名 [www.cisco.com]: " sni; sni=${sni:-"www.cisco.com"}
    save_config "$port" "$pass" "$sni"
    setup_cron
    show_result
}

show_result() {
    if [ ! -f "$CONFIG_FILE" ]; then echo -e "${RED}未安装！${PLAIN}"; return; fi
    source "$CONFIG_FILE"
    local ip=$(curl -s4m5 https://api.ipify.org || echo "你的IP")
    clear
    echo -e "${GREEN}=== AnyTLS 安装成功 (每日凌晨自动换肤) ===${PLAIN}"
    echo -e "地址: ${CYAN}$ip:$PORT${PLAIN}"
    echo -e "密码: ${CYAN}$PASSWORD${PLAIN}"
    echo -e "SNI:  ${CYAN}$SNI${PLAIN}"
    echo -e "当前混淆指纹: ${BLUE}$PADDING${PLAIN}"
    echo -e "\n${YELLOW}定时任务已生效，每天 03:00 将生成全新随机指纹并重启服务。${PLAIN}"
    read -p "按回车返回菜单..."
}

menu() {
    while true; do
        clear
        local status="${RED}● 停止${PLAIN}"
        systemctl is-active --quiet anytls && status="${GREEN}● 运行中${PLAIN}"
        echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${PLAIN}"
        echo -e "      AnyTLS 极致版 (BBR + 每日自动刷新)"
        echo -e " 状态: $status    版本: ${YELLOW}$(cat "$VERSION_FILE" 2>/dev/null)${PLAIN}"
        echo -e "----------------------------------------"
        echo -e " 1. ${GREEN}执行安装/重置 (开启 BBR & 定时刷新)${PLAIN}"
        echo -e " 2. 查看当前配置/连接链接"
        echo -e " 4. ${YELLOW}立即随机生成指纹并重启${PLAIN}"
        echo -e " 9. ${RED}完全卸载${PLAIN}"
        echo -e " 0. 退出"
        read -p " 选择 [0-9]: " num
        case "$num" in
            1) first_install ;;
            2) show_result ;;
            4) if [ -f "$CONFIG_FILE" ]; then source "$CONFIG_FILE"; save_config "$PORT" "$PASSWORD" "$SNI"; echo -e "${GREEN}已手动生成新随机指纹！${PLAIN}"; sleep 1; fi ;;
            9) systemctl stop anytls; systemctl disable anytls; rm -rf "$INSTALL_DIR" "$CONFIG_DIR" "$SERVICE_FILE"; crontab -l | grep -v "$TARGET_BIN" | crontab -; echo "已卸载"; exit 0 ;;
            0) exit 0 ;;
        esac
    done
}

# --- 启动逻辑 ---
# 检查是否由 Crontab 调用
if [[ "$1" == "--refresh" ]]; then
    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
        save_config "$PORT" "$PASSWORD" "$SNI"
    fi
    exit 0
fi

# 首次运行自动将脚本同步到 /usr/local/bin
if [[ "$0" != "$TARGET_BIN" ]]; then
    cp "$0" "$TARGET_BIN" && chmod +x "$TARGET_BIN"
fi

menu
