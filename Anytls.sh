#!/usr/bin/env bash
# =========================================================
# Anytls-Go 一键管理脚本 (修复版 v0.1.9)
# 修复: 解决 curl 管道安装时的截断报错与快捷键丢失问题
# =========================================================

# --- 1. 定义关键路径 (标准化路径，防止混淆) ---
# 脚本真实存放位置
INSTALL_PATH="/usr/local/bin/anytls"
# 快捷指令 (软链接)
BIN_LINK="/usr/bin/anytls"
# 脚本下载源 (请确保这是你的 raw 地址)
SCRIPT_URL="https://raw.githubusercontent.com/connerhsu/Anytls-/main/Anytls.sh"

# --- 2. 颜色配置 ---
Red="\033[31m"
Green="\033[32m"
Yellow="\033[33m"
Blue="\033[34m"
Cyan="\033[36m"
Font="\033[0m"

# --- 3. 核心：自安装与接管逻辑 ---
install_and_exec() {
    # 如果当前运行的脚本 不等于 安装路径 (说明是 curl 管道运行 或 第一次运行)
    if [[ "$0" != "$INSTALL_PATH" ]]; then
        echo -e "${Cyan}[INFO] 正在初始化安装环境...${Font}"
        
        # 1. 强制清理旧的残留文件，防止冲突
        rm -f "$INSTALL_PATH" "$BIN_LINK" "/usr/local/bin/anytls_mgr"
        
        # 2. 下载脚本到系统目录
        if command -v wget >/dev/null; then
            wget -qO "$INSTALL_PATH" "$SCRIPT_URL"
        else
            curl -sSL -o "$INSTALL_PATH" "$SCRIPT_URL"
        fi
        
        # 3. 验证下载是否成功
        if [[ ! -s "$INSTALL_PATH" ]]; then
            echo -e "${Red}[ERROR] 脚本下载失败，请检查网络连接。${Font}"
            exit 1
        fi
        
        # 4. 赋予执行权限
        chmod +x "$INSTALL_PATH"
        
        # 5. 创建快捷指令 (anytls)
        ln -sf "$INSTALL_PATH" "$BIN_LINK"
        
        echo -e "${Green}[OK] 快捷指令已修复: anytls${Font}"
        echo -e "${Green}[OK] 正在启动管理菜单...${Font}"
        sleep 1
        
        # 6. 【关键】使用 exec 切换进程，脱离 curl 管道，防止“unexpected end of file”
        exec bash "$INSTALL_PATH" "$@"
    fi
}

# 立即执行安装检查 (这行代码必须放在最前面)
install_and_exec "$@"

# =========================================================
# 以下是原有业务逻辑 (已清理冗余代码)
# =========================================================

CONFIG_DIR="/etc/AnyTLS"
ANYTLS_SNAP_DIR="/tmp/anytls_install_$$"
ANYTLS_SERVER="${CONFIG_DIR}/server"
ANYTLS_SERVICE_NAME="anytls.service"
ANYTLS_SERVICE_FILE="/etc/systemd/system/${ANYTLS_SERVICE_NAME}"
ANYTLS_CONFIG_FILE="${CONFIG_DIR}/config.yaml"
TZ_DEFAULT="Asia/Shanghai"
SHELL_VERSION="0.1.9"

print_ok() { echo -e "${Green}[OK]${Blue} $1 ${Font}"; }
print_info() { echo -e "${Cyan}[INFO]${Cyan} $1 ${Font}"; }
print_error() { echo -e "${Red}[ERROR] ${Red} $1 ${Font}"; }

ensure_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "Error: 必须使用 root 运行本脚本!" 1>&2
    exit 1
  fi
}

# --- 脚本自更新检查 ---
check_self_update() {
  # 只有在正式安装路径下才检查更新
  if [[ "$0" == "$INSTALL_PATH" ]]; then 
      local remote_version
      remote_version=$(curl -fsSL --connect-timeout 3 -H "Cache-Control: no-cache" "$SCRIPT_URL" | grep 'SHELL_VERSION="' | head -1 | cut -d'"' -f2)
      if [[ -n "$remote_version" && "$remote_version" != "$SHELL_VERSION" ]]; then
        print_info "发现新版本: ${remote_version} (当前: ${SHELL_VERSION})"
        # 可以在这里添加自动更新提示
      fi
  fi
}

get_arch() {
  local arch_raw
  arch_raw=$(uname -m)
  case "$arch_raw" in
    x86_64 | amd64) echo "amd64" ;;
    aarch64 | arm64) echo "arm64" ;;
    *) print_error "不支持的架构 ($arch_raw)" >&2; return 1 ;;
  esac
}

os_install() {
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -y
    apt-get install -y ca-certificates unzip curl
  elif command -v dnf >/dev/null 2>&1; then
    dnf update -y
    dnf install -y ca-certificates unzip curl
  elif command -v yum >/dev/null 2>&1; then
    yum update -y
    yum install -y ca-certificates unzip curl
  else
    echo "请手动安装 ca-certificates, unzip, curl"
    exit 1
  fi
}

close_wall() {
  for svc in firewalld nftables ufw; do
    if systemctl list-unit-files | grep -q "^${svc}.service"; then
      if systemctl is-active --quiet "$svc"; then
        systemctl stop "$svc" 2>/dev/null || true
        systemctl disable "$svc" 2>/dev/null || true
      fi
    fi
  done
}

random_port() { shuf -i 2000-65000 -n 1; }
gen_password() { cat /proc/sys/kernel/random/uuid; }

valid_port() {
  local p="${1:-}"
  [[ "$p" =~ ^[0-9]+$ ]] && (( p >= 1 && p <= 65535 ))
}

is_port_used() {
  local port="$1"
  if command -v ss >/dev/null 2>&1; then
    ss -tuln | awk '{print $5}' | grep -Eq "[:.]${port}([[:space:]]|$)"
  elif command -v lsof >/dev/null 2>&1; then
    lsof -i :"$port" -sTCP:LISTEN >/dev/null 2>&1
  else
    return 1
  fi
}

read_port_interactive() {
  local input
  while true; do
    read -t 15 -p "回车或等待15秒为随机端口 (1-65535)：" input || true
    if [[ -z "${input:-}" ]]; then input=$(random_port); fi
    if ! valid_port "$input"; then echo "端口不合法"; continue; fi
    if is_port_used "$input"; then echo "端口被占用"; continue; fi
    echo "$input"
    break
  done
}

get_ip() {
  local ip
  ip=$(curl -s4 -m 5 https://api.ipify.org)
  [[ -z "$ip" ]] && ip=$(curl -s4 -m 5 http://checkip.amazonaws.com)
  echo "${ip:-127.0.0.1}"
}

get_latest_version() {
  local version
  version=$(curl -s https://api.github.com/repos/anytls/anytls-go/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
  if [[ -z "$version" ]]; then echo "v0.0.8"; return 0; fi 
  echo "$version"
}

get_install_version() {
  if [[ -f "$ANYTLS_SERVICE_FILE" ]]; then
    grep '^X-AT-Version=' "$ANYTLS_SERVICE_FILE" 2>/dev/null | sed -E 's/^X-AT-Version=//' || echo "unknown"
  else
    echo "unknown"
  fi
}

write_systemd() {
  local version="$1" port="$2" pass="$3"
  [[ -z "$version" ]] && version="$(get_install_version)"
  cat > "$ANYTLS_SERVICE_FILE" << EOF
[Unit]
Description=AnyTLS Server Service
After=network.target network-online.target
Wants=network-online.target
X-AT-Version=${version}

[Service]
Type=simple
User=root
Environment=TZ=${TZ_DEFAULT}
ExecStart="${ANYTLS_SERVER}" -l 0.0.0.0:${port} -p "${pass}"
Restart=on-failure
RestartSec=10s
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
}

write_config() {
  local port="$1" pass="$2"
  mkdir -p "$(dirname "${ANYTLS_CONFIG_FILE}")"
  cat > "${ANYTLS_CONFIG_FILE}" <<EOF
listen: :${port}
padding_scheme:
  - "stop=8"
  - "0=20-60"
  - "1=100-450"
  - "2=400-500,c,500-1000,c,500-1000,c,500-1000,c,500-1000"
  - "3=10-20,500-1000"
  - "4=100-800"
  - "5=100-800"
  - "6=100-800"
  - "7=100-800"
auth:
  type: password
  password: ${pass}
EOF
}

client_export() {
  if [[ ! -f "${ANYTLS_CONFIG_FILE}" ]]; then print_error "未找到配置"; return 1; fi
  local port pass ip link padding_info
  port=$(sed -nE 's/^[[:space:]]*listen:[[:space:]]*.*:([0-9]+)[[:space:]]*$/\1/p' "${ANYTLS_CONFIG_FILE}")
  pass=$(sed -nE 's/^[[:space:]]*password:[[:space:]]*(.*)$/\1/p' "${ANYTLS_CONFIG_FILE}")
  
  if grep -q "padding_scheme:" "${ANYTLS_CONFIG_FILE}"; then
    padding_info="${Green}已启用高级动态 Scheme (更安全)${Font}"
  else
    padding_info="普通静态混淆"
  fi
  
  ip=$(get_ip)
  link="${pass}@${ip}:${port}/?insecure=1#AnyTLS"

  echo -e "=========== AnyTLS 配置参数 ==========="
  echo -e " 地址: ${ip}"
  echo -e " 端口: ${port}"
  echo -e " 密码: ${pass}"
  echo -e " 混淆: ${padding_info}"
  echo -e " 备注: 无需每日更换 Padding，全自动动态"
  echo -e "========================================="
  echo -e " URL链接:"
  echo -e " anytls://${link}"
  echo -e "========================================="
}

is_active() { systemctl is-active "${ANYTLS_SERVICE_NAME}" >/dev/null 2>&1; }
is_installed() { [[ -f "$ANYTLS_SERVICE_FILE" ]]; }

install_status_text() {
  if is_installed; then
    if is_active; then echo -e "${Green}已安装（运行中）${Font}"; else echo -e "${Yellow}已安装（已停止）${Font}"; fi
  else echo -e "${Red}未安装${Font}"; fi
}

restart_service() {
  systemctl daemon-reload
  systemctl enable "${ANYTLS_SERVICE_NAME}" >/dev/null 2>&1
  systemctl restart "${ANYTLS_SERVICE_NAME}"
}

install_anytls() {
  mkdir -p "$CONFIG_DIR"
  os_install
  close_wall
  
  ARCH=$(get_arch) || exit 1
  LATEST=$(get_latest_version) || exit 1
  
  print_info "正在下载 AnyTLS ${LATEST} (${ARCH})..."
  AT_URL="https://github.com/anytls/anytls-go/releases/download/${LATEST}/anytls_${LATEST#v}_linux_${ARCH}.zip"
  
  mkdir -p "$ANYTLS_SNAP_DIR"
  curl -L -o "${ANYTLS_SNAP_DIR}/anytls.zip" "$AT_URL" || { print_error "下载失败"; exit 1; }
  
  unzip -o "${ANYTLS_SNAP_DIR}/anytls.zip" -d "$ANYTLS_SNAP_DIR"
  # 兼容不同zip包结构
  if [[ -f "${ANYTLS_SNAP_DIR}/anytls-server" ]]; then
      mv "${ANYTLS_SNAP_DIR}/anytls-server" "$ANYTLS_SERVER"
  elif [[ -f "${ANYTLS_SNAP_DIR}/anytls" ]]; then
      mv "${ANYTLS_SNAP_DIR}/anytls" "$ANYTLS_SERVER"
  fi
  
  chmod +x "$ANYTLS_SERVER"
  rm -rf "${ANYTLS_SNAP_DIR}"

  local port pass
  port=$(read_port_interactive)
  pass=$(gen_password)

  write_systemd "$LATEST" "$port" "$pass"
  write_config "$port" "$pass" 
  
  restart_service
  
  sleep 2
  if is_active; then
    print_ok "AnyTLS 服务已启动"
    client_export
  else
    print_error "服务启动失败"
    journalctl -u "${ANYTLS_SERVICE_NAME}" -n 10 --no-pager
  fi
}

update_anytls() {
  ! is_installed && print_error "未安装 AnyTLS" && return 1
  ARCH=$(get_arch) || exit 1
  LATEST=$(get_latest_version) || exit 1
  
  print_info "正在更新至 ${LATEST}..."
  AT_URL="https://github.com/anytls/anytls-go/releases/download/${LATEST}/anytls_${LATEST#v}_linux_${ARCH}.zip"
  mkdir -p "$ANYTLS_SNAP_DIR"
  curl -L -o "${ANYTLS_SNAP_DIR}/anytls.zip" "$AT_URL" || { print_error "下载失败"; exit 1; }
  
  systemctl stop "${ANYTLS_SERVICE_NAME}"
  unzip -o "${ANYTLS_SNAP_DIR}/anytls.zip" -d "$ANYTLS_SNAP_DIR"
  if [[ -f "${ANYTLS_SNAP_DIR}/anytls-server" ]]; then
      mv "${ANYTLS_SNAP_DIR}/anytls-server" "$ANYTLS_SERVER"
  elif [[ -f "${ANYTLS_SNAP_DIR}/anytls" ]]; then
      mv "${ANYTLS_SNAP_DIR}/anytls" "$ANYTLS_SERVER"
  fi
  chmod +x "$ANYTLS_SERVER"
  rm -rf "${ANYTLS_SNAP_DIR}"

  local port pass
  port=$(sed -nE 's/^[[:space:]]*listen:[[:space:]]*.*:([0-9]+)[[:space:]]*$/\1/p' "${ANYTLS_CONFIG_FILE}")
  pass=$(sed -nE 's/^[[:space:]]*password:[[:space:]]*(.*)$/\1/p' "${ANYTLS_CONFIG_FILE}")
  [[ -z "$port" ]] && port=$(random_port)
  [[ -z "$pass" ]] && pass=$(gen_password)

  write_systemd "$LATEST" "$port" "$pass"
  write_config "$port" "$pass"
  
  restart_service
  print_ok "更新完成"
  client_export
}

uninstall_anytls() {
  read -p "确认卸载？(y/N): " ans
  [[ "${ans:-N}" != [yY] ]] && echo "已取消" && return
  
  systemctl stop "${ANYTLS_SERVICE_NAME}"
  systemctl disable "${ANYTLS_SERVICE_NAME}"
  rm -f "${ANYTLS_SERVICE_FILE}"
  rm -f "${BIN_LINK}" "${INSTALL_PATH}"
  systemctl daemon-reload
  rm -rf "${CONFIG_DIR}"
  print_ok "卸载完成"
  exit 0
}

set_port() {
  ! is_installed && print_error "未安装" && return 1
  local new_port pass
  new_port=$(read_port_interactive)
  pass=$(sed -nE 's/^[[:space:]]*password:[[:space:]]*(.*)$/\1/p' "${ANYTLS_CONFIG_FILE}")
  write_systemd "" "$new_port" "$pass"
  write_config "$new_port" "$pass"
  restart_service
  print_ok "端口已更改"
  client_export
}

set_password() {
  ! is_installed && print_error "未安装" && return 1
  local new_pass port
  new_pass=$(gen_password)
  port=$(sed -nE 's/^[[:space:]]*listen:[[:space:]]*.*:([0-9]+)[[:space:]]*$/\1/p' "${ANYTLS_CONFIG_FILE}")
  write_systemd "" "$port" "$new_pass"
  write_config "$port" "$new_pass"
  restart_service
  print_ok "密码已刷新"
  client_export
}

reset_scheme() {
  ! is_installed && print_error "未安装" && return 1
  local port pass
  port=$(sed -nE 's/^[[:space:]]*listen:[[:space:]]*.*:([0-9]+)[[:space:]]*$/\1/p' "${ANYTLS_CONFIG_FILE}")
  pass=$(sed -nE 's/^[[:space:]]*password:[[:space:]]*(.*)$/\1/p' "${ANYTLS_CONFIG_FILE}")
  write_config "$port" "$pass"
  restart_service
  print_ok "已重置 Scheme"
  client_export
}

main() {
  check_self_update
  while true; do
    clear
    echo -e " AnyTLS 一键脚本 (High Security) ${SHELL_VERSION}"
    echo -e " -------------------------------------------"
    echo -e " 状态：$(install_status_text) | Ver: $(get_install_version)"
    echo -e " 快捷命令: ${Green}anytls${Font}"
    echo -e " -------------------------------------------"
    echo -e " 1. 安装/重装 AnyTLS"
    echo -e " 2. 更新 AnyTLS (强制升级配置)"
    echo -e " 3. 查看配置"
    echo -e " 4. 卸载 AnyTLS"
    echo -e " 5. 更改端口"
    echo -e " 6. 更改密码"
    echo -e " 7. 重置为默认高级 Scheme (修复配置)"
    echo -e " 0. 退出"
    echo -e " -------------------------------------------"
    read -p " 请输入数字: " choice
    case "${choice}" in
      1) install_anytls; read -rp "按回车返回..." ;;
      2) update_anytls; read -rp "按回车返回..." ;;
      3) client_export; read -rp "按回车返回..." ;;
      4) uninstall_anytls ;;
      5) set_port; read -rp "按回车返回..." ;;
      6) set_password; read -rp "按回车返回..." ;;
      7) reset_scheme; read -rp "按回车返回..." ;;
      0) exit 0 ;;
      *) echo "无效选项"; sleep 1 ;;
    esac
  done
}

ensure_root
main "$@"
