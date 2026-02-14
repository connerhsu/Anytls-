#!/bin/bash

# ====================================================
# AnyTLS-Go 终极管理版 V3.0
# ====================================================

# --- 颜色与样式 ---
RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
BLUE='\033[34m'
CYAN='\033[36m'
PLAIN='\033[0m'
BOLD='\033[1m'

# --- 核心路径 ---
REPO="anytls/anytls-go"
INSTALL_DIR="/opt/anytls"
CONFIG_DIR="/etc/anytls"
CONFIG_FILE="${CONFIG_DIR}/server.conf"
VERSION_FILE="${INSTALL_DIR}/version"
SERVICE_FILE="/etc/systemd/system/anytls.service"
AT_BIN="/usr/local/bin/at"

# --- 基础工具 ---
print_info() { echo -e "${CYAN}➜${PLAIN} $1"; }
print_ok()   { echo -e "${GREEN}✔${PLAIN} $1"; }
print_err()  { echo -e "${RED}✖${PLAIN} $1"; }
print_warn() { echo -e "${YELLOW}⚡${PLAIN} $1"; }
print_line() { echo -e "${CYAN}──────────────────────────────────────────────${PLAIN}"; }

# --- 1. 环境初始化与强制快捷键 ---
init_at() {
    [[ $EUID -ne 0 ]] && print_err "请使用 root 权限运行" && exit 1
    
    # 安装必要组件
    if command -v apt-get &>/dev/null; then
        apt-get update >/dev/null 2>&1
        apt-get install -y curl unzip jq net-tools iptables wget >/dev/null 2>&1
    elif command -v yum &>/dev/null; then
        yum install -y curl unzip jq net-tools iptables wget >/dev/null 2>&1
    fi

    # 1. 物理链接：直接把脚本拷贝到系统二进制路径
    cp -f "$0" "$AT_BIN"
    chmod +x "$AT_BIN"
    
    # 2. 别名保障：写入 shell 配置文件
    for rc in ~/.bashrc ~/.zshrc; do
        if [ -f "$rc" ]; then
            sed -i '/alias at=/d' "$rc"
            echo "alias at='$AT_BIN'" >> "$rc"
        fi
    done
}

# --- 2. 修改配置入口 (新增) ---
modify_config() {
    [[ ! -f "$CONFIG_FILE" ]] && print_err "请先执行安装！" && return
    source "$CONFIG_FILE"
    
    clear
    print_line
    echo -e "       ${BOLD}修改 AnyTLS 配置${PLAIN}"
    print_line
    echo -e " 当前端口: ${YELLOW}${PORT}${PLAIN}"
    echo -e " 当前 SNI : ${YELLOW}${SNI}${PLAIN}"
    echo ""
    
    read -p "请输入新端口 [直接回车不修改]: " NEW_PORT
    PORT=${NEW_PORT:-$PORT}
    
    read -p "请输入新 SNI [直接回车不修改]: " NEW_SNI
    SNI=${NEW_SNI:-$SNI}
    
    # 保存新配置
    cat > "$CONFIG_FILE" << EOF
PORT="${PORT}"
PASSWORD="${PASSWORD}"
SNI="${SNI}"
EOF
    
    # 更新 Systemd 执行命令
    sed -i "s|ExecStart=.*|ExecStart=${INSTALL_DIR}/anytls-server -l 0.0.0.0:${PORT} -p \"${PASSWORD}\"|" "$SERVICE_FILE"
    
    systemctl daemon-reload
    systemctl restart anytls
    print_ok "配置修改成功并已重启服务！"
    sleep 2
}

# --- 3. 核心安装逻辑 ---
install_core() {
    local target_tag=$1
    clear
    print_line
    echo -e " ${BOLD}AnyTLS-Go 核心安装/更新${PLAIN}"
    print_line
    
    target_tag=$(curl -sL "https://api.github.com/repos/$REPO/releases/latest" | jq -r .tag_name)
    [[ -z "$target_tag" || "$target_tag" == "null" ]] && print_err "网络异常，请检查 GitHub 连通性" && return 1

    ARCH=$(uname -m)
    case $ARCH in
        x86_64|amd64) KW_ARCH="amd64" ;;
        aarch64|arm64) KW_ARCH="arm64" ;;
        *) print_err "不支持的架构: $ARCH"; return 1 ;;
    esac

    print_info "正在下载版本: ${GREEN}${target_tag}${PLAIN}"
    URL=$(curl -sL "https://api.github.com/repos/$REPO/releases/tags/$target_tag" | jq -r '.assets[] | select(.browser_download_url | contains("linux") and contains("'"$KW_ARCH"'") and contains(".zip")) | .browser_download_url' | head -n 1)

    wget -q --show-progress -O "/tmp/anytls.zip" "$URL"
    mkdir -p /tmp/anytls_ext
    unzip -qo "/tmp/anytls.zip" -d /tmp/anytls_ext
    
    BIN=$(find /tmp/anytls_ext -type f -name "anytls-server" | head -n 1)
    if [[ -n "$BIN" ]]; then
        systemctl stop anytls 2>/dev/null
        mkdir -p "$INSTALL_DIR"
        cp -f "$BIN" "$INSTALL_DIR/anytls-server"
        chmod +x "$INSTALL_DIR/anytls-server"
        echo "$target_tag" > "$VERSION_FILE"
        print_ok "核心部署成功"
    fi
    rm -rf /tmp/anytls.zip /tmp/anytls_ext
}

# --- 4. 首次安装向导 ---
configure_first() {
    clear
    print_line
    echo -e " ${BOLD}AnyTLS 首次配置 (回车使用默认)${PLAIN}"
    print_line
    read -p ":: 端口 [默认 8443]: " PORT
    PORT=${PORT:-8443}
    read -p ":: 密码 [默认 随机]: " PASSWORD
    PASSWORD=${PASSWORD:-$(head /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 16)}
    read -p ":: SNI  [默认 player.live-video.net]: " SNI
    SNI=${SNI:-player.live-video.net}

    mkdir -p "$CONFIG_DIR"
    echo -e "PORT=\"${PORT}\"\nPASSWORD=\"${PASSWORD}\"\nSNI=\"${SNI}\"" > "$CONFIG_FILE"
    
    cat > "$SERVICE_FILE" << EOF
[Unit]
Description=AnyTLS-Go Server
After=network.target
[Service]
Type=simple
User=root
ExecStart=${INSTALL_DIR}/anytls-server -l 0.0.0.0:${PORT} -p "${PASSWORD}"
Restart=always
LimitNOFILE=1000000
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable anytls && systemctl restart anytls
}

# --- 5. 主菜单 ---
main_menu() {
    clear
    local status="${RED}● 已停止${PLAIN}"
    systemctl is-active --quiet anytls && status="${GREEN}● 运行中${PLAIN}"
    local ver=$(cat "$VERSION_FILE" 2>/dev/null || echo "未安装")
    [[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"

    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${PLAIN}"
    echo -e "           ${BOLD}AnyTLS-Go 管理面板${PLAIN}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${PLAIN}"
    echo -e " 状态: ${status}   版本: ${YELLOW}${ver}${PLAIN}"
    echo -e " 域名: ${CYAN}${SNI:-未设置}${PLAIN}   端口: ${YELLOW}${PORT:-N/A}${PLAIN}"
    echo -e " 命令: ${GREEN}at${PLAIN}"
    echo -e "${CYAN}────────────────────────────────────────${PLAIN}"
    echo -e "  ${GREEN}1.${PLAIN} 安装 / 重置配置"
    echo -e "  ${GREEN}2.${PLAIN} 查看配置 (分享链接/YAML)"
    echo -e "  ${GREEN}3.${PLAIN} 查看实时日志"
    echo -e "  ${CYAN}4.${PLAIN} 核心管理 (升级/回滚)"
    echo -e "  ${BLUE}5.${PLAIN} 修改端口与域名 (快捷入口)"
    echo -e ""
    echo -e "  ${GREEN}6.${PLAIN} 启动服务      ${YELLOW}7.${PLAIN} 停止服务"
    echo -e "  ${YELLOW}8.${PLAIN} 重启服务      ${RED}9.${PLAIN} 卸载程序"
    echo -e "  ${RED}0.${PLAIN} 退出"
    echo -e "${CYAN}────────────────────────────────────────${PLAIN}"
    
    read -p " 请选择: " choice
    case "$choice" in
        1) init_at; install_core; configure_first; main_menu ;;
        2) source "$CONFIG_FILE"
           local ip=$(curl -s4m5 https://api.ipify.org)
           clear
           print_line
           echo -e " 分享链接: ${CYAN}anytls://${PASSWORD}@${ip}:${PORT}?sni=${SNI}&insecure=1#Node${PLAIN}"
           print_line
           read -p "回车返回..." ;;
        3) journalctl -u anytls -f ;;
        4) install_core; main_menu ;;
        5) modify_config; main_menu ;;
        6) systemctl start anytls; main_menu ;;
        7) systemctl stop anytls; main_menu ;;
        8) systemctl restart anytls; main_menu ;;
        9) uninstall ;;
        0) exit 0 ;;
        *) main_menu ;;
    esac
}

uninstall() {
    read -p "确定卸载? [y/N]: " res
    if [[ "$res" == "y" ]]; then
        systemctl stop anytls && systemctl disable anytls
        rm -rf "$INSTALL_DIR" "$CONFIG_DIR" "$SERVICE_FILE" "$AT_BIN"
        print_ok "卸载完成！"
        exit 0
    fi
}

# --- 运行入口 ---
init_at > /dev/null 2>&1
main_menu
