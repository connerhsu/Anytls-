#!/bin/bash
# ====================================================
# AnyTLS-Go 高效优化版 (随机混淆 + 一键 BBR)
# ====================================================

# --- 颜色定义 ---
RED='\033[31m'; GREEN='\033[32m'; YELLOW='\033[33m'; BLUE='\033[34m'; CYAN='\033[36m'; PLAIN='\033[0m'; BOLD='\033[1m'

# --- 路径与链接配置 ---
REPO_URL="https://raw.githubusercontent.com/connerhsu/Anytls-/refs/heads/main/Anytls-Fix.sh"
INSTALL_DIR="/opt/anytls"; CONFIG_DIR="/etc/anytls"
CONFIG_FILE="${CONFIG_DIR}/server.conf"; VERSION_FILE="${INSTALL_DIR}/version"
SERVICE_FILE="/etc/systemd/system/anytls.service"; TARGET_BIN="/usr/local/bin/anytls"

# --- 1. 环境增强：一键开启 BBR ---
enable_bbr() {
    echo -e "${CYAN}正在检查 BBR 状态...${PLAIN}"
    if sysctl net.ipv4.tcp_congestion_control | grep -q "bbr"; then
        echo -e "${GREEN}BBR 已经开启。${PLAIN}"
    else
        echo -e "${YELLOW}正在尝试开启 BBR...${PLAIN}"
        # 写入配置
        echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
        echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
        sysctl -p >/dev/null 2>&1
        if sysctl net.ipv4.tcp_congestion_control | grep -q "bbr"; then
            echo -e "${GREEN}BBR 开启成功！${PLAIN}"
        else
            echo -e "${RED}BBR 开启失败，请检查内核版本是否 > 4.9${PLAIN}"
        fi
    fi
}

# --- 2. 随机混淆生成器 ---
generate_padding_json() {
    local stop=$((6 + RANDOM % 8))
    local r1=$((80 + RANDOM % 150)); local r2=$((300 + RANDOM % 400)); local r3=$((500 + RANDOM % 500))
    # 压缩为一行以提高 CLI 兼容性
    echo "[\"stop=${stop}\",\"0=$((20+RANDOM%20))-$((40+RANDOM%20))\",\"1=${r1}-$((r1+200))\",\"2=${r2}-$((r2+300)),c,${r3}-$((r3+200)),c,${r3}-$((r3+300))\",\"3=$((10+RANDOM%10))-$((20+RANDOM%10))\",\"4=$((200+RANDOM%300))-$((600+RANDOM%200))\",\"5=$((400+RANDOM%200))-$((800+RANDOM%200))\"]"
}

# --- 3. 脚本自混淆 ---
add_script_padding() {
    echo -e "\n# Fingerprint: $(head /dev/urandom | tr -dc 'a-zA-Z0-9' | head -c 32)" >> "$1"
}

# --- 4. 核心逻辑 ---
check_root() {
    [[ $EUID -ne 0 ]] && echo -e "${RED}错误: 必须使用 root 运行${PLAIN}" && exit 1
}

install_global() {
    if [[ "$0" != "$TARGET_BIN" ]]; then
        echo -e "${CYAN}环境初始化中...${PLAIN}"
        curl -sSL -o "$TARGET_BIN" "$REPO_URL" || wget -qO "$TARGET_BIN" "$REPO_URL"
        add_script_padding "$TARGET_BIN" && chmod +x "$TARGET_BIN"
        exec bash "$TARGET_BIN" "$@" < /dev/tty
    else
        # 后台静默同步远端脚本
        (curl -sSL -o /tmp/at_sync.sh "$REPO_URL" && cat /tmp/at_sync.sh > "$TARGET_BIN" && add_script_padding "$TARGET_BIN" && rm -f /tmp/at_sync.sh) &
    fi
}

install_deps() {
    local missing=()
    for dep in curl unzip wget net-tools; do
        ! command -v "$dep" &>/dev/null && missing+=("$dep")
    done
    [[ ${#missing[@]} -gt 0 ]] && (apt-get update -y || yum install -y epel-release) && (apt-get install -y "${missing[@]}" || yum install -y "${missing[@]}")
}

update_core() {
    local target=$1; local repo="anytls/anytls-go"
    [[ -z "$target" ]] && target=$(curl -sL "https://api.github.com/repos/$repo/releases/latest" | grep -o '"tag_name": *"[^"]*"' | head -1 | cut -d'"' -f4)
    
    local arch=$(uname -m); local kw=""
    [[ "$arch" == "x86_64" ]] && kw="amd64" || kw="arm64"

    local url=$(curl -sL "https://api.github.com/repos/$repo/releases/tags/$target" | grep -o '"browser_download_url": *"[^"]*"' | grep "linux" | grep "$kw" | head -1 | cut -d'"' -f4)

    wget -qO /tmp/at.zip "$url" && mkdir -p "$INSTALL_DIR"
    unzip -qo /tmp/at.zip -d /tmp/at_tmp
    find /tmp/at_tmp -type f -name "anytls-server" -exec cp -f {} "$INSTALL_DIR/anytls-server" \;
    chmod +x "$INSTALL_DIR/anytls-server" && echo "$target" > "$VERSION_FILE"
    rm -rf /tmp/at.zip /tmp/at_tmp
}

save_config() {
    local pad=$(generate_padding_json)
    mkdir -p "$CONFIG_DIR"
    cat > "$CONFIG_FILE" <<EOF
PORT="$1"; PASSWORD="$2"; SNI="$3"; PADDING='$pad'
EOF
    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=AnyTLS-Go
After=network.target
[Service]
Type=simple
User=root
ExecStart=${INSTALL_DIR}/anytls-server -l 0.0.0.0:$1 -p "$2" --padding '$pad'
Restart=always
LimitNOFILE=1048576
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload && systemctl enable anytls && systemctl restart anytls
}

first_install() {
    install_deps
    enable_bbr   # 一键开启 BBR
    update_core
    clear
    echo -e "${BOLD}=== 配置 AnyTLS ===${PLAIN}"
    read -p "端口 [8443]: " port; port=${port:-8443}
    read -p "密码 [随机]: " pass; pass=${pass:-$(head /dev/urandom | tr -dc 'a-zA-Z0-9' | head -c 12)}
    read -p "域名 [www.cisco.com]: " sni; sni=${sni:-"www.cisco.com"}
    save_config "$port" "$pass" "$sni"
    show_result
}

show_result() {
    source "$CONFIG_FILE"
    local ip=$(curl -s4m5 https://api.ipify.org || echo "你的IP")
    clear
    echo -e "${GREEN}=== 安装成功 ===${PLAIN}"
    echo -e "地址: ${CYAN}$ip:$PORT${PLAIN}"
    echo -e "密码: ${CYAN}$PASSWORD${PLAIN}"
    echo -e "域名: ${CYAN}$SNI${PLAIN}"
    echo -e "混淆: ${BLUE}$PADDING${PLAIN}"
    echo -e "\n${YELLOW}分享链接:${PLAIN}"
    echo -e "${CYAN}anytls://$PASSWORD@$ip:$PORT?sni=$SNI&insecure=1#AnyTLS_$(date +%s)${PLAIN}\n"
    read -p "回车返回..."
}

menu() {
    while true; do
        clear
        local status="${RED}● 停止${PLAIN}"
        systemctl is-active --quiet anytls && status="${GREEN}● 运行中${PLAIN}"
        echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${PLAIN}"
        echo -e "       AnyTLS 高效版 (BBR+动态混淆)"
        echo -e " 状态: $status   版本: ${YELLOW}$(cat "$VERSION_FILE" 2>/dev/null)${PLAIN}"
        echo -e "----------------------------------------"
        echo -e " 1. ${GREEN}安装/重置 (强制刷新随机混淆)${PLAIN}"
        echo -e " 2. 查看配置信息"
        echo -e " 3. 日志查看"
        echo -e " 4. ${YELLOW}仅刷新混淆规则并重启${PLAIN}"
        echo -e " 9. ${RED}完全卸载${PLAIN}"
        echo -e " 0. 退出"
        read -p " 选择 [0-9]: " num
        case "$num" in
            1) first_install ;;
            2) show_result ;;
            3) journalctl -u anytls -f ;;
            4) source "$CONFIG_FILE"; save_config "$PORT" "$PASSWORD" "$SNI"; echo -e "${GREEN}规则已刷新${PLAIN}"; sleep 1 ;;
            9) systemctl stop anytls; rm -rf "$INSTALL_DIR" "$CONFIG_DIR" "$TARGET_BIN" "$SERVICE_FILE"; exit 0 ;;
            0) exit 0 ;;
        esac
    done
}

# --- 启动 ---
check_root
install_global "$@"
menu
