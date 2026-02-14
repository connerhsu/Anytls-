#!/bin/bash

# ====================================================
# AnyTLS-Go 系统修复版 (快捷键: anytls)
# ====================================================

# --- 颜色定义 ---
RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
BLUE='\033[34m'
CYAN='\033[36m'
PLAIN='\033[0m'
BOLD='\033[1m'

# --- 路径定义 ---
REPO="anytls/anytls-go"
INSTALL_DIR="/opt/anytls"
CONFIG_DIR="/etc/anytls"
CONFIG_FILE="${CONFIG_DIR}/server.conf"
VERSION_FILE="${INSTALL_DIR}/version"
SERVICE_FILE="/etc/systemd/system/anytls.service"

# 最终快捷键路径 (直接写入系统二进制目录)
TARGET_BIN="/usr/local/bin/anytls"

# --- 1. 环境清理与修复 (关键步骤) ---
fix_environment() {
    # 1. 删除导致冲突的旧快捷键
    rm -f /usr/local/bin/at
    rm -f /usr/local/bin/ats
    rm -f /usr/local/bin/anytls-menu
    
    # 2. 清理 Shell 配置文件中的残留别名
    for rc in ~/.bashrc ~/.zshrc; do
        if [ -f "$rc" ]; then
            sed -i '/alias at=/d' "$rc"
            sed -i '/alias ats=/d' "$rc"
            sed -i '/alias anytls=/d' "$rc"
        fi
    done
    
    # 3. 安装当前的正确命令
    cp -f "$0" "$TARGET_BIN"
    chmod +x "$TARGET_BIN"
}

# --- 2. 基础检查 ---
check_root() {
    [[ $EUID -ne 0 ]] && echo -e "${RED}必须使用 root 权限运行！${PLAIN}" && exit 1
}

install_deps() {
    if ! command -v jq &>/dev/null; then
        if command -v apt-get &>/dev/null; then
            apt-get update -y >/dev/null 2>&1
            apt-get install -y curl unzip jq net-tools wget >/dev/null 2>&1
        elif command -v yum &>/dev/null; then
            yum install -y curl unzip jq net-tools wget >/dev/null 2>&1
        fi
    fi
}

# --- 3. 核心功能 ---

# 核心下载/更新
update_core() {
    local target=$1
    clear
    echo -e "${CYAN}正在连接 GitHub API...${PLAIN}"
    
    if [[ -z "$target" ]]; then
        target=$(curl -sL "https://api.github.com/repos/$REPO/releases/latest" | jq -r .tag_name)
    fi

    [[ -z "$target" || "$target" == "null" ]] && echo -e "${RED}获取版本失败${PLAIN}" && return

    ARCH=$(uname -m)
    case $ARCH in
        x86_64|amd64) KW="amd64" ;;
        aarch64|arm64) KW="arm64" ;;
        *) echo -e "${RED}不支持的架构: $ARCH${PLAIN}"; return ;;
    esac

    echo -e "下载核心: ${GREEN}${target}${PLAIN}"
    URL=$(curl -sL "https://api.github.com/repos/$REPO/releases/tags/$target" | jq -r '.assets[] | select(.browser_download_url | contains("linux") and contains("'"$KW"'") and contains(".zip")) | .browser_download_url' | head -n 1)

    wget -q --show-progress -O /tmp/anytls.zip "$URL"
    mkdir -p /tmp/anytls_tmp
    unzip -qo /tmp/anytls.zip -d /tmp/anytls_tmp
    
    BIN=$(find /tmp/anytls_tmp -type f -name "anytls-server" | head -n 1)
    if [[ -n "$BIN" ]]; then
        systemctl stop anytls 2>/dev/null
        mkdir -p "$INSTALL_DIR"
        cp -f "$BIN" "$INSTALL_DIR/anytls-server"
        chmod +x "$INSTALL_DIR/anytls-server"
        echo "$target" > "$VERSION_FILE"
        echo -e "${GREEN}核心已安装/更新${PLAIN}"
    else
        echo -e "${RED}解压失败，未找到核心文件${PLAIN}"
    fi
    rm -rf /tmp/anytls.zip /tmp/anytls_tmp
}

# 修改端口与域名 (无损修改)
modify_config() {
    [[ ! -f "$CONFIG_FILE" ]] && echo -e "${RED}服务未安装${PLAIN}" && return
    source "$CONFIG_FILE"
    
    clear
    echo -e "${BOLD}修改端口与域名${PLAIN}"
    echo -e "当前端口: ${GREEN}${PORT}${PLAIN}"
    echo -e "当前域名: ${GREEN}${SNI}${PLAIN}"
    echo "--------------------------"
    
    read -p "新端口 [回车保持 ${PORT}]: " NEW_PORT
    read -p "新域名 [回车保持 ${SNI}]: " NEW_SNI
    
    [[ -z "$NEW_PORT" ]] && NEW_PORT="$PORT"
    [[ -z "$NEW_SNI" ]] && NEW_SNI="$SNI"
    
    # 1. 写入配置文件
    cat > "$CONFIG_FILE" << EOF
PORT="${NEW_PORT}"
PASSWORD="${PASSWORD}"
SNI="${NEW_SNI}"
EOF

    # 2. 写入 Systemd 服务文件 (更新启动参数)
    cat > "$SERVICE_FILE" << EOF
[Unit]
Description=AnyTLS-Go Server
After=network.target

[Service]
Type=simple
User=root
Nice=-10
ExecStart=${INSTALL_DIR}/anytls-server -l 0.0.0.0:${NEW_PORT} -p "${PASSWORD}"
Restart=always
RestartSec=3
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
EOF

    # 3. 重启生效
    systemctl daemon-reload
    systemctl restart anytls
    echo -e "${GREEN}修改成功！服务已重启。${PLAIN}"
    sleep 2
}

# 首次安装流程
first_install() {
    update_core
    
    clear
    echo -e "${BOLD}初始化配置${PLAIN}"
    read -p "端口 [默认 8443]: " PORT
    [[ -z "$PORT" ]] && PORT=8443
    
    read -p "密码 [默认 随机]: " PASSWORD
    [[ -z "$PASSWORD" ]] && PASSWORD=$(head /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 16)
    
    read -p "伪装域名 [默认 player.live-video.net]: " SNI
    [[ -z "$SNI" ]] && SNI="player.live-video.net"
    
    mkdir -p "$CONFIG_DIR"
    cat > "$CONFIG_FILE" << EOF
PORT="${PORT}"
PASSWORD="${PASSWORD}"
SNI="${SNI}"
EOF

    cat > "$SERVICE_FILE" << EOF
[Unit]
Description=AnyTLS-Go Server
After=network.target

[Service]
Type=simple
User=root
Nice=-10
ExecStart=${INSTALL_DIR}/anytls-server -l 0.0.0.0:${PORT} -p "${PASSWORD}"
Restart=always
RestartSec=3
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable anytls
    systemctl restart anytls
    
    show_result
}

show_result() {
    [[ ! -f "$CONFIG_FILE" ]] && return
    source "$CONFIG_FILE"
    IP=$(curl -s4m5 https://api.ipify.org)
    
    clear
    echo -e "${GREEN}AnyTLS 运行中${PLAIN}"
    echo -e "地址: ${IP}:${PORT}"
    echo -e "SNI:  ${SNI}"
    echo -e "链接: ${CYAN}anytls://${PASSWORD}@${IP}:${PORT}?sni=${SNI}&insecure=1#Node${PLAIN}"
    echo ""
    read -p "按回车返回菜单..."
}

# --- 菜单系统 ---
menu() {
    clear
    # 每次打开菜单都确保修复一次环境
    fix_environment >/dev/null 2>&1
    
    VER=$(cat "$VERSION_FILE" 2>/dev/null || echo "未安装")
    STATUS="${RED}停止${PLAIN}"
    systemctl is-active --quiet anytls && STATUS="${GREEN}运行中${PLAIN}"
    
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${PLAIN}"
    echo -e "           ${BOLD}AnyTLS-Go 面板 (Fix版)${PLAIN}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${PLAIN}"
    echo -e " 状态: ${STATUS}      版本: ${YELLOW}${VER}${PLAIN}"
    echo -e " 快捷键: ${GREEN}anytls${PLAIN} (已修复环境冲突)"
    echo -e "----------------------------------------"
    echo -e " 1. 安装 / 重置"
    echo -e " 2. 查看配置"
    echo -e " 3. 查看日志"
    echo -e " 4. 核心管理"
    echo -e " ${YELLOW}5. 修改端口 & 伪装域名${PLAIN}"
    echo -e ""
    echo -e " 6. 启动      7. 停止"
    echo -e " 8. 重启      9. 卸载"
    echo -e " 0. 退出"
    echo -e "----------------------------------------"
    
    read -p " 选择: " num
    case "$num" in
        1) install_deps; first_install; menu ;;
        2) show_result; menu ;;
        3) journalctl -u anytls -f ;;
        4) update_core; menu ;;
        5) modify_config; menu ;;
        6) systemctl start anytls; menu ;;
        7) systemctl stop anytls; menu ;;
        8) systemctl restart anytls; menu ;;
        9) 
           systemctl stop anytls; systemctl disable anytls
           rm -rf "$INSTALL_DIR" "$CONFIG_DIR" "$TARGET_BIN"
           echo "已卸载"; exit 0 ;;
        0) exit 0 ;;
        *) menu ;;
    esac
}

# --- 运行入口 ---
check_root
# 启动时先修复环境
fix_environment

if [[ "$1" == "install" ]]; then
    install_deps
    first_install
else
    menu
fi
