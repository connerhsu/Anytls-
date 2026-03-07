#!/bin/bash
# ====================================================
# AnyTLS-Go 极致优化版 (参数修复 + 每日自动换肤)
# ====================================================

# --- 颜色定义 ---
RED='\033[31m'; GREEN='\033[32m'; YELLOW='\033[33m'; BLUE='\033[34m'; CYAN='\033[36m'; PLAIN='\033[0m'; BOLD='\033[1m'

# --- 路径与链接配置 ---
REPO_URL="https://raw.githubusercontent.com/connerhsu/Anytls-/refs/heads/main/Anytls-Fix.sh"
INSTALL_DIR="/opt/anytls"; CONFIG_DIR="/etc/anytls"
CONFIG_FILE="${CONFIG_DIR}/server.conf"; VERSION_FILE="${INSTALL_DIR}/version"
SERVICE_FILE="/etc/systemd/system/anytls.service"; TARGET_BIN="/usr/local/bin/anytls"

# --- 1. 环境增强：开启 BBR ---
enable_bbr() {
    if ! sysctl net.ipv4.tcp_congestion_control | grep -q "bbr"; then
        echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
        echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
        sysctl -p >/dev/null 2>&1
    fi
}

# --- 2. 随机混淆生成器 (核心逻辑) ---
generate_padding_json() {
    local stop=$((8 + RANDOM % 10))
    local r1=$((100 + RANDOM % 100)); local r2=$((500 + RANDOM % 300))
    local r3=$((700 + RANDOM % 300)); local r5=$((400 + RANDOM % 400))
    # 按照新版参数要求构建 JSON
    echo "[\"stop=${stop}\",\"0=$((10+RANDOM%30))-$((50+RANDOM%40))\",\"1=${r1}-$((r1+200))\",\"2=${r2}-$((r2+200)),c,${r3}-$((r3+150)),c,${r3}-$((r3+300))\",\"3=$((15+RANDOM%10))-$((30+RANDOM%20))\",\"4=$((250+RANDOM%200))-$((750+RANDOM%200))\",\"5=${r5}-$((r5+500))\"]"
}

# --- 3. 自动化定时任务 (Crontab) ---
setup_cron() {
    # 确保 cron 已安装
    if ! command -v cron &>/dev/null && ! command -v crond &>/dev/null; then
        apt-get install -y cron || yum install -y crontabs
    fi
    systemctl enable --now cron || systemctl enable --now crond
    
    # 写入定时任务：每日凌晨 3 点自动运行刷新逻辑
    (crontab -l 2>/dev/null | grep -v "$TARGET_BIN --refresh"; echo "0 3 * * * $TARGET_BIN --refresh > /dev/null 2>&1") | crontab -
}

# --- 4. 核心保存逻辑 (修复参数名) ---
save_config() {
    local pad=$(generate_padding_json)
    mkdir -p "$CONFIG_DIR"
    # 保存基础配置用于管理
    echo "PORT=\"$1\"; PASSWORD=\"$2\"; SNI=\"$3\"; PADDING='$pad'" > "$CONFIG_FILE"

    # 关键修复：使用 -padding-scheme 并移除不支持的 --sni 启动参数
    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=AnyTLS-Go Service
After=network.target

[Service]
Type=simple
User=root
ExecStart=${INSTALL_DIR}/anytls-server -l 0.0.0.0:$1 -p "$2" -padding-scheme '$pad'
Restart=always
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload && systemctl enable anytls && systemctl restart anytls
}

# --- 5. 基础环境维护 ---
check_root() {
    [[ $EUID -ne 0 ]] && echo -e "${RED}错误: 必须使用 root 运行${PLAIN}" && exit 1
}

install_deps() {
    local missing=()
    for dep in curl unzip wget net-tools cron; do
        ! command -v "$dep" &>/dev/null && missing+=("$dep")
    done
    [[ ${#missing[@]} -gt 0 ]] && (apt-get update -y || yum install -y epel-release) && (apt-get install -y "${missing[@]}" || yum install -y "${missing[@]}")
}

update_core() {
    local repo="anytls/anytls-go"
    local target=$(curl -sL "https://api.github.com/repos/$repo/releases/latest" | grep -o '"tag_name": *"[^"]*"' | head -1 | cut -d'"' -f4)
    local arch=$(uname -m); local kw="amd64"
    [[ "$arch" == "aarch64" ]] && kw="arm64"
    local url=$(curl -sL "https://api.github.com/repos/$repo/releases/tags/$target" | grep -o '"browser_download_url": *"[^"]*"' | grep "linux" | grep "$kw" | head -1 | cut -d'"' -f4)

    wget -qO /tmp/at.zip "$url" && mkdir -p "$INSTALL_DIR"
    unzip -qo /tmp/at.zip -d /tmp/at_tmp
    find /tmp/at_tmp -type f -name "anytls-server" -exec cp -f {} "$INSTALL_DIR/anytls-server" \;
    chmod +x "$INSTALL_DIR/anytls-server" && echo "$target" > "$VERSION_FILE"
    rm -rf /tmp/at.zip /tmp/at_tmp
}

# --- 6. 交互逻辑 ---
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
    setup_cron
    show_result
}

show_result() {
    [ ! -f "$CONFIG_FILE" ] && echo -e "${RED}未发现配置文件${PLAIN}" && return
    source "$CONFIG_FILE"
    local ip=$(curl -s4m5 https://api.ipify.org || echo "你的IP")
    clear
    echo -e "${GREEN}=== 安装成功 (每日凌晨自动换肤) ===${PLAIN}"
    echo -e "地址: ${CYAN}$ip:$PORT${PLAIN}"
    echo -e "密码: ${CYAN}$PASSWORD${PLAIN}"
    echo -e "域名: ${CYAN}$SNI${PLAIN}"
    echo -e "混淆: ${BLUE}$PADDING${PLAIN}"
    echo -e "\n${YELLOW}定时任务已生效，每天 03:00 将生成全新随机指纹。${PLAIN}"
    read -p "回车返回..."
}

menu() {
    while true; do
        clear
        local status="${RED}● 停止${PLAIN}"
        systemctl is-active --quiet anytls && status="${GREEN}● 运行中${PLAIN}"
        echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${PLAIN}"
        echo -e "      AnyTLS 极致版 (BBR + 每日自动换肤)"
        echo -e " 状态: $status    版本: ${YELLOW}$(cat "$VERSION_FILE" 2>/dev/null)${PLAIN}"
        echo -e "----------------------------------------"
        echo -e " 1. ${GREEN}安装/重置 (强制刷新随机混淆)${PLAIN}"
        echo -e " 2. 查看配置信息"
        echo -e " 3. 日志查看"
        echo -e " 4. ${YELLOW}立即随机刷新混淆并重启${PLAIN}"
        echo -e " 9. ${RED}完全卸载${PLAIN}"
        echo -e " 0. 退出"
        read -p " 选择 [0-9]: " num
        case "$num" in
            1) first_install ;;
            2) show_result ;;
            3) journalctl -u anytls -f ;;
            4) source "$CONFIG_FILE"; save_config "$PORT" "$PASSWORD" "$SNI"; echo -e "${GREEN}规则已刷新${PLAIN}"; sleep 1 ;;
            9) systemctl stop anytls; rm -rf "$INSTALL_DIR" "$CONFIG_DIR" "$TARGET_BIN" "$SERVICE_FILE"; crontab -l | grep -v "$TARGET_BIN" | crontab -; exit 0 ;;
            0) exit 0 ;;
        esac
    done
}

# --- 启动逻辑 ---
check_root

# 处理定时刷新请求
if [[ "$1" == "--refresh" ]]; then
    if [[ -f "$CONFIG_FILE" ]]; then
        source "$CONFIG_FILE"
        save_config "$PORT" "$PASSWORD" "$SNI"
    fi
    exit 0
fi

# 环境初始化
if [[ "$0" != "$TARGET_BIN" ]]; then
    cp "$0" "$TARGET_BIN" && chmod +x "$TARGET_BIN"
fi
menu
