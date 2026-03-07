#!/bin/bash
# ====================================================
# AnyTLS-Go 极致动态混淆版 (Connor 定制)
# ====================================================

# --- 颜色定义 ---
RED='\033[31m'; GREEN='\033[32m'; YELLOW='\033[33m'; BLUE='\033[34m'; CYAN='\033[36m'; PLAIN='\033[0m'; BOLD='\033[1m'

# --- 路径与链接配置 ---
REPO_URL="https://raw.githubusercontent.com/connerhsu/Anytls-/refs/heads/main/Anytls-Fix.sh"
INSTALL_DIR="/opt/anytls"; CONFIG_DIR="/etc/anytls"
CONFIG_FILE="${CONFIG_DIR}/server.conf"; VERSION_FILE="${INSTALL_DIR}/version"
SERVICE_FILE="/etc/systemd/system/anytls.service"; TARGET_BIN="/usr/local/bin/anytls"

# --- 1. 环境增强：一键开启 BBR ---
enable_bbr() {
    echo -e "${CYAN}正在检查 BBR 状态...${PLAIN}"
    if sysctl net.ipv4.tcp_congestion_control | grep -q "bbr"; then
        echo -e "${GREEN}BBR 已经开启。${PLAIN}"
    else
        echo -e "${YELLOW}正在尝试开启 BBR...${PLAIN}"
        echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
        echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
        sysctl -p >/dev/null 2>&1
        if sysctl net.ipv4.tcp_congestion_control | grep -q "bbr"; then
            echo -e "${GREEN}BBR 开启成功！${PLAIN}"
        else
            echo -e "${RED}BBR 开启失败，请检查内核版本是否 > 4.9${PLAIN}"
        fi
    fi
}

# --- 2. 增强型随机混淆生成器 (核心更改) ---
generate_padding_json() {
    # stop: 随机化握手停止位，模拟不同 TLS 实现的差异
    local stop=$((8 + RANDOM % 10))
    
    # 随机生成各种长度区间，避免出现固定的 565-865 等特征
    local r0_start=$((10 + RANDOM % 40));  local r0_end=$((50 + RANDOM % 50))
    local r1_start=$((100 + RANDOM % 100)); local r1_end=$((300 + RANDOM % 200))
    
    # r2 是大包区间，用于模拟应用层数据，加入 c (Client) 的多重扰动
    local r2_1_s=$((500 + RANDOM % 200));  local r2_1_e=$((800 + RANDOM % 200))
    local r2_2_s=$((700 + RANDOM % 200));  local r2_2_e=$((1000 + RANDOM % 300))
    
    local r3_start=$((10 + RANDOM % 20));  local r3_end=$((30 + RANDOM % 30))
    local r4_start=$((200 + RANDOM % 200)); local r4_end=$((700 + RANDOM % 300))
    local r5_start=$((400 + RANDOM % 300)); local r5_end=$((900 + RANDOM % 400))

    # 构建混淆 JSON
    echo "[\"stop=${stop}\",\"0=${r0_start}-${r0_end}\",\"1=${r1_start}-${r1_end}\",\"2=${r2_1_s}-${r2_1_e},c,${r2_2_s}-${r2_1_e},c,${r2_2_s}-${r2_2_e}\",\"3=${r3_start}-${r3_end}\",\"4=${r4_start}-${r4_end}\",\"5=${r5_start}-${r5_end}\"]"
}

# --- 3. 脚本自混淆 ---
add_script_padding() {
    echo -e "\n# Fingerprint: $(head /dev/urandom | tr -dc 'a-zA-Z0-9' | head -c 32)" >> "$1"
}

# --- 4. 核心逻辑 ---
check_root() {
    [[ $EUID -ne 0 ]] && echo -e "${RED}错误: 必须使用 root 运行${PLAIN}" && exit 1
}

install_global() {
    if [[ "$0" != "$TARGET_BIN" ]]; then
        echo -e "${CYAN}环境初始化中...${PLAIN}"
        curl -sSL -o "$TARGET_BIN" "$REPO_URL" || wget -qO "$TARGET_BIN" "$REPO_URL"
        add_script_padding "$TARGET_BIN" && chmod +x "$TARGET_BIN"
        exec bash "$TARGET_BIN" "$@" < /dev/tty
    else
        (curl -sSL -o /tmp/at_sync.sh "$REPO_URL" && cat /tmp/at_sync.sh > "$TARGET_BIN" && add_script_padding "$TARGET_BIN" && rm -f /tmp/at_sync.sh) &
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
    
    local arch=$(uname -m); local kw=""
    [[ "$arch" == "x86_64" ]] && kw="amd64" || kw="arm64"

    local url=$(curl -sL "https://api.github.com/repos/$repo/releases/tags/$target" | grep -o '"browser_download_url": *"[^"]*"' | grep "linux" | grep "$kw" | head -1 | cut -d'"' -f4)

    wget -qO /tmp/at.zip "$url" && mkdir -p "$INSTALL_DIR"
    unzip -qo /tmp/at.zip -d /tmp/at_tmp
    find /tmp/at_tmp -type f -name "anytls-server" -exec cp -f {} "$INSTALL_DIR/anytls-server" \;
    chmod +x "$INSTALL_DIR/anytls-server" && echo "$target" > "$VERSION_FILE"
    rm -rf /tmp/at.zip /tmp/at_tmp
}

save_config() {
    local pad=$(generate_padding_json)
    mkdir -p "$CONFIG_DIR"
    # 保存配置到本地文件，方便后期刷新调用
    cat > "$CONFIG_FILE" <<EOF
PORT="$1"; PASSWORD="$2"; SNI="$3"; PADDING='$pad'
EOF
    # 写入 Systemd 服务，确保 --padding 后面跟的是最新生成的随机值
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

first_install() {
    install_deps
    enable_bbr
    update_core
    clear
    echo -e "${BOLD}=== 配置 AnyTLS ===${PLAIN}"
    read -p "端口 [8443]: " port; port=${port:-8443}
    read -p "密码 [随机]: " pass; pass=${pass:-$(head /dev/urandom | tr -dc 'a-zA-Z0-9' | head -c 12)}
    read -p "域名 [www.cisco.com]: " sni; sni=${sni:-"www.cisco.com"}
    save_config "$port" "$pass" "$sni"
    show_result
}

show_result() {
    [ ! -f "$CONFIG_FILE" ] && echo -e "${RED}未发现配置文件${PLAIN}" && return
    source "$CONFIG_FILE"
    local ip=$(curl -s4m5 https://api.ipify.org || echo "你的IP")
    clear
    echo -e "${GREEN}=== 当前配置信息 ===${PLAIN}"
    echo -e "地址: ${CYAN}$ip:$PORT${PLAIN}"
    echo -e "密码: ${CYAN}$PASSWORD${PLAIN}"
    echo -e "域名: ${CYAN}$SNI${PLAIN}"
    echo -e "混淆: ${BLUE}$PADDING${PLAIN}"
    echo -e "\n${YELLOW}分享链接 (AnyTLS):${PLAIN}"
    echo -e "${CYAN}anytls://$PASSWORD@$ip:$PORT?sni=$SNI&insecure=1#AnyTLS_$(date +%s)${PLAIN}\n"
    read -p "回车返回..."
}

menu() {
    while true; do
        clear
        local status="${RED}● 停止${PLAIN}"
        systemctl is-active --quiet anytls && status="${GREEN}● 运行中${PLAIN}"
        echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${PLAIN}"
        echo -e "        AnyTLS 极致版 (动态随机指纹)"
        echo -e " 状态: $status    版本: ${YELLOW}$(cat "$VERSION_FILE" 2>/dev/null)${PLAIN}"
        echo -e "----------------------------------------"
        echo -e " 1. ${GREEN}安装/重置 (强制刷新随机混淆)${PLAIN}"
        echo -e " 2. 查看配置信息"
        echo -e " 3. 日志查看"
        echo -e " 4. ${YELLOW}仅重新生成混淆并重启${PLAIN}"
        echo -e " 9. ${RED}完全卸载${PLAIN}"
        echo -e " 0. 退出"
        read -p " 选择 [0-9]: " num
        case "$num" in
            1) first_install ;;
            2) show_result ;;
            3) journalctl -u anytls -f ;;
            4) 
                if [ -f "$CONFIG_FILE" ]; then
                    source "$CONFIG_FILE"
                    save_config "$PORT" "$PASSWORD" "$SNI"
                    echo -e "${GREEN}混淆规则已重新随机生成并重启服务！${PLAIN}"
                else
                    echo -e "${RED}错误：请先安装后再执行此操作${PLAIN}"
                fi
                sleep 2 ;;
            9) systemctl stop anytls; rm -rf "$INSTALL_DIR" "$CONFIG_DIR" "$TARGET_BIN" "$SERVICE_FILE"; exit 0 ;;
            0) exit 0 ;;
        esac
    done
}

# --- 启动 ---
check_root
# 如果是通过 URL 直接运行，则进行全局安装初始化
if [[ "$0" != "$TARGET_BIN" ]]; then
    install_global "$@"
fi
menu
