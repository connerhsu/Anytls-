#!/bin/bash
# ====================================================
# AnyTLS-Go 最终修复版 (快捷键: anytls)
# 特性: 修复管道闪退、每次运行强制自更新、增强状态显示、无JQ依赖
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
# ⚠️ 非常重要：请把下面的链接替换为你自己仓库中这个脚本的 Raw 地址！
REPO_URL="https://raw.githubusercontent.com/connerhsu/Anytls-/refs/heads/main/Anytls-Fix.sh"

REPO="anytls/anytls-go"
INSTALL_DIR="/opt/anytls"
CONFIG_DIR="/etc/anytls"
CONFIG_FILE="${CONFIG_DIR}/server.conf"
VERSION_FILE="${INSTALL_DIR}/version"
SERVICE_FILE="/etc/systemd/system/anytls.service"
TARGET_BIN="/usr/local/bin/anytls"

# --- 1. 基础检查 ---
check_root() {
    [[ $EUID -ne 0 ]] && echo -e "${RED}必须使用 root 权限运行！${PLAIN}" && exit 1
}

# --- 2. 自安装与强制更新逻辑 (核心修复) ---
install_global() {
    # 场景1：通过 curl | bash 管道运行
    if [[ "$0" != "$TARGET_BIN" ]]; then
        echo -e "${CYAN}检测到在线运行，正在将脚本安装到系统...${PLAIN}"
        
        # 强制下载并覆盖
        if command -v wget >/dev/null; then wget -qO "$TARGET_BIN" "$REPO_URL"; else curl -sSL -o "$TARGET_BIN" "$REPO_URL"; fi
        
        if [[ ! -s "$TARGET_BIN" ]]; then
            echo -e "${RED}脚本下载失败！请检查 REPO_URL 是否正确或网络是否连通。${PLAIN}"
            exit 1
        fi
        
        chmod +x "$TARGET_BIN"
        
        # 清理旧别名和冲突文件
        rm -f /usr/local/bin/at /usr/local/bin/ats /usr/local/bin/anytls-menu
        for rc in ~/.bashrc ~/.zshrc; do
            if [ -f "$rc" ]; then
                sed -i '/alias at=/d; /alias ats=/d; /alias anytls=/d' "$rc"
            fi
        done
        
        echo -e "${GREEN}安装成功！已绑定系统命令: anytls${PLAIN}"
        sleep 1
        # 移交控制权，强制获取终端输入
        exec bash "$TARGET_BIN" "$@" < /dev/tty
    else
        # 场景2：已经是本地运行 (输入 anytls 唤出时) -> 强制检查更新自身
        local tmp_sh="/tmp/anytls_script_update.sh"
        if command -v wget >/dev/null; then wget -qO "$tmp_sh" "$REPO_URL"; else curl -sSL -o "$tmp_sh" "$REPO_URL"; fi
        
        if [[ -s "$tmp_sh" ]]; then
            # 比较文件是否有变动，如果有则覆盖并重启自身
            if ! cmp -s "$tmp_sh" "$TARGET_BIN"; then
                echo -e "${YELLOW}检测到脚本有新版本，正在自动更新...${PLAIN}"
                cat "$tmp_sh" > "$TARGET_BIN"
                chmod +x "$TARGET_BIN"
                rm -f "$tmp_sh"
                echo -e "${GREEN}脚本更新完毕，正在重新加载菜单...${PLAIN}"
                sleep 1
                exec bash "$TARGET_BIN" "$@" < /dev/tty
            fi
            rm -f "$tmp_sh"
        fi
    fi
}

install_deps() {
    # 移除了 jq，使用系统自带工具即可
    local deps=("curl" "unzip" "net-tools" "wget")
    local missing=()
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &>/dev/null; then missing+=("$dep"); fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        echo -e "${CYAN}正在安装依赖: ${missing[*]}...${PLAIN}"
        if command -v apt-get &>/dev/null; then
            apt-get update -y >/dev/null 2>&1
            apt-get install -y "${missing[@]}" >/dev/null 2>&1
        elif command -v yum &>/dev/null; then
            yum install -y "${missing[@]}" >/dev/null 2>&1
        elif command -v dnf &>/dev/null; then
            dnf install -y "${missing[@]}" >/dev/null 2>&1
        fi
    fi
}

# --- 3. 核心功能 ---

# 核心下载/更新 (无 JQ 依赖版本)
update_core() {
    local target=$1
    clear
    echo -e "${CYAN}正在连接 GitHub API...${PLAIN}"
    
    # 获取最新版本号
    if [[ -z "$target" ]]; then
        target=$(curl -sL "https://api.github.com/repos/$REPO/releases/latest" | grep -o '"tag_name": *"[^"]*"' | head -n 1 | sed 's/"tag_name": "//;s/"//')
    fi

    [[ -z "$target" ]] && echo -e "${RED}获取版本失败，请检查网络环境。${PLAIN}" && return

    ARCH=$(uname -m)
    case $ARCH in
        x86_64|amd64) KW="amd64" ;;
        aarch64|arm64) KW="arm64" ;;
        *) echo -e "${RED}不支持的架构: $ARCH${PLAIN}"; return ;;
    esac

    echo -e "准备下载核心: ${GREEN}${target} (${KW})${PLAIN}"
    
    # 提取下载链接
    URL=$(curl -sL "https://api.github.com/repos/$REPO/releases/tags/$target" | grep -o '"browser_download_url": *"[^"]*"' | grep -i "linux" | grep -i "$KW" | grep -i "\.zip" | head -n 1 | sed 's/"browser_download_url": "//;s/"//')

    if [[ -z "$URL" ]]; then
        echo -e "${RED}未能提取到下载链接，可能该版本无对应架构。${PLAIN}"
        return
    fi

    rm -f /tmp/anytls.zip
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
        echo -e "${GREEN}AnyTLS-Go 核心已成功安装/更新！${PLAIN}"
    else
        echo -e "${RED}解压失败，未找到 anytls-server 核心文件。${PLAIN}"
    fi
    rm -rf /tmp/anytls.zip /tmp/anytls_tmp
}

# 修改端口与域名 (无损修改)
modify_config() {
    [[ ! -f "$CONFIG_FILE" ]] && echo -e "${RED}服务未安装，请先安装。${PLAIN}" && return
    source "$CONFIG_FILE"
    
    clear
    echo -e "${BOLD}=== 修改端口与域名 ===${PLAIN}"
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

    # 2. 写入 Systemd 服务文件
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
    install_deps
    update_core
    
    clear
    echo -e "${BOLD}=== 初始化配置 ===${PLAIN}"
    read -p "端口 [默认 8443]: " PORT
    [[ -z "$PORT" ]] && PORT=8443
    
    read -p "密码 [默认 随机]: " PASSWORD
    [[ -z "$PASSWORD" ]] && PASSWORD=$(head /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 16)
    
    read -p "伪装域名 [默认 mensura.cdn-apple.com]: " SNI
    [[ -z "$SNI" ]] && SNI="mensura.cdn-apple.com"
    
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
    systemctl enable anytls >/dev/null 2>&1
    systemctl restart anytls
    
    show_result
}

show_result() {
    [[ ! -f "$CONFIG_FILE" ]] && echo -e "${RED}尚未配置节点信息。${PLAIN}" && return
    source "$CONFIG_FILE"
    IP=$(curl -s4m5 https://api.ip.sb/ip || curl -s4m5 https://api.ipify.org)
    
    clear
    echo -e "${GREEN}=== AnyTLS 节点信息 ===${PLAIN}"
    echo -e "地址: ${CYAN}${IP}:${PORT}${PLAIN}"
    echo -e "密码: ${CYAN}${PASSWORD}${PLAIN}"
    echo -e "SNI:  ${CYAN}${SNI}${PLAIN}"
    echo -e "\n${YELLOW}专属分享链接:${PLAIN}"
    echo -e "${CYAN}anytls://${PASSWORD}@${IP}:${PORT}?sni=${SNI}&insecure=1#Node${PLAIN}"
    echo ""
    read -p "按回车键返回菜单..."
}

# --- 菜单系统 ---
menu() {
    while true; do
        clear
        VER=$(cat "$VERSION_FILE" 2>/dev/null || echo "未安装")
        
        # 获取状态与配置用于菜单展示
        STATUS="${RED}● 停止${PLAIN}"
        SHOW_PORT="N/A"
        SHOW_SNI="N/A"
        
        if systemctl is-active --quiet anytls; then 
            STATUS="${GREEN}● 运行中${PLAIN}"
        fi
        
        if [[ -f "$CONFIG_FILE" ]]; then
            source "$CONFIG_FILE"
            SHOW_PORT=$PORT
            SHOW_SNI=$SNI
        fi
        
        echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${PLAIN}"
        echo -e "           ${BOLD}AnyTLS-Go 管理面板${PLAIN}"
        echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${PLAIN}"
        echo -e " 状态: ${STATUS}      核心版本: ${YELLOW}${VER}${PLAIN}"
        echo -e " 端口: ${GREEN}${SHOW_PORT}${PLAIN}        伪装域名: ${GREEN}${SHOW_SNI}${PLAIN}"
        echo -e " 快捷键: ${GREEN}anytls${PLAIN} (自动检测更新已启用)"
        echo -e "----------------------------------------"
        echo -e " ${GREEN}1.${PLAIN} 安装 / 重置 AnyTLS"
        echo -e " ${GREEN}2.${PLAIN} 查看节点配置 & 链接"
        echo -e " ${GREEN}3.${PLAIN} 查看运行日志"
        echo -e " ${GREEN}4.${PLAIN} 更新/降级核心版本"
        echo -e " ${YELLOW}5.${PLAIN} 修改端口与伪装域名"
        echo -e "----------------------------------------"
        echo -e " ${CYAN}6.${PLAIN} 启动      ${CYAN}7.${PLAIN} 停止"
        echo -e " ${CYAN}8.${PLAIN} 重启      ${RED}9.${PLAIN} 完全卸载"
        echo -e " ${GREEN}0.${PLAIN} 退出"
        echo -e "----------------------------------------"
        
        read -p " 请选择数字 [0-9]: " num
        case "$num" in
            1) first_install ;;
            2) show_result ;;
            3) echo "按 Ctrl+C 退出日志查看"; journalctl -u anytls -f ;;
            4) update_core; sleep 2 ;;
            5) modify_config ;;
            6) systemctl start anytls; echo -e "${GREEN}已启动${PLAIN}"; sleep 1 ;;
            7) systemctl stop anytls; echo -e "${RED}已停止${PLAIN}"; sleep 1 ;;
            8) systemctl restart anytls; echo -e "${GREEN}已重启${PLAIN}"; sleep 1 ;;
            9) 
               systemctl stop anytls; systemctl disable anytls >/dev/null 2>&1
               rm -rf "$INSTALL_DIR" "$CONFIG_DIR" "$TARGET_BIN" /etc/systemd/system/anytls.service
               systemctl daemon-reload
               echo -e "${GREEN}已完全卸载！${PLAIN}"
               exit 0 ;;
            0) exit 0 ;;
            *) ;;
        esac
    done
}

# --- 运行入口 ---
check_root
install_global "$@" # 保证环境与更新
menu
