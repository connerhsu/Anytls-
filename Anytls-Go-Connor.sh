#!/bin/bash

# ====================================================
# AnyTLS-Go 终极管理版 (默认 8443 + 自定义 SNI + 核心管理 + at 快捷键)
# ====================================================

# --- 视觉与颜色 ---
RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
BLUE='\033[34m'
CYAN='\033[36m'
PLAIN='\033[0m'
BOLD='\033[1m'

# --- 全局变量 ---
REPO="anytls/anytls-go"
INSTALL_DIR="/opt/anytls"
CONFIG_DIR="/etc/anytls"
CONFIG_FILE="${CONFIG_DIR}/server.conf"
VERSION_FILE="${INSTALL_DIR}/version"
SERVICE_FILE="/etc/systemd/system/anytls.service"
SHORTCUT_BIN="/usr/local/bin/anytls" # 统一存放路径
GAI_CONF="/etc/gai.conf"

# --- 辅助函数 ---
print_info() { echo -e "${CYAN}➜${PLAIN} $1"; }
print_ok()   { echo -e "${GREEN}✔${PLAIN} $1"; }
print_err()  { echo -e "${RED}✖${PLAIN} $1"; }
print_warn() { echo -e "${YELLOW}⚡${PLAIN} $1"; }
print_line() { echo -e "${CYAN}──────────────────────────────────────────────${PLAIN}"; }

# --- 1. 系统与快捷键设置 ---
check_sys() {
    [[ $EUID -ne 0 ]] && print_err "请使用 root 运行" && exit 1
}

# 设置 'at' 快捷键
set_alias() {
    # 将脚本复制到系统路径
    cp "$0" "$SHORTCUT_BIN" 2>/dev/null
    chmod +x "$SHORTCUT_BIN"
    
    # 检查是否已经设置了 alias
    if ! grep -q "alias at=" ~/.bashrc; then
        echo "alias at='$SHORTCUT_BIN'" >> ~/.bashrc
        print_ok "已添加快捷键 'at' 到 ~/.bashrc"
    fi
    
    # 如果存在 zsh
    if [ -f ~/.zshrc ] && ! grep -q "alias at=" ~/.zshrc; then
        echo "alias at='$SHORTCUT_BIN'" >> ~/.zshrc
        print_ok "已添加快捷键 'at' 到 ~/.zshrc"
    fi
    
    # 提醒用户生效
    print_info "快捷键设置完毕。下次登录或执行 'source ~/.bashrc' 后即可输入 'at' 呼出面板。"
}

install_deps() {
    print_info "安装必要依赖..."
    if command -v apt-get &>/dev/null; then
        apt-get update >/dev/null 2>&1
        apt-get install -y curl unzip jq net-tools iptables >/dev/null 2>&1
    elif command -v yum &>/dev/null; then
        yum install -y curl unzip jq net-tools iptables >/dev/null 2>&1
    fi
}

# --- 2. 核心安装逻辑 ---
install_core() {
    local target_tag=$1
    clear
    print_line
    echo -e " ${BOLD}AnyTLS-Go 核心管理${PLAIN}"
    print_line
    
    if [[ -z "$target_tag" ]]; then
        print_info "正在获取远程最新版本号..."
        target_tag=$(curl -sL "https://api.github.com/repos/$REPO/releases/latest" | jq -r .tag_name)
    fi

    [[ -z "$target_tag" || "$target_tag" == "null" ]] && print_err "获取版本失败" && return 1

    ARCH=$(uname -m)
    case $ARCH in
        x86_64|amd64) KW_ARCH="amd64" ;;
        aarch64|arm64) KW_ARCH="arm64" ;;
        *) print_err "不支持架构: $ARCH"; return 1 ;;
    esac

    print_info "准备安装版本: ${GREEN}${target_tag}${PLAIN}"
    DOWNLOAD_URL=$(curl -sL "https://api.github.com/repos/$REPO/releases/tags/$target_tag" | jq -r '.assets[] | select(.browser_download_url | contains("linux") and contains("'"$KW_ARCH"'") and contains(".zip")) | .browser_download_url' | head -n 1)

    if [[ -z "$DOWNLOAD_URL" ]]; then
        print_err "未找到适配该架构的下载包"
        return 1
    fi

    print_info "正在下载..."
    wget -q --show-progress -O "/tmp/anytls.zip" "$DOWNLOAD_URL"
    
    mkdir -p /tmp/anytls_extract
    unzip -qo "/tmp/anytls.zip" -d /tmp/anytls_extract
    FOUND_BIN=$(find /tmp/anytls_extract -type f -name "anytls-server" | head -n 1)

    if [[ -n "$FOUND_BIN" ]]; then
        systemctl stop anytls 2>/dev/null
        mkdir -p "$INSTALL_DIR"
        cp -f "$FOUND_BIN" "$INSTALL_DIR/anytls-server"
        chmod +x "$INSTALL_DIR/anytls-server"
        echo "$target_tag" > "$VERSION_FILE"
        print_ok "版本 ${target_tag} 安装成功"
    else
        print_err "安装失败：核心文件未找到"
    fi

    rm -rf /tmp/anytls.zip /tmp/anytls_extract
    if [[ -f "$CONFIG_FILE" ]]; then systemctl restart anytls 2>/dev/null; fi
}

# --- 3. 配置向导 ---
configure() {
    clear
    print_line
    echo -e " ${BOLD}配置向导${PLAIN}"
    print_line

    read -p "$(echo -e "${CYAN}::${PLAIN} 监听端口 [回车默认 8443]: ")" PORT
    [[ -z "${PORT}" ]] && PORT=8443

    read -p "$(echo -e "${CYAN}::${PLAIN} 连接密码 [回车随机]: ")" PASSWORD
    [[ -z "${PASSWORD}" ]] && PASSWORD=$(head /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 16)

    read -p "$(echo -e "${CYAN}::${PLAIN} 伪装域名 (SNI) [回车默认 player.live-video.net]: ")" CUSTOM_SNI
    [[ -z "${CUSTOM_SNI}" ]] && CUSTOM_SNI="player.live-video.net"

    cat > "$CONFIG_FILE" << EOF
PORT="${PORT}"
PASSWORD="${PASSWORD}"
SNI="${CUSTOM_SNI}"
EOF
    chmod 600 "$CONFIG_FILE"

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

# --- 4. 核心管理菜单 ---
menu_core_manage() {
    clear
    local local_v=$(cat "$VERSION_FILE" 2>/dev/null || echo "未安装")
    print_line
    echo -e "       ${BOLD}AnyTLS 核心管理${PLAIN}"
    print_line
    echo -e " 当前本地版本: ${GREEN}${local_v}${PLAIN}"
    echo ""
    echo -e " 1. 检查并更新至最新版本"
    echo -e " 2. 强制重新安装当前版本"
    echo -e " 3. 安装/回滚特定版本 (输入版本号)"
    echo -e " 0. 返回主菜单"
    print_line
    read -p " 请选择: " core_choice
    case "$core_choice" in
        1) install_core ;;
        2) [[ "$local_v" == "未安装" ]] && print_err "未安装核心" || install_core "$local_v" ;;
        3) read -p "请输入版本号 (例如 v0.1.5): " custom_v
           [[ -n "$custom_v" ]] && install_core "$custom_v" ;;
        0) return ;;
        *) menu_core_manage ;;
    esac
    read -p "按回车返回..."
}

# --- 5. 展示结果 ---
show_result() {
    [[ ! -f "$CONFIG_FILE" ]] && print_err "配置文件不存在" && return
    source "$CONFIG_FILE"
    local ip=$(curl -s4m5 https://api.ipify.org || echo "VPS_IP")
    local link="anytls://${PASSWORD}@${ip}:${PORT}?sni=${SNI}&insecure=1#AnyTLS"

    clear
    print_line
    echo -e "       AnyTLS 配置详情"
    print_line
    echo -e " 节点 IP   : ${GREEN}${ip}${PLAIN}"
    echo -e " 端口      : ${GREEN}${PORT}${PLAIN}"
    echo -e " 密码      : ${GREEN}${PASSWORD}${PLAIN}"
    echo -e " 伪装 SNI  : ${GREEN}${SNI}${PLAIN}"
    echo ""
    echo -e "${BOLD} 🔗 链接:${PLAIN}"
    echo -e "${CYAN}${link}${PLAIN}"
    echo ""
    echo -e "${BOLD} 📝 YAML 配置 (OpenClash):${PLAIN}"
    echo -e "${GREEN}"
    cat << EOF
  - name: "AnyTLS"
    type: anytls
    server: "${ip}"
    port: ${PORT}
    password: "${PASSWORD}"
    sni: "${SNI}"
    skip-cert-verify: true
    udp: true
EOF
    echo -e "${PLAIN}"
    print_line
}

# --- 6. 主菜单 ---
show_menu() {
    clear
    local status_color="${RED}● 已停止${PLAIN}"
    systemctl is-active --quiet anytls && status_color="${GREEN}● 运行中${PLAIN}"
    local local_v=$(cat "$VERSION_FILE" 2>/dev/null || echo "未安装")
    if [[ -f "$CONFIG_FILE" ]]; then source "$CONFIG_FILE"; else SNI="未配置"; fi

    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${PLAIN}"
    echo -e "           ${BOLD}AnyTLS-Go 管理面板${PLAIN}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${PLAIN}"
    echo -e " 状态: ${status_color}  版本: ${YELLOW}${local_v}${PLAIN}"
    echo -e " 端口: ${YELLOW}${PORT:-未设置}${PLAIN}      SNI: ${CYAN}${SNI}${PLAIN}"
    echo -e " 快捷键: ${GREEN}at${PLAIN}"
    echo -e "${CYAN}────────────────────────────────────────${PLAIN}"
    echo -e "  ${GREEN}1.${PLAIN}  快速安装/重置配置"
    echo -e "  ${GREEN}2.${PLAIN}  查看配置信息"
    echo -e "  ${GREEN}3.${PLAIN}  查看实时日志"
    echo -e "  ${CYAN}4.${PLAIN}  核心管理 (升级/降级/重装)"
    echo -e ""
    echo -e "  ${GREEN}5.${PLAIN}  启动服务"
    echo -e "  ${YELLOW}6.${PLAIN}  停止服务"
    echo -e "  ${YELLOW}7.${PLAIN}  重启服务"
    echo -e ""
    echo -e "  ${RED}8.${PLAIN}  卸载程序"
    echo -e "  ${RED}0.${PLAIN}  退出脚本"
    echo -e "${CYAN}────────────────────────────────────────${PLAIN}"
    
    read -p " 请选择: " num
    case "$num" in
        1) check_sys; install_deps; install_core; configure; set_alias; show_result; read -p "回车返回..." ;;
        2) show_result; read -p "回车返回..." ;;
        3) journalctl -u anytls -f ;;
        4) menu_core_manage ;;
        5) systemctl start anytls; print_ok "已尝试启动" ; sleep 1 ;;
        6) systemctl stop anytls; print_warn "服务已停止" ; sleep 1 ;;
        7) systemctl restart anytls; print_ok "已尝试重启" ; sleep 1 ;;
        8) uninstall ;;
        0) exit 0 ;;
        *) show_menu ;;
    esac
    show_menu
}

uninstall() {
    read -p "确定要卸载吗? [y/N]: " confirm
    if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
        systemctl stop anytls && systemctl disable anytls
        rm -rf "$INSTALL_DIR" "$CONFIG_DIR" "$SERVICE_FILE" "$SHORTCUT_BIN"
        sed -i '/alias at=/d' ~/.bashrc 2>/dev/null
        sed -i '/alias at=/d' ~/.zshrc 2>/dev/null
        print_ok "卸载成功，快捷键已移除"
    fi
}

# 脚本运行入口
check_sys
if [[ ! -f "$CONFIG_FILE" || "$1" == "install" ]]; then
    # 首次运行或强制安装
    install_deps
    install_core
    configure
    set_alias
    show_result
else
    # 正常进入菜单前确保 alias 已存在
    set_alias > /dev/null 2>&1
    show_menu
fi
