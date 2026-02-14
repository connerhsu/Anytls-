#!/bin/bash

# ====================================================
# AnyTLS-Go 终极管理脚本 V5.0 (快捷键: ats)
# ====================================================

# --- 颜色定义 ---
RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
BLUE='\033[34m'
CYAN='\033[36m'
PLAIN='\033[0m'
BOLD='\033[1m'

# --- 变量与路径 ---
REPO="anytls/anytls-go"
INSTALL_DIR="/opt/anytls"
CONFIG_DIR="/etc/anytls"
CONFIG_FILE="${CONFIG_DIR}/server.conf"
VERSION_FILE="${INSTALL_DIR}/version"
SERVICE_FILE="/etc/systemd/system/anytls.service"

# 这里是新的快捷键命令路径
SHORTCUT_NAME="ats"
SHORTCUT_BIN="/usr/local/bin/${SHORTCUT_NAME}"

# --- 基础函数 ---
print_info() { echo -e "${CYAN}➜${PLAIN} $1"; }
print_ok()   { echo -e "${GREEN}✔${PLAIN} $1"; }
print_err()  { echo -e "${RED}✖${PLAIN} $1"; }

check_root() {
    [[ $EUID -ne 0 ]] && print_err "必须使用 root 权限运行此脚本！" && exit 1
}

# --- 核心：配置快捷键 ats ---
setup_shortcut() {
    # 1. 物理复制脚本到 /usr/local/bin/ats
    # 这样直接输入 ats 就能运行，不需要依赖 alias
    cp -f "$0" "$SHORTCUT_BIN"
    chmod +x "$SHORTCUT_BIN"

    # 2. 为了保险，同时配置 Alias (适配部分特殊环境)
    # 并清理旧的 'at' 别名
    for rc in ~/.bashrc ~/.zshrc; do
        if [ -f "$rc" ]; then
            # 清理旧的 at 别名
            sed -i '/alias at=/d' "$rc" 
            # 清理旧的 ats 别名 (防止重复)
            sed -i "/alias ${SHORTCUT_NAME}=/d" "$rc"
            # 添加新的 ats 别名
            echo "alias ${SHORTCUT_NAME}='${SHORTCUT_BIN}'" >> "$rc"
        fi
    done
}

# --- 安装依赖 ---
install_deps() {
    if ! command -v jq &>/dev/null; then
        print_info "安装依赖组件 (curl, unzip, jq)..."
        if command -v apt-get &>/dev/null; then
            apt-get update -y >/dev/null 2>&1
            apt-get install -y curl unzip jq net-tools wget >/dev/null 2>&1
        elif command -v yum &>/dev/null; then
            yum install -y curl unzip jq net-tools wget >/dev/null 2>&1
        fi
    fi
}

# --- 核心逻辑：安装/更新 ---
update_core() {
    local target=$1
    clear
    print_info "正在查询最新版本..."
    
    if [[ -z "$target" ]]; then
        target=$(curl -sL "https://api.github.com/repos/$REPO/releases/latest" | jq -r .tag_name)
    fi

    [[ -z "$target" || "$target" == "null" ]] && print_err "无法连接 GitHub API" && return

    ARCH=$(uname -m)
    case $ARCH in
        x86_64|amd64) KW="amd64" ;;
        aarch64|arm64) KW="arm64" ;;
        *) print_err "不支持的 CPU 架构: $ARCH"; return ;;
    esac

    print_info "下载核心: ${GREEN}${target}${PLAIN}"
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
        print_ok "核心部署完成"
    else
        print_err "核心文件损坏"
    fi
    rm -rf /tmp/anytls.zip /tmp/anytls_tmp
}

# --- 功能：修改配置 (你要求的入口) ---
modify_config() {
    [[ ! -f "$CONFIG_FILE" ]] && print_err "请先安装服务！" && return
    source "$CONFIG_FILE"
    
    clear
    print_info "当前配置："
    echo -e " 端口: ${GREEN}${PORT}${PLAIN}"
    echo -e " 域名: ${GREEN}${SNI}${PLAIN}"
    echo "--------------------------------"
    
    read -p "请输入新端口 [回车保持 ${PORT}]: " NEW_PORT
    read -p "请输入新域名 [回车保持 ${SNI}]: " NEW_SNI
    
    [[ -z "$NEW_PORT" ]] && NEW_PORT="$PORT"
    [[ -z "$NEW_SNI" ]] && NEW_SNI="$SNI"
    
    # 1. 更新配置文件
    cat > "$CONFIG_FILE" << EOF
PORT="${NEW_PORT}"
PASSWORD="${PASSWORD}"
SNI="${NEW_SNI}"
EOF

    # 2. 更新 Systemd 服务文件 (核心启动参数需要变动)
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
    print_ok "配置已更新，服务已重启！"
    sleep 2
}

# --- 功能：首次安装 ---
first_install() {
    setup_shortcut # 设置 ats
    update_core    # 下载核心
    
    clear
    echo -e "${BOLD}AnyTLS 快速初始化${PLAIN}"
    
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

    # 生成服务文件
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

# --- 展示信息 ---
show_result() {
    [[ ! -f "$CONFIG_FILE" ]] && return
    source "$CONFIG_FILE"
    IP=$(curl -s4m5 https://api.ipify.org)
    [[ -z "$IP" ]] && IP="VPS_IP"
    
    clear
    echo -e "${GREEN}AnyTLS 运行中${PLAIN}"
    echo -e "IP: $IP   端口: $PORT   SNI: $SNI"
    echo -e "分享链接: ${CYAN}anytls://${PASSWORD}@${IP}:${PORT}?sni=${SNI}&insecure=1#AnyTLS${PLAIN}"
    echo ""
    read -p "按回车返回菜单..."
}

# --- 主菜单 ---
menu() {
    clear
    # 每次进入菜单都尝试修复一下快捷键，确保 ats 可用
    setup_shortcut >/dev/null 2>&1
    
    VER=$(cat "$VERSION_FILE" 2>/dev/null || echo "未安装")
    STATUS="${RED}停止${PLAIN}"
    systemctl is-active --quiet anytls && STATUS="${GREEN}运行中${PLAIN}"
    
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${PLAIN}"
    echo -e "           ${BOLD}AnyTLS-Go 面板 V5.0${PLAIN}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${PLAIN}"
    echo -e " 状态: ${STATUS}      版本: ${YELLOW}${VER}${PLAIN}"
    echo -e " 快捷键: ${GREEN}ats${PLAIN}"
    echo -e "----------------------------------------"
    echo -e "  1. 安装 / 重置配置"
    echo -e "  2. 查看配置信息"
    echo -e "  3. 查看运行日志"
    echo -e "  4. 核心管理 (升级/降级)"
    echo -e "  ${YELLOW}5. 修改端口 & 伪装域名${PLAIN} (常用)"
    echo -e ""
    echo -e "  6. 启动服务    7. 停止服务"
    echo -e "  8. 重启服务    9. 卸载脚本"
    echo -e "  0. 退出"
    echo -e "----------------------------------------"
    
    read -p " 请选择: " num
    case "$num" in
        1) install_deps; first_install; menu ;;
        2) show_result; menu ;;
        3) journalctl -u anytls -f ;;
        4) update_core; menu ;;
        5) modify_config; menu ;; # 快捷入口
        6) systemctl start anytls; print_ok "启动命令已发送"; sleep 1; menu ;;
        7) systemctl stop anytls; print_ok "停止命令已发送"; sleep 1; menu ;;
        8) systemctl restart anytls; print_ok "重启命令已发送"; sleep 1; menu ;;
        9) 
           systemctl stop anytls; systemctl disable anytls
           rm -rf "$INSTALL_DIR" "$CONFIG_DIR" "$SHORTCUT_BIN"
           sed -i "/alias ${SHORTCUT_NAME}=/d" ~/.bashrc
           print_ok "卸载完成"; exit 0 ;;
        0) exit 0 ;;
        *) menu ;;
    esac
}

# --- 入口处理 ---
check_root
if [[ "$1" == "install" ]]; then
    install_deps
    setup_shortcut
    first_install
else
    setup_shortcut >/dev/null 2>&1
    menu
fi
