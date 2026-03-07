#!/bin/bash
# ====================================================
# AnyTLS-Go 动态混淆随机版 (修复版)
# 修复内容: 
# 1. 修复 padding-scheme 参数传入方式 (改为文件路径)，解决启动失败问题
# 2. 修复菜单选项 5 显示乱码问题 (echo -p -> echo -e)
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
# 注意：如果你的脚本仓库地址变了，请在这里更新
REPO_URL="https://raw.githubusercontent.com/connerhsu/Anytls-/refs/heads/main/Anytls-Fix.sh"
INSTALL_DIR="/opt/anytls"
CONFIG_DIR="/etc/anytls"
CONFIG_FILE="${CONFIG_DIR}/server.conf"
PADDING_FILE="${CONFIG_DIR}/padding.json" # 新增：独立的 Padding 配置文件
VERSION_FILE="${INSTALL_DIR}/version"
SERVICE_FILE="/etc/systemd/system/anytls.service"
TARGET_BIN="/usr/local/bin/anytls"

# --- 0. 核心：随机数据包填充策略生成器 ---
generate_padding_json() {
    local stop=$((6 + RANDOM % 8)) # 停止位在 6-13 之间随机
    local r1=$((80 + RANDOM % 150))
    local r2=$((300 + RANDOM % 400))
    local r3=$((500 + RANDOM % 500))

    cat <<EOF
[
  "stop=${stop}",
  "0=$((20 + RANDOM % 20))-$((40 + RANDOM % 20))",
  "1=${r1}-$((r1 + 200))",
  "2=${r2}-$((r2 + 300)),c,${r3}-$((r3 + 200)),c,${r3}-$((r3 + 300))",
  "3=$((10 + RANDOM % 10))-$((20 + RANDOM % 10))",
  "4=$((200 + RANDOM % 300))-$((600 + RANDOM % 200))",
  "5=$((400 + RANDOM % 200))-$((800 + RANDOM % 200))"
]
EOF
}

# --- 1. 脚本自混淆 (改变脚本自身的 MD5) ---
add_script_padding() {
    local rand_str=$(head /dev/urandom | tr -dc 'a-zA-Z0-9' | head -c $((16 + RANDOM % 48)))
    # 避免无限追加，只在文件末尾没有 Fingerprint 时追加（可选优化，此处保持原逻辑简单追加）
    echo -e "\n# Fingerprint: ${rand_str}" >> "$1"
}

# --- 2. 基础检查与自更新逻辑 ---
check_root() {
    [[ $EUID -ne 0 ]] && echo -e "${RED}必须使用 root 权限运行！${PLAIN}" && exit 1
}

install_global() {
    if [[ "$0" != "$TARGET_BIN" ]]; then
        echo -e "${CYAN}正在初始化 AnyTLS 环境...${PLAIN}"
        if command -v wget >/dev/null; then wget -qO "$TARGET_BIN" "$REPO_URL"; else curl -sSL -o "$TARGET_BIN" "$REPO_URL"; fi
        # 赋予执行权限
        chmod +x "$TARGET_BIN"
        add_script_padding "$TARGET_BIN"
        exec bash "$TARGET_BIN" "$@" < /dev/tty
    else
        # 每次运行本地 anytls，都尝试同步远端并重新随机化本地脚本
        local tmp_sh="/tmp/anytls_rand.sh"
        if curl -sSL -o "$tmp_sh" "$REPO_URL" || wget -qO "$tmp_sh" "$REPO_URL"; then
            # 只有下载成功才覆盖
            if [[ -s "$tmp_sh" ]]; then
                cat "$tmp_sh" > "$TARGET_BIN"
                add_script_padding "$TARGET_BIN"
                chmod +x "$TARGET_BIN"
            fi
            rm -f "$tmp_sh"
        fi
    fi
}

install_deps() {
    local deps=("curl" "unzip" "net-tools" "wget" "tar")
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &>/dev/null; then
            echo -e "正在安装依赖: $dep"
            if [ -x "$(command -v apt-get)" ]; then
                apt-get update -y >/dev/null 2>&1
                apt-get install -y "$dep" >/dev/null 2>&1
            elif [ -x "$(command -v yum)" ]; then
                yum install -y "$dep" >/dev/null 2>&1
            fi
        fi
    done
}

# --- 3. 功能模块 ---
update_core() {
    local target=$1
    echo -e "${CYAN}正在获取最新核心...${PLAIN}"
    local repo="anytls/anytls-go"
    
    # 获取最新 Tag
    if [[ -z "$target" ]]; then
        target=$(curl -sL "https://api.github.com/repos/$repo/releases/latest" | grep -o '"tag_name": *"[^"]*"' | head -n 1 | sed 's/"tag_name": "//;s/"//')
    fi
    
    if [[ -z "$target" ]]; then
        echo -e "${RED}获取版本信息失败，请检查网络连接或 GitHub API 限制${PLAIN}"
        return
    fi

    ARCH=$(uname -m)
    case $ARCH in
        x86_64|amd64) KW="amd64" ;;
        aarch64|arm64) KW="arm64" ;;
        *) echo "不支持的架构: $ARCH"; return ;;
    esac

    # 获取下载链接
    URL=$(curl -sL "https://api.github.com/repos/$repo/releases/tags/$target" | grep -o '"browser_download_url": *"[^"]*"' | grep -i "linux" | grep -i "$KW" | grep -i "\.zip" | head -n 1 | sed 's/"browser_download_url": "//;s/"//')

    if [[ -z "$URL" ]]; then
        echo -e "${RED}未找到适配当前架构的下载链接${PLAIN}"
        return
    fi

    echo -e "正在下载版本: ${target}..."
    wget -qO /tmp/anytls.zip "$URL"
    
    if [[ ! -s /tmp/anytls.zip ]]; then
        echo -e "${RED}下载失败${PLAIN}"
        return
    fi

    mkdir -p /tmp/anytls_tmp && unzip -qo /tmp/anytls.zip -d /tmp/anytls_tmp
    BIN=$(find /tmp/anytls_tmp -type f -name "anytls-server" | head -n 1)
    
    if [[ -n "$BIN" ]]; then
        systemctl stop anytls 2>/dev/null
        mkdir -p "$INSTALL_DIR"
        cp -f "$BIN" "$INSTALL_DIR/anytls-server"
        chmod +x "$INSTALL_DIR/anytls-server"
        echo "$target" > "$VERSION_FILE"
        echo -e "${GREEN}核心更新成功${PLAIN}"
    else
        echo -e "${RED}解压失败或未找到二进制文件${PLAIN}"
    fi
    rm -rf /tmp/anytls.zip /tmp/anytls_tmp
}

write_config() {
    # 1. 生成 Padding JSON
    local padding_val=$(generate_padding_json | tr -d '\n' | sed 's/ //g')
    
    # 确保配置目录存在
    mkdir -p "$CONFIG_DIR"

    # 2. 【关键修复】将 JSON 写入到单独的文件中
    echo "${padding_val}" > "${PADDING_FILE}"

    # 3. 写入主配置文件 (供脚本读取显示用)
    cat > "$CONFIG_FILE" << EOF
PORT="${1}"
PASSWORD="${2}"
SNI="${3}"
# 注意: 实际运行使用的是 ${PADDING_FILE}
PADDING_Preview='${padding_val}'
EOF

    # 4. 【关键修复】Systemd 中指向文件路径，而不是传递 Raw String
    # 移除了单引号包裹，直接使用绝对路径
    cat > "$SERVICE_FILE" << EOF
[Unit]
Description=AnyTLS-Go Server
After=network.target

[Service]
Type=simple
User=root
ExecStart=${INSTALL_DIR}/anytls-server -l 0.0.0.0:${1} -p "${2}" -padding-scheme "${PADDING_FILE}"
Restart=always
RestartSec=3
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl restart anytls
    
    # 检查启动状态
    sleep 2
    if systemctl is-active --quiet anytls; then
        echo -e "${GREEN}服务启动成功！${PLAIN}"
    else
        echo -e "${RED}服务启动失败！正在查看日志...${PLAIN}"
        journalctl -u anytls -n 10 --no-pager
    fi
}

first_install() {
    install_deps
    # 只有当二进制文件不存在时才强制更新/下载，或者用户手动选更新
    if [[ ! -f "$INSTALL_DIR/anytls-server" ]]; then
        update_core
    fi
    
    clear
    echo -e "${BOLD}=== 初始化配置 (Padding 已自动随机化) ===${PLAIN}"
    read -p "端口 [8443]: " PORT
    PORT=${PORT:-8443}
    read -p "密码 [随机]: " PASSWORD
    PASSWORD=${PASSWORD:-$(head /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 16)}
    read -p "域名 [www.cisco.com]: " SNI
    SNI=${SNI:-"www.cisco.com"}
    
    mkdir -p "$CONFIG_DIR"
    write_config "$PORT" "$PASSWORD" "$SNI"
    show_result
}

show_result() {
    # 容错处理：如果配置文件不存在
    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo -e "${RED}配置文件不存在，请先安装。${PLAIN}"
        return
    fi
    
    source "$CONFIG_FILE"
    
    # 获取公网 IP
    IP=$(curl -s4m5 https://api.ipify.org || curl -s4m5 https://ifconfig.me || echo "127.0.0.1")
    
    # 读取最新的 Padding 文件内容用于显示
    local current_padding=$(cat "$PADDING_FILE" 2>/dev/null)

    clear
    echo -e "${GREEN}=== AnyTLS 节点信息 (已应用动态混淆) ===${PLAIN}"
    echo -e "地址: ${CYAN}${IP}:${PORT}${PLAIN}"
    echo -e "密码: ${CYAN}${PASSWORD}${PLAIN}"
    echo -e "SNI:  ${CYAN}${SNI}${PLAIN}"
    echo -e "\n${YELLOW}当前 Padding 策略 (来自 ${PADDING_FILE}):${PLAIN}"
    echo -e "${BLUE}${current_padding}${PLAIN}"
    echo -e "\n${YELLOW}分享链接:${PLAIN}"
    # 这里构造链接
    echo -e "${CYAN}anytls://${PASSWORD}@${IP}:${PORT}?sni=${SNI}&insecure=1#Random_Node${PLAIN}\n"
    read -p "按回车返回菜单..."
}

# --- 4. 菜单系统 ---
menu() {
    while true; do
        clear
        VER=$(cat "$VERSION_FILE" 2>/dev/null || echo "未安装")
        STATUS="${RED}● 停止${PLAIN}"
        if systemctl is-active --quiet anytls; then
            STATUS="${GREEN}● 运行中${PLAIN}"
        fi
        
        echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${PLAIN}"
        echo -e "           AnyTLS-Go 动态混淆面板"
        echo -e " 状态: ${STATUS}      版本: ${YELLOW}${VER}${PLAIN}"
        echo -e " 特性: 每次配置/安装都会重新生成随机 Padding"
        echo -e "----------------------------------------"
        echo -e " ${GREEN}1.${PLAIN} 安装 / 重置 (重新生成随机 Padding)"
        echo -e " ${GREEN}2.${PLAIN} 查看配置信息"
        echo -e " ${GREEN}3.${PLAIN} 查看日志"
        # 【修复】这里 echo -p 改为 echo -e
        echo -e " ${YELLOW}5.${PLAIN} 修改端口/域名 (触发重新随机化)"
        echo -e " ${RED}9.${PLAIN} 卸载"
        echo -e " ${GREEN}0.${PLAIN} 退出"
        echo -e "----------------------------------------"
        read -p " 选择: " num
        case "$num" in
            1) first_install ;;
            2) show_result ;;
            3) journalctl -u anytls -f ;;
            5) first_install ;; 
            9) systemctl stop anytls; systemctl disable anytls; rm -rf "$INSTALL_DIR" "$CONFIG_DIR" "$TARGET_BIN" "$SERVICE_FILE"; echo "已卸载"; exit 0 ;;
            0) exit 0 ;;
            *) echo -e "${RED}请输入正确的数字${PLAIN}"; sleep 1 ;;
        esac
    done
}

check_root
install_global "$@"
menu
