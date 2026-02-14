#!/bin/bash

# ====================================================
# AnyTLS-Go 管理脚本 (修复快捷键 + 独立配置修改)
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
# 真正的脚本安装路径，不直接叫 at，避免被系统误删
REAL_SCRIPT_PATH="/usr/local/bin/anytls-menu"
INSTALL_DIR="/opt/anytls"
CONFIG_DIR="/etc/anytls"
CONFIG_FILE="${CONFIG_DIR}/server.conf"
VERSION_FILE="${INSTALL_DIR}/version"
SERVICE_FILE="/etc/systemd/system/anytls.service"

# --- 1. 基础检查与快捷键修复 ---
check_root() {
    [[ $EUID -ne 0 ]] && echo -e "${RED}请使用 root 权限运行!${PLAIN}" && exit 1
}

install_tools() {
    if ! command -v jq &>/dev/null; then
        echo "安装必要工具..."
        if command -v apt-get &>/dev/null; then
            apt-get update -y >/dev/null 2>&1
            apt-get install -y curl unzip jq net-tools wget >/dev/null 2>&1
        elif command -v yum &>/dev/null; then
            yum install -y curl unzip jq net-tools wget >/dev/null 2>&1
        fi
    fi
}

# --- 核心：修复 at 快捷键 ---
fix_shortcut() {
    # 1. 将当前脚本内容保存到系统路径
    cat "$0" > "$REAL_SCRIPT_PATH"
    chmod +x "$REAL_SCRIPT_PATH"

    # 2. 暴力写入别名到配置文件
    local shell_rc=""
    if [[ "$SHELL" == */zsh ]]; then
        shell_rc="$HOME/.zshrc"
    else
        shell_rc="$HOME/.bashrc"
    fi

    # 删除旧的 alias at 设置 (防止重复)
    sed -i '/alias at=/d' "$shell_rc" 2>/dev/null
    
    # 写入新的 alias
    echo "alias at='bash $REAL_SCRIPT_PATH'" >> "$shell_rc"

    # 3. 尝试在当前 Shell 临时生效 (虽然子进程无法影响父进程，但尽量尝试)
    alias at="bash $REAL_SCRIPT_PATH"
}

# --- 2. 核心功能逻辑 ---

# 更新/安装核心
update_core() {
    local target=$1
    clear
    echo -e "${CYAN}正在获取最新版本信息...${PLAIN}"
    
    if [[ -z "$target" ]]; then
        target=$(curl -sL "https://api.github.com/repos/anytls/anytls-go/releases/latest" | jq -r .tag_name)
    fi

    [[ -z "$target" || "$target" == "null" ]] && echo -e "${RED}获取版本失败${PLAIN}" && return

    ARCH=$(uname -m)
    case $ARCH in
        x86_64|amd64) KW="amd64" ;;
        aarch64|arm64) KW="arm64" ;;
        *) echo -e "${RED}不支持的架构: $ARCH${PLAIN}"; return ;;
    esac

    echo -e "准备安装版本: ${GREEN}${target}${PLAIN}"
    URL=$(curl -sL "https://api.github.com/repos/anytls/anytls-go/releases/tags/$target" | jq -r '.assets[] | select(.browser_download_url | contains("linux") and contains("'"$KW"'") and contains(".zip")) | .browser_download_url' | head -n 1)

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
        echo -e "${GREEN}核心更新成功!${PLAIN}"
    else
        echo -e "${RED}文件解压失败${PLAIN}"
    fi
    rm -rf /tmp/anytls.zip /tmp/anytls_tmp
}

# 修改端口和域名 (重写)
modify_config() {
    [[ ! -f "$CONFIG_FILE" ]] && echo -e "${RED}请先执行安装!${PLAIN}" && return
    source "$CONFIG_FILE"
    
    clear
    echo -e "${BOLD}=== 修改配置 ===${PLAIN}"
    echo -e "当前端口: ${GREEN}${PORT}${PLAIN}"
    echo -e "当前域名: ${GREEN}${SNI}${PLAIN}"
    echo "------------------------"
    
    read -p "请输入新端口 [回车保持 ${PORT}]: " NEW_PORT
    read -p "请输入新域名 [回车保持 ${SNI}]: " NEW_SNI
    
    # 如果用户直接回车，则使用旧值
    [[ -z "$NEW_PORT" ]] && NEW_PORT="$PORT"
    [[ -z "$NEW_SNI" ]] && NEW_SNI="$SNI"
    
    # 1. 更新配置文件
    cat > "$CONFIG_FILE" << EOF
PORT="${NEW_PORT}"
PASSWORD="${PASSWORD}"
SNI="${NEW_SNI}"
EOF

    # 2. 更新服务文件 (因为端口是写死在启动命令里的)
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

    # 3. 重启应用
    systemctl daemon-reload
    systemctl restart anytls
    
    echo -e "${GREEN}修改成功！正在重启服务...${PLAIN}"
    sleep 2
    show_info
}

# 首次安装配置
first_install() {
    fix_shortcut # 确保快捷键安装
    update_core  # 下载核心
    
    clear
    echo -e "${BOLD}=== 快速初始化 ===${PLAIN}"
    read -p "端口 [默认 8443]: " PORT
    [[ -z "$PORT" ]] && PORT=8443
    
    read -p "密码 [默认 随机]: " PASSWORD
    [[ -z "$PASSWORD" ]] && PASSWORD=$(head /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 16)
    
    read -p "伪装域名 [默认 player.live-video.net]: " SNI
    [[ -z "$SNI" ]] && SNI="player.live-video.net"
    
    mkdir -p "$CONFIG_DIR"
    # 保存配置供后续读取
    cat > "$CONFIG_FILE" << EOF
PORT="${PORT}"
PASSWORD="${PASSWORD}"
SNI="${SNI}"
EOF

    # 写入服务
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
    
    show_info
}

show_info() {
    [[ ! -f "$CONFIG_FILE" ]] && return
    source "$CONFIG_FILE"
    IP=$(curl -s4m5 https://api.ipify.org)
    
    clear
    echo -e "${GREEN}AnyTLS 运行中${PLAIN}"
    echo -e "IP: $IP   端口: $PORT   域名: $SNI"
    echo -e "链接: ${CYAN}anytls://${PASSWORD}@${IP}:${PORT}?sni=${SNI}&insecure=1#Node${PLAIN}"
    echo ""
    read -p "按回车返回菜单..."
}

# --- 3. 菜单系统 ---
menu() {
    clear
    # 每次进入菜单都尝试刷新快捷键逻辑
    fix_shortcut >/dev/null 2>&1
    
    VER=$(cat "$VERSION_FILE" 2>/dev/null || echo "未安装")
    STATUS="${RED}停止${PLAIN}"
    systemctl is-active --quiet anytls && STATUS="${GREEN}运行中${PLAIN}"
    
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${PLAIN}"
    echo -e "           ${BOLD}AnyTLS-Go 面板 V4.0${PLAIN}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${PLAIN}"
    echo -e " 状态: ${STATUS}      核心版本: ${YELLOW}${VER}${PLAIN}"
    echo -e " 快捷键: 输入 ${GREEN}at${PLAIN} 即可唤出本菜单"
    echo -e "----------------------------------------"
    echo -e " 1. 安装 / 重置 (8443 + 域名伪装)"
    echo -e " 2. 查看配置链接"
    echo -e " 3. 查看运行日志"
    echo -e " 4. 核心管理 (升级/降级)"
    echo -e " 5. ${YELLOW}修改端口 & 伪装域名${PLAIN}"
    echo -e ""
    echo -e " 6. 启动服务    7. 停止服务    8. 重启服务"
    echo -e " 9. 卸载脚本    0. 退出"
    echo -e "----------------------------------------"
    
    read -p "请选择: " num
    case "$num" in
        1) install_tools; first_install ;;
        2) show_info ;;
        3) journalctl -u anytls -f ;;
        4) update_core ;;
        5) modify_config ;; # 这里是你要的新入口
        6) systemctl start anytls; menu ;;
        7) systemctl stop anytls; menu ;;
        8) systemctl restart anytls; menu ;;
        9) 
           systemctl stop anytls; systemctl disable anytls
           rm -rf /opt/anytls /etc/anytls /usr/local/bin/anytls-menu
           sed -i '/alias at=/d' ~/.bashrc
           echo "已卸载"; exit 0 ;;
        0) exit 0 ;;
        *) menu ;;
    esac
    menu
}

# --- 入口 ---
check_root
# 如果带参数 install 则直接跑安装流程
if [[ "$1" == "install" ]]; then
    install_tools
    fix_shortcut
    first_install
else
    # 否则进入菜单
    menu
fi
