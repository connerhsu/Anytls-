#!/bin/bash
# ====================================================
# AnyTLS-Go 最终修复版 (BBR + 随机混淆 + 管道运行兼容)
# ====================================================

# --- 颜色定义 ---
RED='\033[31m'; GREEN='\033[32m'; YELLOW='\033[33m'; BLUE='\033[34m'; CYAN='\033[36m'; PLAIN='\033[0m'; BOLD='\033[1m'

# --- 路径配置 ---
REPO_URL="https://raw.githubusercontent.com/connerhsu/Anytls-/main/Anytls-Fix.sh"
INSTALL_DIR="/opt/anytls"; CONFIG_DIR="/etc/anytls"
CONFIG_FILE="${CONFIG_DIR}/server.conf"; VERSION_FILE="${INSTALL_DIR}/version"
SERVICE_FILE="/etc/systemd/system/anytls.service"; TARGET_BIN="/usr/local/bin/anytls"

# --- 1. 基础环境与 BBR ---
check_root() {
    [[ $EUID -ne 0 ]] && echo -e "${RED}错误: 必须使用 root 运行${PLAIN}" && exit 1
}

enable_bbr() {
    echo -e "${CYAN}正在检查 BBR 状态...${PLAIN}"
    if sysctl net.ipv4.tcp_congestion_control | grep -q "bbr"; then
        echo -e "${GREEN}BBR 已经开启。${PLAIN}"
    else
        echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
        echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
        sysctl -p >/dev/null 2>&1
        echo -e "${GREEN}BBR 开启成功！${PLAIN}"
    fi
}

# --- 2. 随机混淆生成器 ---
generate_padding_json() {
    local stop=$((6 + RANDOM % 8))
    local r1=$((80 + RANDOM % 150)); local r2=$((300 + RANDOM % 400)); local r3=$((500 + RANDOM % 500))
    echo "[\"stop=${stop}\",\"0=$((20+RANDOM%20))-$((40+RANDOM%20))\",\"1=${r1}-$((r1+200))\",\"2=${r2}-$((r2+300)),c,${r3}-$((r3+200)),c,${r3}-$((r3+300))\",\"3=$((10+RANDOM%10))-$((20+RANDOM%10))\",\"4=$((200+RANDOM%300))-$((600+RANDOM%200))\",\"5=$((400+RANDOM%200))-$((800+RANDOM%200))\"]"
}

# --- 3. 核心安装逻辑 (修复一键运行的关键) ---
install_global() {
    if [[ "$0" != "$TARGET_BIN" ]]; then
        echo -e "${CYAN}同步脚本至系统并初始化...${PLAIN}"
        mkdir -p "$(dirname "$TARGET_BIN")"
        curl -sSL -o "$TARGET_BIN" "$REPO_URL" || wget -qO "$TARGET_BIN" "$REPO_URL"
        echo -e "\n# Fingerprint: $(head /dev/urandom | tr -dc 'a-zA-Z0-9' | head -c 32)" >> "$TARGET_BIN"
        chmod +x "$TARGET_BIN"
        # 核心：使用 < /dev/tty 接管标准输入，解决管道运行时 read 失效的问题
        exec bash "$TARGET_BIN" "$@" < /dev/tty
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
    
    local arch=$(uname -m); local kw="amd64"
    [[ "$arch" == "aarch64" ]] && kw="arm64"

    local url=$(curl -sL "https://api.github.com/repos/$repo/releases/tags/$target" | grep -o '"browser_download_url": *"[^"]*"' | grep "linux" | grep "$kw" | head -1 | cut -d'"' -f4)

    wget -qO /tmp/at.zip "$url"
    mkdir -p "$INSTALL_DIR"
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
Description=AnyTLS-Go Server
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

# --- 4. 菜单功能函数 ---
first_install() {
    install_deps
    enable_bbr
    update_core
    clear
    echo -e "${BOLD}=== 配置 AnyTLS ===${PLAIN}"
    read -p "端口 [8443]: " port; port=${port:-8443}
    read -p "密码 [随机]: " pass; pass=${pass:-$(head /dev/urandom | tr -dc 'a-zA-Z0-9' | head -c 12)}
    # 默认域名 www.cisco.com
    read -p "域名 [www.cisco.com]: " sni; sni=${sni:-"www.cisco.com"}
    save_config "$port" "$pass" "$sni"
    show_result
}

show_result() {
    [[ ! -f "$CONFIG_FILE" ]] && return
    source "$CONFIG_FILE"
    local ip=$(curl -s4m5 https://api.ipify.org || echo "你的IP")
    clear
    echo -e "${GREEN}=== 安装成功 ===${PLAIN}"
    echo -e "地址: ${CYAN}$ip:$PORT${PLAIN}"
    echo -e "密码: ${CYAN}$PASSWORD${PLAIN}"
    echo -e "域名: ${CYAN}$SNI${PLAIN}"
    echo -e "\n${YELLOW}分享链接:${PLAIN}"
    echo -e "${CYAN}anytls://$PASSWORD@$ip:$PORT?sni=$SNI&insecure=1#AnyTLS_Server${PLAIN}\n"
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
        echo -e " 5. ${RED}完全卸载${PLAIN}"
        echo -e " 0. 退出"
        echo -e "----------------------------------------"
        read -p " 选择 [0-5]: " num
        case "$num" in
            1) first_install ;;
            2) show_result ;;
            3) journalctl -u anytls -f ;;
            4) 
                if [[ -f "$CONFIG_FILE" ]]; then
                    source "$CONFIG_FILE"
                    save_config "$PORT" "$PASSWORD" "$SNI"
                    echo -e "${GREEN}混淆规则已刷新并重启服务${PLAIN}"; sleep 1
                else
                    echo -e "${RED}未发现配置文件，请先安装${PLAIN}"; sleep 1
                fi
                ;;
            5) 
                systemctl stop anytls; systemctl disable anytls >/dev/null 2>&1
                rm -rf "$INSTALL_DIR" "$CONFIG_DIR" "$TARGET_BIN" "$SERVICE_FILE"
                echo -e "${RED}已完全卸载${PLAIN}"; exit 0 ;;
            0) exit 0 ;;
            *) ;;
        esac
    done
}

# --- 执行入口 ---
check_root
install_global "$@"
menu
