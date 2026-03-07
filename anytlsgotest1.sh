#!/usr/bin/env bash
# https://github.com/GeorgianaBlake/AnyTLS
# AnyTLS 一键管理脚本 v0.1.7 (Auto-Repair Edition)
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
SHELL_VERSION="0.1.7" 
AT_ALIASES="AT_GeorgianaBlake"
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

# --- 核心修改：支持管道运行下的快捷方式修复 ---
create_shortcut() {
  local current_script
  current_script=$(readlink -f "$0" 2>/dev/null)
  
  # 判断是否在管道中运行或文件不存在
  if [[ "$0" == "bash" || "$0" == "-" || ! -f "$current_script" ]]; then
      print_info "检测到在线运行，正在同步脚本到本地..."
      curl -fsSL "$SCRIPT_RAW_URL" -o "$SHORTCUT_FILE"
      chmod +x "$SHORTCUT_FILE"
  elif [[ "$current_script" != "$SHORTCUT_FILE" ]]; then
      cp -f "$current_script" "$SHORTCUT_FILE"
      chmod +x "$SHORTCUT_FILE"
  fi
  
  # 清理旧路径并刷新缓存
  [[ -f "/usr/bin/anytls" ]] && rm -f "/usr/bin/anytls"
  hash -r
}

ensure_root() {
  if [[ $EUID -ne 0 ]]; then
    clear
    echo "Error: 必须使用 root 运行本脚本!" 1>&2
    exit 1
  fi
}

# (其余功能函数保持不变，为节省篇幅略，确保你的本地副本包含全部功能)
# ... [此处包含你之前代码中的 get_arch, install_anytls, write_config 等全部函数] ...

# 关键：在 main 开始前就执行修复
main() {
  ensure_root
  create_shortcut
  # ... 菜单循环代码 ...
