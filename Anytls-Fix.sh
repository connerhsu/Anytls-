#!/bin/bash
# ====================================================
# AnyTLS-Go 最终修复版 (支持一键管道运行)
# 特性: BBR加速、随机特征、自动环境修复
# ====================================================

# --- 颜色定义 ---
RED='\033[31m'; GREEN='\033[32m'; YELLOW='\033[33m'; BLUE='\033[34m'; CYAN='\033[36m'; PLAIN='\033[0m'

# --- 路径配置 ---
REPO_URL="https://raw.githubusercontent.com/connerhsu/Anytls-/main/Anytls-Fix.sh"
INSTALL_DIR="/opt/anytls"
CONFIG_FILE="/etc/anytls/server.conf"
TARGET_BIN="/usr/local/bin/anytls"
SERVICE_FILE="/etc/systemd/system/anytls.service"

# --- 1. 基础环境与 BBR ---
check_root() {
    [[ $EUID -ne 0 ]] && echo -e "${RED}错误: 请使用 root 运行${PLAIN}" && exit 1
}

enable_bbr() {
    if sysctl net.ipv4.tcp_congestion_control | grep -q "bbr"; then
        echo -e "${GREEN}[BBR] 已经开启${PLAIN}"
    else
        echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
        echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
        sysctl -p >/dev/null 2>&1
        echo -e "${GREEN}[BBR] 开启成功${PLAIN}"
    fi
}

# --- 2. 随机 Padding 生成 ---
generate_padding() {
    local stop=$((6 + RANDOM % 8))
    echo "[\"stop=${stop}\",\"0=$((20+RANDOM%20))-$((40+RANDOM%20))\",\"1=$((100+RANDOM%100))-$((300+RANDOM%100))\",\"2=400-600,c,500-800\",\"3=10-20\",\"4=300-600\",\"5=400-800\"]"
}

# --- 3. 核心安装逻辑 (修复一键运行的关键) ---
install_global() {
    # 如果脚本不是从本地目标路径运行，说明是 curl 管道运行
    if [[ "$0" != "$TARGET_BIN" ]]; then
        echo -e "${CYAN}正在将脚本同步至系统...${PLAIN}"
        mkdir -p "$(dirname "$TARGET_BIN")"
        curl -sSL -o "$TARGET_BIN" "$REPO_URL" || wget -qO "$TARGET_BIN" "$REPO_URL"
        chmod +x "$TARGET_BIN"
        
        # 移除可能冲突的旧命令
        rm -f /usr/local/bin/at /usr/local/bin/ats
        
        echo -e "${GREEN}同步完成，正在启动菜单...${PLAIN}"
        # 【关键】重新执行脚本，并强制将标准输入定向到 tty，解决 read 失效问题
        exec bash "$TARGET_BIN" "$@" < /dev/tty
    fi
}

install_deps() {
    local deps=("curl" "unzip" "wget" "net-tools")
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &>/dev/null; then
            apt-get update -y >/dev/null 2>&1 || yum install -y epel-release >/dev/null 2>&1
            apt-get install -y "$dep" >/dev/null 2>&1 || yum install -y "$dep" >/dev/null 2>&1
        fi
    done
}

update_core() {
    echo -e "${CYAN}正在下载 AnyTLS-Go 核心...${PLAIN}"
    local arch=$(uname -m)
    local kw="amd64"
    [[ "$arch" == "aarch64" ]] && kw="arm64"
    
    local url=$(curl -sL "https://api.github.com/repos/anytls/anytls-go/releases/latest" | grep "browser_download_url" | grep "linux" | grep "$kw" | head -1 | cut -d'"' -f4)
    
    wget -qO /tmp/at.zip "$url"
    mkdir -p "$INSTALL_DIR"
    unzip -qo /tmp/at.zip -d /tmp/at_tmp
    find /tmp/at_tmp -type f -name "anytls-server" -exec cp -f {} "$INSTALL_DIR/anytls-server" \;
    chmod +x "$INSTALL_DIR/anytls-server"
    rm -rf /tmp/at.zip /tmp/at_tmp
}

# --- 4. 配置写入 ---
save_config() {
    local pad=$(generate_padding)
    mkdir -p "/etc/anytls"
    cat > "$CONFIG_FILE" <<EOF
PORT="$1"
PASSWORD="$2"
SNI="$3"
PADDING='$pad'
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

# --- 5. 菜单界面 ---
first_install() {
    install_deps
    enable_bbr
    update_core
    echo -e "\n${BOLD}=== 配置节点 ===${PLAIN}"
    read -p "端口 [8443]: " port; port=${port:-8443}
    read -p "密码 [随机]: " pass; pass=${pass:-$(head /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 12)}
    read -p "域名 [www.microsoft.com]: " sni; sni=${sni:-"www.microsoft.com"}
    save_config "$port" "$pass" "$sni"
    
    local ip=$(curl -s4m5 https://api.ipify.org)
    echo -e "\n${GREEN}安装成功！${PLAIN}"
    echo -e "配置已存至: $CONFIG_FILE"
    echo -e "分享链接: ${CYAN}anytls://$pass@$ip:$port?sni=$sni&insecure=1#AnyTLS${PLAIN}"
    read -p "回车返回菜单..."
}

menu() {
    while true; do
        clear
        echo -e "${CYAN}AnyTLS-Go 管理脚本${PLAIN}"
        echo -e "------------------------"
        echo -e "1. 安装 / 重置"
        echo -e "2. 卸载"
        echo -e "0. 退出"
        read -p "请选择: " num
        case "$num" in
            1) first_install ;;
            2) systemctl stop anytls; rm -rf "$INSTALL_DIR" "/etc/anytls" "$TARGET_BIN" "$SERVICE_FILE"; exit 0 ;;
            0) exit 0 ;;
        esac
    done
}

# --- 执行入口 ---
check_root
install_global "$@"
menu
