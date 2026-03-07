#!/usr/bin/env bash
# https://github.com/GeorgianaBlake/AnyTLS
# AnyTLS 一键管理脚本 v0.1.6 (High Security Padding Edition)
# 集成高级 padding_scheme，每一次连接都使用动态随机包长，无需每日更换
# 适配 Debian/Ubuntu (apt) 与 CentOS/RHEL/Alma/Rocky
# 兼容 arm64 和 amd64

# ================= 配置区 =================
SCRIPT_RAW_URL="https://raw.githubusercontent.com/GeorgianaBlake/AnyTLS/main/install.sh"
# =========================================

CONFIG_DIR="/etc/AnyTLS"
ANYTLS_SNAP_DIR="/tmp/anytls_install_$$"
ANYTLS_SERVER="${CONFIG_DIR}/server"
ANYTLS_SERVICE_NAME="anytls.service"
ANYTLS_SERVICE_FILE="/etc/systemd/system/${ANYTLS_SERVICE_NAME}"
ANYTLS_CONFIG_FILE="${CONFIG_DIR}/config.yaml"
TZ_DEFAULT="Asia/Shanghai"
SHELL_VERSION="0.1.6" 
AT_ALIASES="AT_GeorgianaBlake"

# --- 核心修复点：将路径修改为报错信息中的路径 ---
SHORTCUT_FILE="/usr/local/bin/anytls"

# 颜色配置
Font="\033[0m"
Red="\033[31m"
Green="\033[32m"
Yellow="\033[33m"
Blue="\033[34m"
Cyan="\033[36m"
RedBG="\033[41m"
OK="${Green}[OK]${Font}"
ERROR="${Red}[ERROR]${Font}"
WARN="${Yellow}[WARN]${Font}"
INFO="${Cyan}[INFO]${Font}"

print_ok() { echo -e "${OK}${Blue} $1 ${Font}"; }
print_info() { echo -e "${INFO}${Cyan} $1 ${Font}"; }
print_error() { echo -e "${ERROR} ${RedBG} $1 ${Font}"; }

judge() {
  if [[ 0 -eq $? ]]; then
    print_ok "$1 完成"
    sleep 1
  else
    print_error "$1 失败"
    exit 1
  fi
}

trap 'echo -e "\n${WARN} 已中断"; exit 1' INT

ensure_root() {
  if [[ $EUID -ne 0 ]]; then
    clear
    echo "Error: 必须使用 root 运行本脚本!" 1>&2
    exit 1
  fi
}

check_self_update() {
  if [[ "$0" != "$SHORTCUT_FILE" ]]; then return; fi
  local remote_version
  remote_version=$(curl -fsSL --connect-timeout 3 -H "Cache-Control: no-cache" "$SCRIPT_RAW_URL" | grep 'SHELL_VERSION="' | head -1 | cut -d'"' -f2)
  if [[ -z "$remote_version" ]]; then return; fi
  if [[ "$remote_version" != "$SHELL_VERSION" ]]; then
    print_info "发现脚本新版本: ${remote_version} (当前: ${SHELL_VERSION})"
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

pause() { read -rp "按回车返回菜单..." _; }
quit() { exit 0; }
hr() { printf '%*s\n' 40 '' | tr ' ' '='; }

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

urlencode() {
  local s="$1"
  local i c
  for (( i=0; i<${#s}; i++ )); do
    c=${s:$i:1}
    case "$c" in
      [a-zA-Z0-9.~_-]) printf '%s' "$c" ;;
      *) printf '%%%02X' "'$c" ;;
    esac
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
  elif command -v netstat >/dev/null 2>&1; then
    netstat -tuln 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]${port}$"
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
  local ip4 ip6
  ip4=$(curl -s -4 http://www.cloudflare.com/cdn-cgi/trace | awk -F= '/^ip=/{print $2}')
  [[ -n "${ip4}" ]] && echo "${ip4}" && return
  ip6=$(curl -s -6 http://www.cloudflare.com/cdn-cgi/trace | awk -F= '/^ip=/{print $2}')
  [[ -n "${ip6}" ]] && echo "${ip6}" && return
  curl -s https://api.ipify.org || true
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

# --- 核心修复函数：强制覆盖坏掉的快捷方式 ---
create_shortcut() {
  local current_script
  current_script=$(readlink -f "$0")
  
  if [[ "$current_script" != "$SHORTCUT_FILE" ]]; then
      cp -f "$current_script" "$SHORTCUT_FILE"
      chmod +x "$SHORTCUT_FILE"
      # 清理可能存在的旧路径干扰
      [[ -f "/usr/bin/anytls" ]] && rm -f "/usr/bin/anytls"
      print_ok "快捷指令 anytls 已重新定向至 $SHORTCUT_FILE"
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
StandardOutput=journal
StandardError=journal

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
    local pad_val
    pad_val=$(sed -nE 's/^[[:space:]]*padding:[[:space:]]*([0-9]+).*$/\1/p' "${ANYTLS_CONFIG_FILE}")
    padding_info="${pad_val} (普通静态混淆)"
  fi
  
  ip=$(get_ip)
  local alias_enc
  alias_enc=$(urlencode "${AT_ALIASES}")
  link="${pass}@${ip}:${port}/?insecure=1#${alias_enc}"

  echo -e "=========== AnyTLS 配置参数 ==========="
  echo -e " 地址: ${ip}"
  echo -e " 端口: ${port}"
  echo -e " 密码: ${pass}"
  echo -e " 混淆: ${padding_info}"
  echo -e " 备注: 此配置使用动态包长，无需每日更换 Padding"
  echo -e "========================================="
  echo -e " URL链接:"
  echo -e " anytls://${link}"
  echo -e "========================================="
}

start_service() { systemctl start "${ANYTLS_SERVICE_NAME}"; sleep 1; status_service; }
stop_service() { systemctl stop "${ANYTLS_SERVICE_NAME}"; }
status_service() { systemctl status "${ANYTLS_SERVICE_NAME}" --no-pager; }
log_service() { journalctl -u "${ANYTLS_SERVICE_NAME}" -f "$@"; }

binary_exists() { [[ -x "${ANYTLS_SERVER}" ]]; }
service_file_exists() { [[ -f "${ANYTLS_SERVICE_FILE}" ]]; }
is_installed() { binary_exists || service_file_exists; }
is_active() { systemctl is-active "${ANYTLS_SERVICE_NAME}" >/dev/null 2>&1; }

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
  mv "${ANYTLS_SNAP_DIR}/anytls-server" "$ANYTLS_SERVER"
  chmod +x "$ANYTLS_SERVER"
  rm -rf "${ANYTLS_SNAP_DIR}"

  local port pass
  port=$(read_port_interactive)
  pass=$(gen_password)

  write_systemd "$LATEST" "$port" "$pass"
  write_config "$port" "$pass"
  
  create_shortcut
  restart_service
  
  sleep 2
  if is_active; then
    print_ok "AnyTLS 服务已启动 (High Security Mode)"
    client_export
  else
    print_error "服务启动失败"
    log_service -n 20
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
  mv "${ANYTLS_SNAP_DIR}/anytls-server" "$ANYTLS_SERVER"
  chmod +x "$ANYTLS_SERVER"
  rm -rf "${ANYTLS_SNAP_DIR}"

  local port pass
  port=$(sed -nE 's/^[[:space:]]*listen:[[:space:]]*.*:([0-9]+)[[:space:]]*$/\1/p' "${ANYTLS_CONFIG_FILE}")
  pass=$(sed -nE 's/^[[:space:]]*password:[[:space:]]*(.*)$/\1/p' "${ANYTLS_CONFIG_FILE}")
  [[ -z "$port" ]] && port=$(random_port)
  [[ -z "$pass" ]] && pass=$(gen_password)

  write_systemd "$LATEST" "$port" "$pass"
  write_config "$port" "$pass"
  create_shortcut
  
  restart_service
  print_ok "更新完成，配置文件已升级为高级 Scheme"
  client_export
}

uninstall_anytls() {
  ! is_installed && print_error "未安装 AnyTLS" && return 1
  read -p "确认卸载？(y/N): " ans
  [[ "${ans:-N}" != [yY] ]] && echo "已取消" && return
  
  crontab -l 2>/dev/null | grep -v "auto_padding.sh" | crontab -
  rm -f "${CONFIG_DIR}/auto_padding.sh"

  systemctl stop "${ANYTLS_SERVICE_NAME}"
  systemctl disable "${ANYTLS_SERVICE_NAME}"
  rm -f "${ANYTLS_SERVICE_FILE}"
  rm -f "${SHORTCUT_FILE}"
  systemctl daemon-reload
  rm -rf "${CONFIG_DIR}"
  print_ok "卸载完成"
}

set_port() {
  ! is_installed && print_error "未安装" && return 1
  local new_port pass
  new_port=$(read_port_interactive)
  pass=$(sed -nE 's/^[[:space:]]*password:[[:space:]]*(.*)$/\1/p' "${ANYTLS_CONFIG_FILE}")
  
  write_systemd "" "$new_port" "$pass"
  write_config "$new_port" "$pass"
  restart_service
  print_ok "端口已更改为: $new_port"
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
  print_ok "已重置为默认高级 Scheme"
  client_export
}

view_config() {
  ! is_installed && print_error "未安装" && return 1
  client_export
}

main() {
  ensure_root
  create_shortcut
  check_self_update 

  while true; do
    clear
    hr
    echo -e " AnyTLS 一键脚本 (High Security)"
    echo -e " 快捷命令: anytls"
    echo -e " 脚本版本: ${SHELL_VERSION}"
    echo -e " 状态：$(install_status_text) | Ver: $(get_install_version)"
    echo -e " 混淆模式: ${Green}高级动态 Scheme (实时随机)${Font}"
    hr
    echo -e "${Cyan}1. 安装/重装 AnyTLS${Font}"
    echo -e "${Cyan}2. 更新 AnyTLS (强制升级配置)${Font}"
    echo -e "${Cyan}3. 查看配置${Font}"
    echo -e "${Cyan}4. 卸载 AnyTLS${Font}"
    echo -e "${Cyan}5. 更改端口${Font}"
    echo -e "${Cyan}6. 更改密码${Font}"
    echo -e "${Cyan}7. 重置为默认高级 Scheme (修复配置)${Font}"
    echo -e "${Cyan}0. 退出${Font}"
    hr
    read -p "请输入数字: " choice
    case "${choice}" in
      1) install_anytls; pause ;;
      2) update_anytls; pause ;;
      3) view_config; pause ;;
      4) uninstall_anytls; pause ;;
      5) set_port; pause ;;
      6) set_password; pause ;;
      7) reset_scheme; pause ;;
      0) exit 0 ;;
      *) echo "无效选项"; pause ;;
    esac
  done
}

main
