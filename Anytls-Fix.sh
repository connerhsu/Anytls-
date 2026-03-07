#!/bin/bash
# ====================================================
# AnyTLS-Go 极致动态版 (Connor 定制：自动每日换肤)
# ====================================================

# --- 颜色定义 ---
RED='\033[31m'; GREEN='\033[32m'; YELLOW='\033[33m'; BLUE='\033[34m'; CYAN='\033[36m'; PLAIN='\033[0m'; BOLD='\033[1m'

# --- 路径与链接配置 ---
REPO_URL="https://raw.githubusercontent.com/connerhsu/Anytls-/refs/heads/main/Anytls-Fix.sh"
INSTALL_DIR="/opt/anytls"; CONFIG_DIR="/etc/anytls"
CONFIG_FILE="${CONFIG_DIR}/server.conf"; VERSION_FILE="${INSTALL_DIR}/version"
SERVICE_FILE="/etc/systemd/system/anytls.service"; TARGET_BIN="/usr/local/bin/anytls"

# --- 1. 环境增强：开启 BBR ---
enable_bbr() {
    if ! sysctl net.ipv4.tcp_congestion_control | grep -q "bbr"; then
        echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
        echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
        sysctl -p >/dev/null 2>&1
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

    # 修复：使用 -padding-scheme 并移除不支持的 --sni
    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=AnyTLS-Go
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

# --- 4. 核心：定时任务 (Crontab) 设置 ---
setup_cron() {
    echo -e "${CYAN}正在配置每日凌晨 3 点自动更新指纹...${PLAIN}"
    # 确保 cron 正在运行
    systemctl enable --now cron || systemctl enable --now crond
    
    # 避免重复添加任务
    crontab -l | grep -v "$TARGET_BIN --refresh" > /tmp/at_cron
    echo "0 3 * * * $TARGET_BIN --refresh > /dev/null 2>&1" >> /tmp/at_cron
    crontab /tmp/at_cron
    rm -f /tmp/at_cron
    echo -e "${GREEN}Crontab 任务设置成功！${PLAIN}"
}

# --- 5. 安装依赖 (加入 cron) ---
install_deps() {
    local missing=()
    for dep in curl unzip wget net-tools cron; do
        ! command -v "$dep" &>/dev/null && missing+=("$dep")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        apt-get update -y && apt-get install -y "${missing[@]}" || yum install -y epel-release && yum install -y "${missing[@]}"
    fi
}

# --- 6. 核心安装逻辑 ---
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
    echo -e "${BOLD}=== 配置 AnyTLS ===${PLAIN}"
    read -p "端口 [8443]: " port; port=${port:-8443}
    read -p "密码 [随机]: " pass; pass=${pass:-$(head /dev/urandom | tr -dc 'a-zA-Z0-9' | head -c 12)}
    read -p "域名 [www.cisco.com]: " sni; sni=${sni:-"www.cisco.com"}
    save_config "$port" "$pass" "$sni"
    setup_cron
    show_result
}

show_result() {
    [ ! -f "$CONFIG_FILE" ] && echo -e "${RED}未发现配置${PLAIN}" && return
    source "$CONFIG_FILE"
    local ip=$(curl -s4m5 https://api.ipify.org || echo "你的IP")
    clear
    echo -e "${GREEN}=== AnyTLS 运行中 (每日自动换肤) ===${PLAIN}"
    echo -e "地址: ${CYAN}$ip:$PORT${PLAIN}"
    echo -e "密码: ${CYAN}$PASSWORD${PLAIN}"
    echo -e "指纹: ${BLUE}$PADDING${PLAIN}"
    echo -e "\n${YELLOW}提示：指纹每天凌晨 3 点会自动刷新，无需手动干预。${PLAIN}"
    read -p "回车返回..."
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
        echo -e " 1. ${GREEN}执行安装/重置 (开启 BBR & 定时任务)${PLAIN}"
        echo -e " 2. 查看当前配置/连接链接"
        echo -e " 4. ${YELLOW}手动立即刷新指纹并重启${PLAIN}"
        echo -p " 9. 完全卸载"
        echo -e " 0. 退出"
        read -p " 选择 [0-9]: " num
        case "$num" in
            1) first_install ;;
            2) show_result ;;
            4) if [ -f "$CONFIG_FILE" ]; then source "$CONFIG_FILE"; save_config "$PORT" "$PASSWORD" "$SNI"; echo -e "${GREEN}刷新成功${PLAIN}"; sleep 1; fi ;;
            0) exit 0 ;;
            *) menu ;;
        esac
    done
}

# --- 启动 ---
if [[ "$1" == "--refresh" ]]; then
    # 给 Crontab 调用的静默刷新接口
    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
        save_config "$PORT" "$PASSWORD" "$SNI"
    fi
    exit 0
fi

if [[ "$0" != "$TARGET_BIN" ]]; then
    # 首次运行自动部署二进制到系统路径
    mkdir -p $(dirname "$TARGET_BIN")
    cp "$0" "$TARGET_BIN" && chmod +x "$TARGET_BIN"
fi
menu
