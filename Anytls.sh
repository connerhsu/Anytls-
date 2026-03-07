#!/usr/bin/env bash
# https://github.com/GeorgianaBlake/AnyTLS
# AnyTLS一键管理脚本：安装/更新/查看/更改端口/更改密码/删除/快捷指令/Padding
# 适配 Debian/Ubuntu (apt) 与 CentOS/RHEL/Alma/Rocky
# 兼容 arm64 和 amd64 两种系统架构

# 移除 set -euo pipefail 以防止脚本因非致命错误静默退出
# set -euo pipefail 

CONFIG_DIR="/etc/AnyTLS" # 配置目录
ANYTLS_SNAP_DIR="/tmp/anytls_install_$$" # 临时目录
ANYTLS_SERVER="${CONFIG_DIR}/server" # 服务端文件
ANYTLS_SERVICE_NAME="anytls.service" # 服务
ANYTLS_SERVICE_FILE="/etc/systemd/system/${ANYTLS_SERVICE_NAME}" # 服务目录
ANYTLS_CONFIG_FILE="${CONFIG_DIR}/config.yaml" # 主配置文件
TZ_DEFAULT="Asia/Shanghai" # 默认时区
SHELL_VERSION="0.1.3" # 脚本版本
AT_ALIASES="AT_GeorgianaBlake" # AnyTLS别名
SHORTCUT_FILE="/usr/bin/anytls" # 快捷指令路径

# 字体颜色配置
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

get_arch() {
  local arch_raw
  arch_raw=$(uname -m)
  case "$arch_raw" in
    x86_64 | amd64) echo "amd64" ;;
    aarch64 | arm64) echo "arm64" ;;
    *)
      print_error "不支持的系统架构 ($arch_raw)" >&2
      return 1
      ;;
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
    echo "未识别的包管理器，请手动安装 ca-certificates、unzip、curl 后重试"
    exit 1
  fi
}

pause() { read -rp "按回车返回菜单..." _; }
quit() { exit 0; }
hr() { printf '%*s\n' 40 '' | tr ' ' '='; }

# 关闭各类防火墙
close_wall() {
  for svc in firewalld nftables ufw; do
    if systemctl list-unit-files | grep -q "^${svc}.service"; then
      if systemctl is-active --quiet "$svc"; then
        systemctl stop "$svc" 2>/dev/null || true
        systemctl disable "$svc" 2>/dev/null || true
        print_ok "已关闭并禁用防火墙: $svc"
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
gen_padding() { shuf -i 100-1500 -n 1; }

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
    read -t 15 -p "回车或等待15秒为随机端口，或者自定义端口请输入(1-65535)：" input || true
    if [[ -z "${input:-}" ]]; then
      input=$(random_port)
    fi
    if ! valid_port "$input"; then
      echo "端口不合法：$input"
      continue
    fi
    if is_port_used "$input"; then
      echo "端口 $input 已被占用"
      continue
    fi
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
  version=$(curl -s https://api.github.com/repos/anytls/anytls-go/releases/latest \
    | grep '"tag_name":' \
    | sed -E 's/.*"([^"]+)".*/\1/')
  if [[ -z "$version" ]]; then
    print_error "无法获取AnyTLS最新版本号" >&2
    return 1
  fi
  echo "$version"
}

get_install_version() {
  if [[ -f "$ANYTLS_SERVICE_FILE" ]]; then
    # 增加 || true 防止 grep 没找到时退出脚本
    grep '^X-AT-Version=' "$ANYTLS_SERVICE_FILE" 2>/dev/null | sed -E 's/^X-AT-Version=//' || echo "unknown"
  else
    echo "unknown"
  fi
}

# 修复后的创建快捷指令逻辑
create_shortcut() {
  local current_script
  # 尝试获取当前脚本的绝对路径
  if [[ -f "$0" ]]; then
      current_script=$(readlink -f "$0")
  else
      current_script=""
  fi

  # 只有当 $0 是真实文件，且不是 bash 本身，且不是目标文件时才复制
  if [[ -n "$current_script" && -f "$current_script" && "$current_script" != "$SHORTCUT_FILE" ]]; then
      cp -f "$current_script" "$SHORTCUT_FILE"
      chmod +x "$SHORTCUT_FILE"
      print_ok "快捷指令 anytls 已更新，输入 'anytls' 即可管理"
  elif [[ -f "install.sh" ]]; then
      # 如果脚本名为 install.sh 且在当前目录
      cp -f "install.sh" "$SHORTCUT_FILE"
      chmod +x "$SHORTCUT_FILE"
      print_ok "快捷指令 anytls 已修复"
  else
      # 无法自动复制时的提示
      echo -e "${WARN} 无法自动创建快捷指令。请手动执行: cp <脚本文件名> /usr/bin/anytls"
  fi
}

write_systemd() {
  local version="$1" port="$2" pass="$3"
  [[ -z "$version" ]] && version="$(get_install_version)"
  
  cat > "$ANYTLS_SERVICE_FILE" << EOF
[Unit]
Description=AnyTLS Server Service
Documentation=https://github.com/anytls/anytls-go
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
  local port="$1" pass="$2" padding="$3"
  mkdir -p "$(dirname "${ANYTLS_CONFIG_FILE}")"
  cat > "${ANYTLS_CONFIG_FILE}" <<EOF
listen: :${port}
padding: ${padding}
auth:
  type: password
  password: ${pass}
EOF
}

client_export() {
  if [[ ! -f "${ANYTLS_CONFIG_FILE}" ]]; then
    print_error "未找到 ${ANYTLS_CONFIG_FILE}"
    return 1
  fi
  local port pass ip link padding
  port=$(sed -nE 's/^[[:space:]]*listen:[[:space:]]*.*:([0-9]+)[[:space:]]*$/\1/p' "${ANYTLS_CONFIG_FILE}")
  pass=$(sed -nE 's/^[[:space:]]*password:[[:space:]]*(.*)$/\1/p' "${ANYTLS_CONFIG_FILE}")
  padding=$(sed -nE 's/^[[:space:]]*padding:[[:space:]]*([0-9]+).*$/\1/p' "${ANYTLS_CONFIG_FILE}")
  
  ip=$(get_ip)
  local alias_enc
  alias_enc=$(urlencode "${AT_ALIASES}")
  link="${pass}@${ip}:${port}/?insecure=1#${alias_enc}"

  echo -e "=========== AnyTLS 配置参数 ==========="
  echo -e " 地址: ${ip}"
  echo -e " 端口: ${port}"
  echo -e " 密码: ${pass}"
  echo -e " Padding: ${padding} (随机混淆长度)"
  echo -e " 备注: 请确保客户端允许不安全证书"
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
    if is_active; then
      echo -e "${Green}已安装（运行中）${Font}"
    else
      echo -e "${Yellow}已安装（已停止）${Font}"
    fi
  else
    echo -e "${Red}未安装${Font}"
  fi
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

  local port pass padding
  port=$(read_port_interactive)
  pass=$(gen_password)
  padding=$(gen_padding)

  write_systemd "$LATEST" "$port" "$pass"
  write_config "$port" "$pass" "$padding"
  
  # 放在最后执行，确保脚本本身存在
  create_shortcut

  restart_service
  
  sleep 2
  if is_active; then
    print_ok "AnyTLS 服务已启动"
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

  local port pass padding
  port=$(sed -nE 's/^[[:space:]]*listen:[[:space:]]*.*:([0-9]+)[[:space:]]*$/\1/p' "${ANYTLS_CONFIG_FILE}")
  pass=$(sed -nE 's/^[[:space:]]*password:[[:space:]]*(.*)$/\1/p' "${ANYTLS_CONFIG_FILE}")
  padding=$(sed -nE 's/^[[:space:]]*padding:[[:space:]]*([0-9]+).*$/\1/p' "${ANYTLS_CONFIG_FILE}")

  [[ -z "$port" ]] && port=$(random_port)
  [[ -z "$pass" ]] && pass=$(gen_password)
  [[ -z "$padding" ]] && padding=$(gen_padding)

  write_systemd "$LATEST" "$port" "$pass"
  write_config "$port" "$pass" "$padding"
  create_shortcut
  
  restart_service
  print_ok "更新完成"
  client_export
}

uninstall_anytls() {
  ! is_installed && print_error "未安装 AnyTLS" && return 1
  read -p "确认卸载？(y/N): " ans
  [[ "${ans:-N}" != [yY] ]] && echo "已取消" && return
  
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
  local new_port pass padding
  new_port=$(read_port_interactive)
  pass=$(sed -nE 's/^[[:space:]]*password:[[:space:]]*(.*)$/\1/p' "${ANYTLS_CONFIG_FILE}")
  padding=$(sed -nE 's/^[[:space:]]*padding:[[:space:]]*([0-9]+).*$/\1/p' "${ANYTLS_CONFIG_FILE}")
  [[ -z "$padding" ]] && padding=$(gen_padding)
  
  write_systemd "" "$new_port" "$pass"
  write_config "$new_port" "$pass" "$padding"
  restart_service
  print_ok "端口已更改为: $new_port"
  client_export
}

set_password() {
  ! is_installed && print_error "未安装" && return 1
  local new_pass port padding
  new_pass=$(gen_password)
  port=$(sed -nE 's/^[[:space:]]*listen:[[:space:]]*.*:([0-9]+)[[:space:]]*$/\1/p' "${ANYTLS_CONFIG_FILE}")
  padding=$(sed -nE 's/^[[:space:]]*padding:[[:space:]]*([0-9]+).*$/\1/p' "${ANYTLS_CONFIG_FILE}")
  [[ -z "$padding" ]] && padding=$(gen_padding)
  
  write_systemd "" "$port" "$new_pass"
  write_config "$port" "$new_pass" "$padding"
  restart_service
  print_ok "密码已刷新"
  client_export
}

set_padding() {
  ! is_installed && print_error "未安装" && return 1
  local new_padding port pass
  new_padding=$(gen_padding)
  port=$(sed -nE 's/^[[:space:]]*listen:[[:space:]]*.*:([0-9]+)[[:space:]]*$/\1/p' "${ANYTLS_CONFIG_FILE}")
  pass=$(sed -nE 's/^[[:space:]]*password:[[:space:]]*(.*)$/\1/p' "${ANYTLS_CONFIG_FILE}")
  
  write_config "$port" "$pass" "$new_padding"
  restart_service
  print_ok "Padding 已刷新为: $new_padding"
  client_export
}

view_config() {
  ! is_installed && print_error "未安装" && return 1
  client_export
}

main() {
  # 启动时先创建快捷方式，确保修复
  create_shortcut

  while true; do
    clear
    hr
    echo -e " AnyTLS 一键脚本 (Fixed)"
    echo -e " 快捷命令: anytls"
    echo -e " 版本: ${SHELL_VERSION}"
    echo -e " 状态：$(install_status_text) | Ver: $(get_install_version)"
    hr
    echo -e "${Cyan}1. 安装/重装 AnyTLS${Font}"
    echo -e "${Cyan}2. 更新 AnyTLS${Font}"
    echo -e "${Cyan}3. 查看配置${Font}"
    echo -e "${Cyan}4. 卸载 AnyTLS${Font}"
    echo -e "${Cyan}5. 更改端口${Font}"
    echo -e "${Cyan}6. 更改密码${Font}"
    echo -e "${Cyan}7. 更改随机Padding (混淆)${Font}"
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
      7) set_padding; pause ;;
      0) exit 0 ;;
      *) echo "无效选项"; pause ;;
    esac
  done
}

ensure_root
main
