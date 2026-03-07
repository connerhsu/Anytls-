#!/bin/bash
# ====================================================
# AnyTLS-Go 动态混淆随机版 (快捷键: anytls)
# 特性: 
# 1. 每次运行脚本强制随机化脚本指纹 (Padding)
# 2. 自动生成随机 TLS 数据包填充策略 (JSON Padding)
# 3. 修复管道运行环境，支持快捷键一键唤出
# ====================================================

# --- 颜色定义 ---
RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
BLUE='\033[34m'
CYAN='\033[36m'
PLAIN='\033[0m'
BOLD='\033[1m'

# --- 路径与链接配置 ---
REPO_URL="https://raw.githubusercontent.com/connerhsu/Anytls-/refs/heads/main/Anytls-Fix.sh"
INSTALL_DIR="/opt/anytls"
CONFIG_DIR="/etc/anytls"
CONFIG_FILE="${CONFIG_DIR}/server.conf"
VERSION_FILE="${INSTALL_DIR}/version"
SERVICE_FILE="/etc/systemd/system/anytls.service"
TARGET_BIN="/usr/local/bin/anytls"

# --- 0. 核心：随机数据包填充策略生成器 ---
# 模仿官方文档格式，但数值全部随机化，避免固定指纹
generate_padding_json() {
    local stop=$((6 + RANDOM % 8)) # 停止位在 6-13 之间随机
    local r1=$((80 + RANDOM % 150))
    local r2=$((300 + RANDOM % 400))
    local r3=$((500 + RANDOM % 500))

    cat <<EOF
[
  "stop=${stop}",
  "0=$((20 + RANDOM % 20))-$((40 + RANDOM % 20))",
  "1=${r1}-$((r1 + 200))",
  "2=${r2}-$((r2 + 300)),c,${r3}-$((r3 + 200)),c,${r3}-$((r3 + 300))",
  "3=$((10 + RANDOM % 10))-$((20 + RANDOM % 10))",
  "4=$((200 + RANDOM % 300))-$((600 + RANDOM % 200))",
  "5=$((400 + RANDOM % 200))-$((800 + RANDOM % 200))"
]
EOF
}

# --- 1. 脚本自混淆 (改变脚本自身的 MD5) ---
add_script_padding() {
    local rand_str=$(head /dev/urandom | tr -dc 'a-zA-Z0-9' | head -c $((16 + RANDOM % 48)))
    echo -e "\n# Fingerprint: ${rand_str}" >> "$1"
}

# --- 2. 基础检查与自更新逻辑 ---
check_root() {
    [[ $EUID -ne 0 ]] && echo -e "${RED}必须使用 root 权限运行！${PLAIN}" && exit 1
}

install_global() {
    if [[ "$0" != "$TARGET_BIN" ]]; then
        echo -e "${CYAN}正在初始化 AnyTLS 环境...${PLAIN}"
        if command -v wget >/dev/null; then wget -qO "$TARGET_BIN" "$REPO_URL"; else curl -sSL -o "$TARGET_BIN" "$REPO_URL"; fi
        add_script_padding "$TARGET_BIN"
        chmod +x "$TARGET_BIN"
        exec bash "$TARGET_BIN" "$@" < /dev/tty
    else
        # 每次运行本地 anytls，都尝试同步远端并重新随机化本地脚本
        local tmp_sh="/tmp/anytls_rand.sh"
        if curl -sSL -o "$tmp_sh" "$REPO_URL" || wget -qO "$tmp_sh" "$REPO_URL"; then
            cat "$tmp_sh" > "$TARGET_BIN"
            add_script_padding "$TARGET_BIN"
            chmod +x "$TARGET_BIN"
            rm -f "$tmp_sh"
        fi
    fi
}

install_deps() {
    local deps=("curl" "unzip" "net-tools" "wget")
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &>/dev/null; then
            echo -e "正在安装依赖: $dep"
            apt-get update -y >/dev/null 2>&1 || yum install -y "$dep" >/dev/null 2>&1
            apt-get install -y "$dep" >/dev/null 2>&1
        fi
    done
}

# --- 3. 功能模块 ---
update_core() {
    local target=$1
    echo -e "${CYAN}正在获取最新核心...${PLAIN}"
    # 这里保持你原本的 GitHub API 获取逻辑
    local repo="anytls/anytls-go"
    [[ -z "$target" ]] && target=$(curl -sL "https://api.github.com/repos/$repo/releases/latest" | grep -o '"tag_name": *"[^"]*"' | head -n 1 | sed 's/"tag_name": "//;s/"//')
    
    ARCH=$(uname -m)
    case $ARCH in
        x86_64|amd64) KW="amd64" ;;
        aarch64|arm64) KW="arm64" ;;
        *) echo "不支持的架构"; return ;;
    esac

    URL=$(curl -sL "https://api.github.com/repos/$repo/releases/tags/$target" | grep -o '"browser_download_url": *"[^"]*"' | grep -i "linux" | grep -i "$KW" | grep -i "\.zip" | head -n 1 | sed 's/"browser_download_url": "//;s/"//')

    wget -qO /tmp/anytls.zip "$URL"
    mkdir -p /tmp/anytls_tmp && unzip -qo /tmp/anytls.zip -d /tmp/anytls_tmp
    BIN=$(find /tmp/anytls_tmp -type f -name "anytls-server" | head -n 1)
    if [[ -n "$BIN" ]]; then
        systemctl stop anytls 2>/dev/null
        mkdir -p "$INSTALL_DIR"
        cp -f "$BIN" "$INSTALL_DIR/anytls-server"
        chmod +x "$INSTALL_DIR/anytls-server"
        echo "$target" > "$VERSION_FILE"
    fi
    rm -rf /tmp/anytls.zip /tmp/anytls_tmp
}

write_config() {
    # 每次写入配置时重新生成随机 Padding JSON
    local padding_val=$(generate_padding_json | tr -d '\n' | sed 's/ //g')
    
    # 写入配置文件供脚本读取
    cat > "$CONFIG_FILE" << EOF
PORT="${1}"
PASSWORD="${2}"
SNI="${3}"
PADDING='${padding_val}'
EOF

    # 写入 Systemd 服务
    cat > "$SERVICE_FILE" << EOF
[Unit]
Description=AnyTLS-Go Server
After=network.target

[Service]
Type=simple
User=root
ExecStart=${INSTALL_DIR}/anytls-server -l 0.0.0.0:${1} -p "${2}" -padding-scheme '${padding_val}'
Restart=always
RestartSec=3
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl restart anytls
}

first_install() {
    install_deps
    update_core
    clear
    echo -e "${BOLD}=== 初始化配置 (Padding 已自动随机化) ===${PLAIN}"
    read -p "端口 [8443]: " PORT
    PORT=${PORT:-8443}
    read -p "密码 [随机]: " PASSWORD
    PASSWORD=${PASSWORD:-$(head /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 16)}
    read -p "域名 [www.cisco.com]: " SNI
    SNI=${SNI:-"www.cisco.com"}
    
    mkdir -p "$CONFIG_DIR"
    write_config "$PORT" "$PASSWORD" "$SNI"
    show_result
}

show_result() {
    source "$CONFIG_FILE"
    IP=$(curl -s4m5 https://api.ipify.org || echo "127.0.0.1")
    clear
    echo -e "${GREEN}=== AnyTLS 节点信息 (已应用动态混淆) ===${PLAIN}"
    echo -e "地址: ${CYAN}${IP}:${PORT}${PLAIN}"
    echo -e "密码: ${CYAN}${PASSWORD}${PLAIN}"
    echo -e "SNI:  ${CYAN}${SNI}${PLAIN}"
    echo -e "\n${YELLOW}当前 Padding 策略:${PLAIN}"
    echo -e "${BLUE}${PADDING}${PLAIN}"
    echo -e "\n${YELLOW}分享链接:${PLAIN}"
    echo -e "${CYAN}anytls://${PASSWORD}@${IP}:${PORT}?sni=${SNI}&insecure=1#Random_Node${PLAIN}\n"
    read -p "按回车返回菜单..."
}

# --- 4. 菜单系统 ---
menu() {
    while true; do
        clear
        VER=$(cat "$VERSION_FILE" 2>/dev/null || echo "未安装")
        STATUS="${RED}● 停止${PLAIN}"
        systemctl is-active --quiet anytls && STATUS="${GREEN}● 运行中${PLAIN}"
        
        echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${PLAIN}"
        echo -e "           AnyTLS-Go 动态混淆面板"
        echo -e " 状态: ${STATUS}     版本: ${YELLOW}${VER}${PLAIN}"
        echo -e " 特性: 每次配置/安装都会重新生成随机 Padding"
        echo -e "----------------------------------------"
        echo -e " ${GREEN}1.${PLAIN} 安装 / 重置 (重新生成随机 Padding)"
        echo -e " ${GREEN}2.${PLAIN} 查看配置信息"
        echo -e " ${GREEN}3.${PLAIN} 查看日志"
        echo -p " ${YELLOW}5.${PLAIN} 修改端口/域名 (触发重新随机化)"
        echo -e " ${RED}9.${PLAIN} 卸载"
        echo -e " ${GREEN}0.${PLAIN} 退出"
        read -p " 选择: " num
        case "$num" in
            1) first_install ;;
            2) show_result ;;
            3) journalctl -u anytls -f ;;
            5) first_install ;; # 逻辑相同，复用即可
            9) systemctl stop anytls; rm -rf "$INSTALL_DIR" "$CONFIG_DIR" "$TARGET_BIN" "$SERVICE_FILE"; echo "已卸载"; exit 0 ;;
            0) exit 0 ;;
        esac
    done
}

check_root
install_global "$@"
menu
