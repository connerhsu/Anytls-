#!/bin/bash

# ====================================================
# AnyTLS-Go 终极版 (8443 + 自定义SNI + 核心管理 + at快捷键)
# ====================================================

# --- 颜色定义 ---
RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
BLUE='\033[34m'
CYAN='\033[36m'
PLAIN='\033[0m'
BOLD='\033[1m'

# --- 变量定义 ---
REPO="anytls/anytls-go"
INSTALL_DIR="/opt/anytls"
CONFIG_DIR="/etc/anytls"
CONFIG_FILE="${CONFIG_DIR}/server.conf"
VERSION_FILE="${INSTALL_DIR}/version"
SERVICE_FILE="/etc/systemd/system/anytls.service"
BIN_PATH="/usr/local/bin/at"  # 快捷命令直接指向这里

# --- 基础工具 ---
print_info() { echo -e "${CYAN}➜${PLAIN} $1"; }
print_ok()   { echo -e "${GREEN}✔${PLAIN} $1"; }
print_err()  { echo -e "${RED}✖${PLAIN} $1"; }
print_warn() { echo -e "${YELLOW}⚡${PLAIN} $1"; }
print_line() { echo -e "${CYAN}──────────────────────────────────────────────${PLAIN}"; }

# --- 1. 环境准备与快捷键 ---
init_env() {
    [[ $EUID -ne 0 ]] && print_err "请使用 root 权限运行" && exit 1
    
    # 安装依赖
    if command -v apt-get &>/dev/null; then
        apt-get update >/dev/null 2>&1
        apt-get install -y curl unzip jq net-tools iptables wget >/dev/null 2>&1
    elif command -v yum &>/dev/null; then
        yum install -y curl unzip jq net-tools iptables wget >/dev/null 2>&1
    fi

    # 设置快捷键 'at'
    # 将脚本自身复制到 /usr/local/bin/at
    cp "$0" "$BIN_PATH" 2>/dev/null
    chmod +x "$BIN_PATH"
    
    # 写入别名确保万无一失
    for rc in ~/.bashrc ~/.zshrc; do
        if [ -f "$rc" ] && ! grep -q "alias at=" "$rc"; then
            echo "alias at='$BIN_PATH'" >> "$rc"
        fi
    done
}

# --- 2. 核心安装逻辑 ---
install_core() {
    local target_tag=$1
    clear
    print_line
    echo -e " ${BOLD}AnyTLS-Go 核心安装/更新${PLAIN}"
    print_line
    
    # 获取版本号
    if [[ -z "$target_tag" ]]; then
        target_tag=$(curl -sL "https://api.github.com/repos/$REPO/releases/latest" | jq -r .tag_name)
    fi

    [[ -z "$target_tag" || "$target_tag" == "null" ]] && print_err "无法获取 GitHub 版本，请检查网络" && return 1

    # 架构识别
    ARCH=$(uname -m)
    case $ARCH in
        x86_64|amd64) KW_ARCH="amd64" ;;
        aarch64|arm64) KW_ARCH="arm64" ;;
        *) print_err "不支持的架构: $ARCH"; return 1 ;;
    esac

    print_info "正在下载版本: ${GREEN}${target_tag}${PLAIN} ($ARCH)"
    
    URL=$(curl -sL "https://api.github.com/repos/$REPO/releases/tags/$target_tag" | jq -r '.assets[] | select(.browser_download_url | contains("linux") and contains("'"$KW_ARCH"'") and contains(".zip")) | .browser_download_url' | head -n 1)

    if [[ -z "$URL" ]]; then
        print_err "未找到匹配的下载地址"
        return 1
    fi

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
        print_ok "核心安装完成！"
    else
        print_err "解压后未找到二进制文件"
    fi
    rm -rf /tmp/anytls.zip /tmp/anytls_ext
}

# --- 3. 配置生成 ---
configure() {
    clear
    print_line
    echo -e " ${BOLD}AnyTLS 配置向导 (直接回车使用推荐值)${PLAIN}"
    print_line

    read -p ":: 监听端口 [默认 8443]: " PORT
    PORT=${PORT:-8443}

    read -p ":: 连接密码 [默认 随机生成]: " PASSWORD
    PASSWORD=${PASSWORD:-$(head /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 16)}

    read -p ":: 伪装域名 (SNI) [默认 player.live-video.net]: " SNI
    SNI=${SNI:-player.live-video.net}

    mkdir -p "$CONFIG_DIR"
    cat > "$CONFIG_FILE" << EOF
PORT="${PORT}"
PASSWORD="${PASSWORD}"
SNI="${SNI}"
EOF
    chmod 600 "$CONFIG_FILE"

    # Systemd 守护进程
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
    systemctl enable anytls >/dev/null 2>&1
    systemctl restart anytls
}

# --- 4. 核心管理子菜单 ---
menu_core() {
    clear
    local cur=$(cat "$VERSION_FILE" 2>/dev/null || echo "未安装")
    print_line
    echo -e "       ${BOLD}AnyTLS 核心管理${PLAIN}"
    print_line
    echo -e " 当前版本: ${GREEN}${cur}${PLAIN}"
    echo ""
    echo -e " 1. 升级到最新版本"
    echo -e " 2. 重新安装当前版本"
    echo -e " 3. 安装指定版本 (回滚)"
    echo -e " 0. 返回"
    print_line
    read -p " 选择: " c
    case "$c" in
        1) install_core ;;
        2) [[ "$cur" != "未安装" ]] && install_core "$cur" ;;
        3) read -p "输入版本号 (例 v0.1.5): " v && install_core "$v" ;;
        *) return ;;
    esac
}

# --- 5. 信息展示 ---
show_info() {
    [[ ! -f "$CONFIG_FILE" ]] && print_err "尚未安装" && return
    source "$CONFIG_FILE"
    local ip=$(curl -s4m5 https://api.ipify.org || echo "您的VPS_IP")
    local link="anytls://${PASSWORD}@${ip}:${PORT}?sni=${SNI}&insecure=1#AnyTLS_Node"

    clear
    print_line
    echo -e "       ${BOLD}AnyTLS 配置概览${PLAIN}"
    print_line
    echo -e " 节点 IP   : ${GREEN}${ip}${PLAIN}"
    echo -e " 端口      : ${GREEN}${PORT}${PLAIN}"
    echo -e " 密码      : ${GREEN}${PASSWORD}${PLAIN}"
    echo -e " 伪装 SNI  : ${GREEN}${SNI}${PLAIN}"
    echo ""
    echo -e "${BOLD}🔗 分享链接:${PLAIN}"
    echo -e "${CYAN}${link}${PLAIN}"
    echo ""
    echo -e "${BOLD}📝 OpenClash 配置参考:${PLAIN}"
    echo -e "${GREEN}type: anytls, server: ${ip}, port: ${PORT}, password: ${PASSWORD}, sni: ${SNI}, skip-cert-verify: true${PLAIN}"
    print_line
}

# --- 6. 主菜单 ---
main_menu() {
    clear
    local status="${RED}● 已停止${PLAIN}"
    systemctl is-active --quiet anytls && status="${GREEN}● 运行中${PLAIN}"
    local ver=$(cat "$VERSION_FILE" 2>/dev/null || echo "未安装")
    
    if [[ -f "$CONFIG_FILE" ]]; then source "$CONFIG_FILE"; else SNI="未设置"; fi

    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${PLAIN}"
    echo -e "           ${BOLD}AnyTLS-Go 管理面板${PLAIN}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${PLAIN}"
    echo -e " 状态: ${status}   版本: ${YELLOW}${ver}${PLAIN}"
    echo -e " SNI : ${CYAN}${SNI}${PLAIN}   端口: ${YELLOW}${PORT:-N/A}${PLAIN}"
    echo -e " 命令: ${GREEN}at${PLAIN}"
    echo -e "${CYAN}────────────────────────────────────────${PLAIN}"
    echo -e "  ${GREEN}1.${PLAIN} 安装 / 重置 (8443端口+自定义SNI)"
    echo -e "  ${GREEN}2.${PLAIN} 查看配置信息 (导出链接)"
    echo -e "  ${GREEN}3.${PLAIN} 查看实时日志"
    echo -e "  ${CYAN}4.${PLAIN} 核心管理 (升级/回滚)"
    echo -e ""
    echo -e "  ${GREEN}5.${PLAIN} 启动服务      ${YELLOW}6.${PLAIN} 停止服务"
    echo -e "  ${YELLOW}7.${PLAIN} 重启服务      ${RED}8.${PLAIN} 卸载程序"
    echo -e "  ${RED}0.${PLAIN} 退出"
    echo -e "${CYAN}────────────────────────────────────────${PLAIN}"
    
    read -p " 请选择: " choice
    case "$choice" in
        1) init_env; install_core; configure; show_info; read -p "回车继续..." ;;
        2) show_info; read -p "回车继续..." ;;
        3) journalctl -u anytls -f ;;
        4) menu_core ;;
        5) systemctl start anytls ;;
        6) systemctl stop anytls ;;
        7) systemctl restart anytls ;;
        8) uninstall ;;
        0) exit 0 ;;
    esac
    main_menu
}

uninstall() {
    read -p "确定卸载? [y/N]: " res
    if [[ "$res" == "y" ]]; then
        systemctl stop anytls && systemctl disable anytls
        rm -rf "$INSTALL_DIR" "$CONFIG_DIR" "$SERVICE_FILE" "$BIN_PATH"
        sed -i '/alias at=/d' ~/.bashrc 2>/dev/null
        sed -i '/alias at=/d' ~/.zshrc 2>/dev/null
        print_ok "卸载完成，快捷键已移除"
        exit 0
    fi
}

# --- 启动逻辑 ---
if [[ "$1" == "install" ]]; then
    init_env; install_core; configure; show_info
else
    # 每次运行都静默尝试设置一遍快捷键
    [[ ! -f "$BIN_PATH" ]] && init_env > /dev/null 2>&1
    main_menu
fi
